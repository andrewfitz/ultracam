import Accelerate
import CoreAudioTypes

/// Where one input channel's samples come from during a `process` call.
struct ChannelSource {
  /// nil reads as silence: a channel the buffer list does not carry, or one
  /// of a buffer without data.
  var base: UnsafeRawPointer?
  /// Elements between consecutive frames.
  var stride: Int
}

/// Converts any supported input into planar Float32 chunks with an optional
/// history prefix (the true-peak FIR's 11 past samples), in memory allocated
/// once at init. Every pointer is stable for the stage's lifetime.
struct PlanarStage {
  let channelCount: Int
  let history: Int
  let capacity: Int
  let channelStride: Int
  let storage: UnsafeMutablePointer<Float>
  let sources: UnsafeMutablePointer<ChannelSource>

  init(channelCount: Int, history: Int, capacity: Int) {
    self.channelCount = channelCount
    self.history = history
    self.capacity = capacity
    // Keep every channel 16-byte aligned for vDSP.
    channelStride = (history + capacity + 3) & ~3
    storage = .allocate(capacity: channelCount * channelStride)
    storage.initialize(repeating: 0, count: channelCount * channelStride)
    sources = .allocate(capacity: channelCount)
    sources.initialize(repeating: ChannelSource(base: nil, stride: 1), count: channelCount)
  }

  func deallocate() {
    storage.deallocate()
    sources.deallocate()
  }

  /// The current chunk of channel `c`; `history` past samples precede it.
  @inline(__always) func samples(_ c: Int) -> UnsafeMutablePointer<Float> {
    storage + c * channelStride + history
  }

  /// Fills channel c's history with the current chunk's first sample.
  func primeHistory(_ c: Int) {
    guard history > 0 else { return }
    let x = samples(c)
    (x - history).update(repeating: x[0], count: history)
  }

  // MARK: Binding inputs (no allocation; fills `sources`)

  func bindInterleaved(_ base: UnsafeRawPointer, format: AudioSampleFormat, frameStride: Int) {
    forEachIndex(channelCount) { c in
      sources[c] = ChannelSource(base: base + c * format.byteSize, stride: frameStride)
    }
  }

  func bindPlanar(_ c: Int, _ base: UnsafeRawPointer) {
    sources[c] = ChannelSource(base: base, stride: 1)
  }

  /// Channels are taken in order across the buffers, which may be planar,
  /// interleaved or mixed. Channels the list does not carry, and the channels
  /// of a buffer without data (an unrendered bus), read as silence; either
  /// way every later buffer keeps its channel positions.
  func bindBufferList(_ list: UnsafePointer<AudioBufferList>, frameCount: Int, format: AudioSampleFormat) {
    let raw = UnsafeRawPointer(list)
    let bufferCount = Int(list.pointee.mNumberBuffers)
    let first = raw + MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
    var c = 0
    var b = 0
    while b < bufferCount, c < channelCount {
      let buffer = (first + b * MemoryLayout<AudioBuffer>.stride).load(as: AudioBuffer.self)
      b += 1
      let width = Int(buffer.mNumberChannels)
      let data = buffer.mData.map(UnsafeRawPointer.init)
      if data != nil {
        precondition(
          frameCount * width * format.byteSize <= Int(buffer.mDataByteSize), "AudioBuffer shorter than frameCount")
      }
      var i = 0
      while i < width, c < channelCount {
        sources[c] = ChannelSource(base: data.map { $0 + i * format.byteSize }, stride: width)
        c += 1
        i += 1
      }
    }
    while c < channelCount {
      sources[c] = ChannelSource(base: nil, stride: 1)
      c += 1
    }
  }

  // MARK: Loading

  /// Converts `frames` frames starting at `offset` into the chunk buffers.
  /// Float input is sanitized so no filter state can ever be poisoned.
  func load(offset: Int, frames: Int, format: AudioSampleFormat) {
    let n = vDSP_Length(frames)
    forEachIndex(channelCount) { c in
      let dst = samples(c)
      let source = sources[c]
      guard let base = source.base else {
        vDSP_vclr(dst, 1, n)
        return
      }
      let stride = source.stride
      let src = base + offset * stride * format.byteSize
      switch format {
      case .float32:
        let f = src.assumingMemoryBound(to: Float.self)
        if stride == 1 {
          dst.update(from: f, count: frames)
        } else {
          // A strided multiply by one is vDSP's fast gather (mmov copies one row at a time).
          var one: Float = 1
          vDSP_vsmul(f, stride, &one, dst, 1, n)
        }
        sanitize(dst, frames)
      case .int16:
        vDSP_vflt16(src.assumingMemoryBound(to: Int16.self), stride, dst, 1, n)
        var scale: Float = 1 / 32768
        vDSP_vsmul(dst, 1, &scale, dst, 1, n)
      case .int32:
        vDSP_vflt32(src.assumingMemoryBound(to: Int32.self), stride, dst, 1, n)
        var scale: Float = 1 / 2_147_483_648
        vDSP_vsmul(dst, 1, &scale, dst, 1, n)
      }
    }
  }

  /// NaN reads as 0, infinity as full scale (an over), and finite magnitudes
  /// beyond `sampleLimit` are clamped to it. One vector pass (a sum of
  /// magnitudes, which any NaN, infinity or huge sample pushes past the
  /// limit); the scalar repair only runs then.
  @inline(__always) private func sanitize(_ x: UnsafeMutablePointer<Float>, _ frames: Int) {
    var sum: Float = 0
    vDSP_svemg(x, 1, &sum, vDSP_Length(frames))
    guard !(sum <= Self.sampleLimit) else { return }
    forEachIndex(frames) { i in
      let v = x[i]
      if v.isNaN {
        x[i] = 0
      } else if v.isInfinite {
        x[i] = v > 0 ? 1 : -1
      } else if abs(v) > Self.sampleLimit {
        x[i] = v > 0 ? Self.sampleLimit : -Self.sampleLimit
      }
    }
  }

  /// +120 dBFS: far above any real signal, far below Float overflow in the filters.
  static let sampleLimit: Float = 1e6

  /// Moves the last `history` samples of a `frames`-long chunk in front of the
  /// next chunk. Regions may overlap when `frames < history`.
  func carryHistory(_ c: Int, frames: Int) {
    guard history > 0 else { return }
    let x = samples(c)
    (x - history).update(from: x + frames - history, count: history)
  }
}
