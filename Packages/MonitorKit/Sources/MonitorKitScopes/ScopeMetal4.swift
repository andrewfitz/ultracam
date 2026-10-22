import Metal
import MonitorKit

// Shared pieces of the scopes' Metal 4 encode path. Like MonitorKit's, every
// call takes the host's `MonitorSubmission` and only encodes: no queue, command
// buffer or allocator is created, nothing is committed, waited for or handled.
// Uniforms go into the host's allocator or a `MonitorUniformRing` slot,
// bindings into an argument table each object owns, and what the GPU reads into
// `ScopeEngine.residency`, released only after its last submission completes.

/// Copies `value` into uniform memory at `offset`.
@inline(__always)
func scopeStore<T>(_ value: T, _ base: UnsafeMutableRawPointer, _ offset: Int) {
  withUnsafeBytes(of: value) { base.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
}

@inline(__always)
func scopeAlign256(_ n: Int) -> Int { (n + 255) / 256 * 256 }

/// One encode's uniform memory: `length` bytes from the host's allocator (always
/// written), or the slot of `ring` holding `generation` (`contents` nil when that
/// slot already holds it).
func scopeUniforms(
  _ ring: inout MonitorUniformRing, length: Int, generation: UInt64, submission: MonitorSubmission,
  engine: ScopeEngine
) throws -> (contents: UnsafeMutableRawPointer?, address: MTLGPUAddress) {
  if let host = submission.uniforms {
    let m = host.allocateUniforms(length: length)
    return (m.contents, m.gpuAddress)
  }
  return try ring.slot(
    for: submission, generation: generation, device: engine.device, residency: engine.residency,
    initialSlots: engine.framesInFlight)
}

extension MonitorResidency {
  /// Makes `buffer` the resident one in `slot`: adds it, and retires the one it
  /// replaces until the latest submission completes. Steady state compares one
  /// identity and touches nothing.
  func track(_ buffer: MTLBuffer?, in slot: inout MTLBuffer?) {
    guard slot !== buffer else { return }
    if let old = slot { retire(old, resident: old) }
    slot = buffer
    if let buffer { add(buffer) }
  }

  func track(_ texture: MTLTexture?, in slot: inout MTLTexture?) {
    guard slot !== texture else { return }
    if let old = slot { retire(old, resident: old) }
    slot = texture
    if let texture { add(texture) }
  }

  /// A LUT's texture, counted, so one LUT shared by several scopes or feeds stays resident.
  func track(_ lut: MonitorLUT?, in slot: inout MonitorLUT?) {
    guard slot !== lut else { return }
    if let old = slot { retire(old, resident: old.texture) }
    slot = lut
    if let lut { add(lut.texture) }
  }
}
