// Included only with ULTRACAM_BACKEND_TESTING; no mock code in the shipped app.
#include <vector>
#include <string>

class FakeTimecode final : public IDeckLinkTimecode {
 public:
  std::atomic<ULONG> references{1};
  CFStringRef value = CFSTR("01:02:03:04");
  uint8_t frames = 4;
  uint8_t minutes = 2, seconds = 3;
  bool componentsFail = false;
  BMDTimecodeFlags flags = bmdTimecodeIsDropFrame;
  ~FakeTimecode() override = default;
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG n = --references; if (!n) delete this; return n; }
  BMDTimecodeBCD GetBCD() override { return 0; }
  HRESULT GetComponents(uint8_t *hours, uint8_t *minuteCount, uint8_t *secondCount, uint8_t *frameCount) override {
    if (componentsFail) return E_FAIL;
    if (hours) *hours = 1; if (minuteCount) *minuteCount = minutes; if (secondCount) *secondCount = seconds;
    if (frameCount) *frameCount = frames; return S_OK;
  }
  HRESULT GetString(CFStringRef *result) override { if (!result) return E_INVALIDARG; *result = static_cast<CFStringRef>(CFRetain(value)); return S_OK; }
  BMDTimecodeFlags GetFlags() override { return flags; }
  HRESULT GetTimecodeUserBits(BMDTimecodeUserBits *bits) override { if (bits) *bits = 0; return S_OK; }
};

// Capture always enables 32-bit integer audio; the fixture is written as
// 16-bit values for readability and stored left-aligned like the driver's.
class FakeAudioPacket final : public IDeckLinkAudioInputPacket {
 public:
  std::atomic<ULONG> references{1};
  std::vector<int32_t> samples;
  BMDTimeValue packetTime = 960;
  explicit FakeAudioPacket(std::initializer_list<int16_t> values) {
    for (int16_t value : values) samples.push_back(int32_t(value) * 65536);
  }
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG n = --references; if (!n) delete this; return n; }
  long GetSampleFrameCount() override { return static_cast<long>(samples.size() / 2); }
  HRESULT GetBytes(void **result) override { if (!result) return E_INVALIDARG; *result = samples.data(); return S_OK; }
  HRESULT GetPacketTime(BMDTimeValue *result, BMDTimeScale) override { if (!result) return E_INVALIDARG; *result = packetTime; return S_OK; }
};

class FakeRawAudioPacket final : public IDeckLinkAudioInputPacket {
 public:
  std::atomic<ULONG> references{1};
  std::vector<int32_t> samples;
  size_t channelCount = 2;
  BMDTimeValue packetTime = 48000 * 3 + 17;
  explicit FakeRawAudioPacket(std::initializer_list<int32_t> values) : samples(values) {}
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG n = --references; if (!n) delete this; return n; }
  long GetSampleFrameCount() override { return static_cast<long>(samples.size() / channelCount); }
  HRESULT GetBytes(void **result) override { if (!result) return E_INVALIDARG; *result = samples.data(); return S_OK; }
  HRESULT GetPacketTime(BMDTimeValue *result, BMDTimeScale) override { if (!result) return E_INVALIDARG; *result = packetTime; return S_OK; }
};

class FakeFrame;

class FakeVideoBuffer final : public IDeckLinkVideoBuffer {
 public:
  std::atomic<ULONG> references{1};
  uint64_t size;
  void *foreignBytes = nullptr;
  explicit FakeVideoBuffer(uint64_t bytes) : size(bytes) {}
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG n = --references; if (!n) delete this; return n; }
  HRESULT GetBytes(void **result) override { if (!result || !foreignBytes) return E_NOTIMPL; *result = foreignBytes; return S_OK; }
  HRESULT GetSize(uint64_t *result) override { if (!result) return E_INVALIDARG; *result = size; return S_OK; }
  HRESULT StartAccess(BMDBufferAccessFlags) override { return S_OK; }
  HRESULT EndAccess(BMDBufferAccessFlags) override { return S_OK; }
};

class FakeMetadata final : public IDeckLinkVideoFrameMetadataExtensions {
 public:
  std::atomic<ULONG> references{1};
  int64_t colorspace, eotf;
  FakeMetadata(int64_t space, int64_t transfer) : colorspace(space), eotf(transfer) {}
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG n = --references; if (!n) delete this; return n; }
  HRESULT GetInt(BMDDeckLinkFrameMetadataID key, int64_t *value) override {
    if (key == bmdDeckLinkFrameMetadataColorspace && colorspace) { *value = colorspace; return S_OK; }
    if (key == bmdDeckLinkFrameMetadataHDRElectroOpticalTransferFunc && eotf >= 0) { *value = eotf; return S_OK; }
    return E_INVALIDARG;
  }
  HRESULT GetFloat(BMDDeckLinkFrameMetadataID, double *) override { return E_NOTIMPL; }
  HRESULT GetFlag(BMDDeckLinkFrameMetadataID, bool *) override { return E_NOTIMPL; }
  HRESULT GetString(BMDDeckLinkFrameMetadataID, CFStringRef *) override { return E_NOTIMPL; }
  HRESULT GetBytes(BMDDeckLinkFrameMetadataID, void *, uint32_t *) override { return E_NOTIMPL; }
};

@interface FakeFrameLifetime : NSObject
- (instancetype)initWithRelease:(void (^)(void))release;
@end
@implementation FakeFrameLifetime { void (^_release)(void); }
- (instancetype)initWithRelease:(void (^)(void))release { if ((self = [super init])) _release = [release copy]; return self; }
- (void)dealloc { if (_release) _release(); }
@end

// SDK 16 frames expose their buffer through IDeckLinkMacVideoBuffer. Like the
// driver's, the CVPixelBuffer it creates keeps the frame alive until its final release.
class FakeMacVideoBuffer final : public IDeckLinkMacVideoBuffer {
 public:
  std::atomic<ULONG> references{1};
  FakeFrame *frame;
  explicit FakeMacVideoBuffer(FakeFrame *owner);
  ~FakeMacVideoBuffer() override;
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG n = --references; if (!n) delete this; return n; }
  HRESULT CreateCVPixelBufferRef(void **result) override;
};

class FakeFrame final : public IDeckLinkVideoInputFrame {
 public:
  std::atomic<ULONG> references{1};
  bool *destroyed;
  std::vector<uint8_t> bytes = std::vector<uint8_t>(10240 * 2160, 0);
  bool noSignal = false, invalidTime = false, negativeTime = false, badBytes = false;
  FakeTimecode *timecode = nullptr;      // Every RP188 format except HFRTC.
  FakeTimecode *hfrTimecode = nullptr;   // bmdTimecodeRP188HighFrameRate only.
  BMDTimeValue frameDuration = 1001;
  BMDTimeValue streamTime = 123123;
  BMDTimeValue hardwareTime = 0;         // Microseconds; 0 is unavailable.
  uint64_t bufferSize = 0;               // 0: no IDeckLinkVideoBuffer interface.
  bool hdrFlag = false;
  int64_t metadataColorspace = 0, metadataEOTF = -1;
  bool metadataAvailable = false;
  CFStringRef sdkTransfer = nullptr;     // An attachment the SDK sets itself.
  long width = 3840;
  long height = 2160;
  long rowBytes = 10240;
  long wrappedWidth = 3840;
  long wrappedHeight = 2160;
  BMDPixelFormat pixel = bmdFormat10BitYUV;
  IDeckLinkVideoBuffer *ownedBuffer = nullptr;
  FakeFrame(bool *result) : destroyed(result) {}
  ~FakeFrame() override { if (ownedBuffer) ownedBuffer->Release(); *destroyed = true; }
  HRESULT QueryInterface(REFIID iid, LPVOID *result) override {
    *result = nullptr;
    if (sameIID(iid, IID_IDeckLinkVideoBuffer) && ownedBuffer) {
      ownedBuffer->AddRef(); *result = ownedBuffer; return S_OK;
    }
    if (sameIID(iid, IID_IDeckLinkMacVideoBuffer)) {
      *result = static_cast<IDeckLinkMacVideoBuffer *>(new FakeMacVideoBuffer(this)); return S_OK;
    }
    if (sameIID(iid, IID_IDeckLinkVideoBuffer) && bufferSize) {
      *result = static_cast<IDeckLinkVideoBuffer *>(new FakeVideoBuffer(bufferSize)); return S_OK;
    }
    if (sameIID(iid, IID_IDeckLinkVideoFrameMetadataExtensions) && metadataAvailable) {
      *result = static_cast<IDeckLinkVideoFrameMetadataExtensions *>(new FakeMetadata(metadataColorspace, metadataEOTF));
      return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG n = --references; if (!n) delete this; return n; }
  long GetWidth() override { return width; }
  long GetHeight() override { return height; }
  long GetRowBytes() override { return rowBytes; }
  BMDPixelFormat GetPixelFormat() override { return pixel; }
  BMDFrameFlags GetFlags() override {
    return (noSignal ? bmdFrameHasNoInputSource : bmdFrameFlagDefault) | (hdrFlag ? bmdFrameContainsHDRMetadata : 0);
  }
  HRESULT GetTimecode(BMDTimecodeFormat format, IDeckLinkTimecode **result) override {
    FakeTimecode *value = format == bmdTimecodeRP188HighFrameRate ? hfrTimecode : timecode;
    if (!result || !value) return E_NOTIMPL;
    value->AddRef(); *result = value; return S_OK;
  }
  HRESULT GetAncillaryData(IDeckLinkVideoFrameAncillary **) override { return E_NOTIMPL; }
  HRESULT GetStreamTime(BMDTimeValue *pts, BMDTimeValue *duration, BMDTimeScale scale) override {
    const int multiplier = scale == 240000 ? 4 : 1;
    *pts = negativeTime ? -1 : streamTime * multiplier; *duration = frameDuration * multiplier; return invalidTime ? E_FAIL : S_OK;
  }
  HRESULT GetHardwareReferenceTimestamp(BMDTimeScale scale, BMDTimeValue *time, BMDTimeValue *duration) override {
    if (!hardwareTime || scale != 1000000) return E_NOTIMPL;
    *time = hardwareTime; if (duration) *duration = 16683; return S_OK;
  }
};

FakeMacVideoBuffer::FakeMacVideoBuffer(FakeFrame *owner) : frame(owner) { frame->AddRef(); }
FakeMacVideoBuffer::~FakeMacVideoBuffer() { frame->Release(); }
HRESULT FakeMacVideoBuffer::CreateCVPixelBufferRef(void **result) {
  if (!result) return E_INVALIDARG;
  *result = nullptr;
  if (frame->badBytes) return E_FAIL;
  // An IOSurface-backed buffer like the driver's. Its attachment holds the frame
  // until the buffer's final release, as the SDK documents.
  CVPixelBufferRef buffer = nullptr;
  NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
  if (CVPixelBufferCreate(kCFAllocatorDefault, frame->wrappedWidth, frame->wrappedHeight, frame->pixel,
      (__bridge CFDictionaryRef)attributes, &buffer) != kCVReturnSuccess || !buffer) return E_FAIL;
  frame->AddRef();
  FakeFrame *owner = frame;
  id holder = [[FakeFrameLifetime alloc] initWithRelease:^{ owner->Release(); }];
  CVBufferSetAttachment(buffer, CFSTR("UltracamTestFrameLifetime"), (__bridge CFTypeRef)holder, kCVAttachmentMode_ShouldNotPropagate);
  if (frame->sdkTransfer)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, frame->sdkTransfer, kCVAttachmentMode_ShouldPropagate);
  *result = buffer;
  return S_OK;
}

class FakeMode final : public IDeckLinkDisplayMode {
 public:
  ULONG references = 1;
  BMDDisplayMode mode = bmdMode4K2160p5994;
  long width = 3840, height = 2160;
  bool invalidRate = false;
  BMDTimeScale rateScale = 0;
  BMDFieldDominance fieldDominance = bmdProgressiveFrame;
  BMDDisplayModeFlags flags = bmdDisplayModeColorspaceRec709;
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { return --references; }
  HRESULT GetName(CFStringRef *name) override { *name = CFSTR("Synthetic 4K"); CFRetain(*name); return S_OK; }
  BMDDisplayMode GetDisplayMode() override { return mode; }
  long GetWidth() override { return width; }
  long GetHeight() override { return height; }
  HRESULT GetFrameRate(BMDTimeValue *duration, BMDTimeScale *scale) override {
    *duration = 1001; *scale = rateScale ? rateScale : mode == bmdMode4K2160p2997 ? 30000 : 60000; return invalidRate ? E_FAIL : S_OK;
  }
  BMDFieldDominance GetFieldDominance() override { return fieldDominance; }
  BMDDisplayModeFlags GetFlags() override { return flags; }
};

class FakeInput final : public IDeckLinkInput {
 public:
  ULONG references = 1;
  std::vector<std::string> calls;
  HRESULT enableResult = S_OK, startResult = S_OK, callbackResult = S_OK;
  HRESULT audioResult = E_NOTIMPL;
  BMDAudioSampleRate enabledAudioRate = bmdAudioSampleRate48kHz;
  BMDAudioSampleType enabledAudioType = bmdAudioSampleType16bitInteger;
  uint32_t enabledAudioChannels = 0;
  HRESULT pauseResult = S_OK, flushResult = S_OK;
  bool reconfiguredOnMainThread = false;
  BMDDisplayMode enabledMode = bmdModeUnknown;
  BMDPixelFormat enabledPixel = bmdFormat10BitYUV;
  IDeckLinkInputCallback *callback = nullptr;
  void (^onPause)(void) = nil;
  ~FakeInput() override { if (callback) callback->Release(); }
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { return --references; }
  HRESULT DoesSupportVideoMode(BMDVideoConnection, BMDDisplayMode, BMDPixelFormat, BMDVideoInputConversionMode,
    BMDSupportedVideoModeFlags, BMDDisplayMode *, bool *supported) override { calls.push_back("support"); *supported = true; return S_OK; }
  HRESULT GetDisplayMode(BMDDisplayMode, IDeckLinkDisplayMode **) override { return E_NOTIMPL; }
  HRESULT GetDisplayModeIterator(IDeckLinkDisplayModeIterator **) override { return E_NOTIMPL; }
  HRESULT SetScreenPreviewCallback(IDeckLinkScreenPreviewCallback *) override { return E_NOTIMPL; }
  HRESULT EnableVideoInput(BMDDisplayMode mode, BMDPixelFormat format, BMDVideoInputFlags) override {
    calls.push_back("enable");
    if (mode == bmdModeUnknown || (format != bmdFormat10BitYUV && format != bmdFormat8BitYUV && format != bmdFormat10BitRGB && format != bmdFormat12BitRGBLE)) return E_INVALIDARG;
    enabledMode = mode;
    enabledPixel = format;
    return enableResult;
  }
  HRESULT DisableVideoInput() override { calls.push_back("disable"); return S_OK; }
  uint32_t availableFrames = 0;
  bool provideClock = false;
  int64_t clockOffsetMicros = 0;  // Hardware clock = host clock - offset.
  useconds_t clockDelayMicros = 0;  // A slow reference-clock read (a wide bracket).
  HRESULT GetAvailableVideoFrameCount(uint32_t *count) override {
    if (!count) return E_INVALIDARG;
    *count = availableFrames; return S_OK;
  }
  HRESULT EnableVideoInputWithAllocatorProvider(BMDDisplayMode mode, BMDPixelFormat format, BMDVideoInputFlags flags,
    IDeckLinkVideoBufferAllocatorProvider *provider) override {
    if (!provider) return E_INVALIDARG;
    const uint32_t row = format == bmdFormat12BitRGBLE ? 288 : 256;
    IDeckLinkVideoBufferAllocator *allocator = nullptr;
    if (provider->GetVideoBufferAllocator(row * 16, 64, 16, row, format, &allocator) != S_OK) return E_FAIL;
    IDeckLinkVideoBuffer *buffer = nullptr;
    const HRESULT result = allocator->AllocateVideoBuffer(&buffer); allocator->Release();
    if (result != S_OK || !buffer) return E_FAIL;
    buffer->Release();
    return EnableVideoInput(mode, format, flags);
  }
  HRESULT EnableAudioInput(BMDAudioSampleRate rate, BMDAudioSampleType type, uint32_t channels) override {
    enabledAudioRate = rate; enabledAudioType = type; enabledAudioChannels = channels; return audioResult;
  }
  HRESULT DisableAudioInput() override { return E_NOTIMPL; }
  HRESULT GetAvailableAudioSampleFrameCount(uint32_t *) override { return E_NOTIMPL; }
  HRESULT StartStreams() override { calls.push_back("start"); return startResult; }
  HRESULT StopStreams() override { calls.push_back("stop"); return S_OK; }
  HRESULT PauseStreams() override {
    calls.push_back("pause"); reconfiguredOnMainThread = [NSThread isMainThread];
    HRESULT result = pauseResult;
    void (^action)(void) = [onPause copy];
    if (action) action();
    return result;
  }
  HRESULT FlushStreams() override { calls.push_back("flush"); return flushResult; }
  HRESULT SetCallback(IDeckLinkInputCallback *value) override {
    calls.push_back(value ? "callback" : "clear");
    if (value && callbackResult != S_OK) return callbackResult;
    if (value) value->AddRef(); if (callback) callback->Release(); callback = value; return S_OK;
  }
  HRESULT GetHardwareReferenceClock(BMDTimeScale scale, BMDTimeValue *time, BMDTimeValue *inFrame, BMDTimeValue *perFrame) override {
    if (!provideClock || scale != 1000000) return E_NOTIMPL;
    if (clockDelayMicros) usleep(clockDelayMicros);
    *time = hostMicroseconds() - clockOffsetMicros; *inFrame = 0; *perFrame = 16683; return S_OK;
  }
};

class FakeConfiguration final : public IDeckLinkConfiguration {
 public:
  ULONG references = 1;
  int64_t connection = bmdVideoConnectionSDI;
  int64_t audioConnection = bmdAudioConnectionAnalog;
  HRESULT audioWriteResult = S_OK;
  bool failAudioReadback = false, audioReadbackPending = false;
  bool ignoreAudioWrites = false;
  int writes = 0, persistentWrites = 0;
  bool ignoreConnectionWrites = false;
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { return --references; }
  HRESULT SetFlag(BMDDeckLinkConfigurationID, bool) override { return E_NOTIMPL; }
  HRESULT GetFlag(BMDDeckLinkConfigurationID, bool *) override { return E_NOTIMPL; }
  HRESULT SetInt(BMDDeckLinkConfigurationID key, int64_t value) override {
    if (key == bmdDeckLinkConfigAudioInputConnection) {
      if (audioWriteResult != S_OK) return audioWriteResult;
      if (!ignoreAudioWrites) audioConnection = value;
      audioReadbackPending = failAudioReadback;
      return S_OK;
    }
    if (key != bmdDeckLinkConfigVideoInputConnection) return E_INVALIDARG;
    if (!ignoreConnectionWrites) connection = value;
    ++writes; return S_OK;
  }
  HRESULT GetInt(BMDDeckLinkConfigurationID key, int64_t *value) override {
    if (key == bmdDeckLinkConfigAudioInputConnection) {
      if (audioReadbackPending) { audioReadbackPending = false; return E_FAIL; }
      *value = audioConnection; return S_OK;
    }
    if (key != bmdDeckLinkConfigVideoInputConnection) return E_INVALIDARG;
    *value = connection; return S_OK;
  }
  HRESULT SetFloat(BMDDeckLinkConfigurationID, double) override { return E_NOTIMPL; }
  HRESULT GetFloat(BMDDeckLinkConfigurationID, double *) override { return E_NOTIMPL; }
  HRESULT SetString(BMDDeckLinkConfigurationID, CFStringRef) override { return E_NOTIMPL; }
  HRESULT GetString(BMDDeckLinkConfigurationID, CFStringRef *) override { return E_NOTIMPL; }
  HRESULT SetFlagWithParam(BMDDeckLinkConfigurationID, uint64_t, bool) override { return E_NOTIMPL; }
  HRESULT GetFlagWithParam(BMDDeckLinkConfigurationID, uint64_t, bool *) override { return E_NOTIMPL; }
  HRESULT SetIntWithParam(BMDDeckLinkConfigurationID, uint64_t, int64_t) override { return E_NOTIMPL; }
  HRESULT GetIntWithParam(BMDDeckLinkConfigurationID, uint64_t, int64_t *) override { return E_NOTIMPL; }
  HRESULT SetFloatWithParam(BMDDeckLinkConfigurationID, uint64_t, double) override { return E_NOTIMPL; }
  HRESULT GetFloatWithParam(BMDDeckLinkConfigurationID, uint64_t, double *) override { return E_NOTIMPL; }
  HRESULT SetStringWithParam(BMDDeckLinkConfigurationID, uint64_t, CFStringRef) override { return E_NOTIMPL; }
  HRESULT GetStringWithParam(BMDDeckLinkConfigurationID, uint64_t, CFStringRef *) override { return E_NOTIMPL; }
  HRESULT WriteConfigurationToPreferences() override { ++persistentWrites; return S_OK; }
};

BOOL UltracamRunRawAudioSyntheticChecks(NSError **error) {
  {  // No inner pool: a failure returns its autoreleased NSError through the out-parameter.
    __block NSData *received = nil;
    __block CMTime packetTime = kCMTimeInvalid;
    __block NSUInteger sampleFrames = 0, channels = 0, bytesPerSample = 0;
    auto framesBlock = ^(CVPixelBufferRef, CMTime, BOOL) {};
    auto eventsBlock = ^(NSString *) {};
    auto rawBlock = ^(NSData *samples, CMTime time, NSUInteger frames, NSUInteger channelCount, NSUInteger sampleBytes) {
      received = [samples copy]; packetTime = time; sampleFrames = frames;
      channels = channelCount; bytesPerSample = sampleBytes;
    };

    auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock, nil, rawBlock);
    bool destroyed = false;
    auto frame = new FakeFrame(&destroyed);
    auto audio = new FakeRawAudioPacket({INT32_MIN, 0x40000000, -123, 123});
    const int32_t expectedSamples[] = {INT32_MIN, 0x40000000, -123, 123};
    NSData *expectedData = [NSData dataWithBytes:expectedSamples length:sizeof(expectedSamples)];
    callback->VideoInputFrameArrived(frame, audio);
    audio->samples[0] = 0;
    if (!received || ![received isEqualToData:expectedData] ||
      CMTimeCompare(packetTime, CMTimeMake(48000 * 3 + 17, 48000)) != 0 ||
      sampleFrames != 2 || channels != 2 || bytesPerSample != sizeof(int32_t) || received.length != sizeof(expectedSamples))
      return fail(error, @"Raw embedded audio callback did not copy exact 48 kHz packet metadata and bytes.");
    // During HDMI reconnect Desktop Video may provide an audio packet without a
    // paired video frame. Audio has its own clock and must remain observable.
    auto audioOnly = new FakeRawAudioPacket({1, 2});
    callback->VideoInputFrameArrived(nullptr, audioOnly);
    if (!received || sampleFrames != 1 || channels != 2 || bytesPerSample != sizeof(int32_t))
      return fail(error, @"Raw audio was dropped when the paired video frame was nil.");
    audioOnly->Release();
    callback->accepting = false;
    audio->Release(); frame->Release(); callback->Release();

    FakeInput input;
    input.audioResult = S_OK;
    callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock, nil, rawBlock);
    HRESULT status = startInput(&input, callback, bmdMode4K2160p5994, bmdVideoInputFlagDefault, true);
    if (status != S_OK || input.enabledAudioRate != bmdAudioSampleRate48kHz ||
      input.enabledAudioType != bmdAudioSampleType32bitInteger || input.enabledAudioChannels != 2 ||
      !callback->audioEnabled)
      return fail(error, @"Raw embedded audio startup did not request 32-bit integer PCM.");
    stopInput(&input, callback);
    if (callback->audioEnabled) return fail(error, @"Raw embedded audio teardown left audio enabled.");
    callback->Release();
    return YES;
  }
}

// Within one callback the video frame is wrapped and handed off before the
// callback's audio is reported, and the audio is reported on every path the
// frame takes (delivered, no signal, gated, refused, absent).
BOOL UltracamRunCallbackOrderSyntheticChecks(NSError **error) {
  {  // No inner pool: a failure returns its autoreleased NSError through the out-parameter.
    // V: frame handler, M: media statistics, A: raw audio, E: event.
    std::string log;
    std::string *order = &log;  // Blocks capture the pointer.
    __block CVPixelBufferRef held = nullptr;
    auto framesBlock = ^(CVPixelBufferRef buffer, CMTime, BOOL valid) {
      *order += valid ? "V" : "v";
      if (!held) held = CVPixelBufferRetain(buffer);
    };
    auto autoFramesBlock = ^(CVPixelBufferRef, CMTime, CMTime, BOOL) { *order += "V"; };
    auto eventsBlock = ^(NSString *) { *order += "E"; };
    auto mediaBlock = ^(NSString *, CMTime, NSUInteger, NSUInteger, float, float, float, float, NSUInteger, BOOL) {
      *order += "M";
    };
    auto rawBlock = ^(NSData *samples, CMTime, NSUInteger, NSUInteger, NSUInteger) {
      *order += samples ? "A" : "a";
    };
    auto expect = [&](const char *expected, NSString *message) -> bool {
      if (log == expected) { log.clear(); return true; }
      fail(error, [NSString stringWithFormat:@"%@ Order was \"%s\", expected \"%s\".", message, log.c_str(), expected]);
      return false;
    };

    auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock, mediaBlock, rawBlock);
    bool destroyed = false;
    auto frame = new FakeFrame(&destroyed);
    auto audio = new FakeRawAudioPacket({1, 2, 3, 4});
    callback->VideoInputFrameArrived(frame, audio);
    if (!expect("VMA", @"A delivered frame was not handed off before its callback's audio.")) return NO;

    // Signal loss: the event, then the audio, with no frame delivered.
    frame->noSignal = true;
    callback->VideoInputFrameArrived(frame, audio);
    if (!expect("EMA", @"Audio was not reported after a frame without signal.")) return NO;
    frame->noSignal = false;
    frame->streamTime += frame->frameDuration;
    callback->VideoInputFrameArrived(frame, audio);
    if (!expect("VMA", @"The frame after signal returned was not handed off before its audio.")) return NO;

    // Frames gated for a format change: audio still reported.
    callback->framesEnabled = false;
    frame->streamTime += frame->frameDuration;
    callback->VideoInputFrameArrived(frame, audio);
    if (!expect("MA", @"Audio was not reported while frames were gated.")) return NO;
    callback->framesEnabled = true;

    // No video object at all (a source reconnect): audio only.
    callback->VideoInputFrameArrived(nullptr, audio);
    if (!expect("MA", @"Audio was not reported for a callback without a frame.")) return NO;

    // A refused frame (fatal): the fault, then the same callback's audio; later callbacks are ignored.
    frame->width = 1920;
    frame->streamTime += frame->frameDuration;
    callback->VideoInputFrameArrived(frame, audio);
    if (!expect("EMA", @"A refused frame's callback did not report its audio after the fault.")) return NO;
    frame->width = 3840;
    callback->VideoInputFrameArrived(frame, audio);
    if (!expect("", @"A failed capture reported a later callback.")) return NO;
    callback->Release();

    // The automatic-format handler takes the same order.
    callback = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, eventsBlock, nil, rawBlock);
    callback->autoFrameHandler = [autoFramesBlock copy];
    frame->streamTime += frame->frameDuration;
    callback->VideoInputFrameArrived(frame, audio);
    if (!expect("VA", @"The automatic-format frame was not handed off before its callback's audio.")) return NO;
    callback->accepting = false;
    callback->Release();

    if (held) { CVPixelBufferRelease(held); held = nullptr; }
    audio->Release(); frame->Release();
    if (!destroyed) return fail(error, @"The order check leaked its frame.");
    return YES;
  }
}

BOOL UltracamRunSyntheticChecks(NSError **error) {
  {  // No inner pool: a failure returns its autoreleased NSError through the out-parameter.
    __block CVPixelBufferRef retained = nullptr;
    __block int frames = 0, events = 0;
    __block int mediaCallbacks = 0;
    __block BOOL mediaTimecodeMatches = NO;
    __block BOOL mediaTimecodeAbsent = NO;
    __block CMTime mediaPacketTime = kCMTimeInvalid;
    __block NSUInteger mediaFrames = 0, mediaChannels = 0, mediaBytes = 0;
    __block float mediaLeftPeak = 0, mediaRightPeak = 0, mediaLeftRMS = 0, mediaRightRMS = 0;
    __block BOOL mediaPresent = NO;
    __block NSString *lastMessage = nil;
    __block CMTime timestamp = kCMTimeInvalid;
    auto framesBlock = ^(CVPixelBufferRef buffer, CMTime pts, BOOL valid) {
      if (valid) { ++frames; timestamp = pts; retained = CVPixelBufferRetain(buffer); }
    };
    auto eventsBlock = ^(NSString *message) { ++events; lastMessage = message; };
    auto mediaBlock = ^(NSString *timecode, CMTime packetTime, NSUInteger sampleFrames,
      NSUInteger channels, float leftPeak, float rightPeak, float leftRMS, float rightRMS,
      NSUInteger bytes, BOOL present) {
      ++mediaCallbacks; mediaTimecodeMatches = [timecode isEqualToString:@"01:02:03;08"]; mediaTimecodeAbsent = timecode == nil; mediaPacketTime = packetTime;
      mediaFrames = sampleFrames; mediaChannels = channels; mediaBytes = bytes;
      mediaLeftPeak = leftPeak; mediaRightPeak = rightPeak; mediaLeftRMS = leftRMS;
      mediaRightRMS = rightRMS; mediaPresent = present;
    };
    auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock, mediaBlock);
    bool destroyed = false;
    auto frame = new FakeFrame(&destroyed);
    auto timecode = new FakeTimecode(); frame->timecode = timecode;
    auto audio = new FakeAudioPacket({INT16_MIN, 16384, 8192, -16384});
    callback->VideoInputFrameArrived(frame, audio);
    if (frames != 1 || !retained || CMTimeCompare(timestamp, CMTimeMake(123123, 60000)) != 0 ||
      CVPixelBufferGetPixelFormatType(retained) != kCVPixelFormatType_422YpCbCr10 || frame->references != 2 ||
      mediaCallbacks != 1 || !mediaTimecodeMatches ||
      CMTimeCompare(mediaPacketTime, CMTimeMake(960, 48000)) != 0 || mediaFrames != 2 ||
      mediaChannels != 2 || mediaBytes != 16 || !mediaPresent || mediaLeftPeak != 1.0f ||
      mediaRightPeak != 0.5f || std::abs(mediaLeftRMS - 0.728868f) > 0.0001f ||
      std::abs(mediaRightRMS - 0.5f) > 0.0001f)
      return fail(error, @"Native frame/media format, timing, metadata or reference test failed.");
    audio->Release(); frame->timecode = nullptr; timecode->Release();
    frame->Release();
    if (destroyed) return fail(error, @"Native frame was freed while Swift retained its pixel buffer.");
    callback->accepting = false;
    CVPixelBufferRelease(retained); retained = nullptr;
    if (!destroyed) return fail(error, @"Native frame leaked after final pixel buffer release.");
    callback->Release();

    // Lost signal is reported once per transition; stop rejects late frames.
    destroyed = false; frame = new FakeFrame(&destroyed); frame->noSignal = true;
    callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock);
    callback->VideoInputFrameArrived(frame, nullptr); callback->VideoInputFrameArrived(frame, nullptr);
    if (events != 1 || frames != 1) return fail(error, @"No-signal event deduplication failed.");
    callback->accepting = false; frame->noSignal = false;
    callback->VideoInputFrameArrived(frame, nullptr);
    if (frames != 1) return fail(error, @"Stopped callback delivered a late frame.");
    frame->Release(); callback->Release();

    // A media callback without a valid packet must not fabricate channel
    // metadata. The callback still runs so consumers can clear stale meters.
    mediaCallbacks = 0; mediaChannels = 99; mediaPresent = YES; mediaTimecodeAbsent = NO;
    destroyed = false; frame = new FakeFrame(&destroyed);
    auto emptyTimecode = new FakeTimecode(); emptyTimecode->value = CFSTR(""); emptyTimecode->componentsFail = true; frame->timecode = emptyTimecode;
    callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock, mediaBlock);
    callback->VideoInputFrameArrived(frame, nullptr);
    if (mediaCallbacks != 1 || !mediaTimecodeAbsent || mediaChannels != 0 || mediaPresent || mediaFrames != 0 || mediaBytes != 0)
      return fail(error, @"Missing embedded audio fabricated packet metadata.");
    frame->timecode = nullptr; emptyTimecode->Release();
    callback->accepting = false; if (retained) { CVPixelBufferRelease(retained); retained = nullptr; }
    frame->Release(); callback->Release();
    for (int scenario = 0; scenario != 5; ++scenario) {
      destroyed = false; frame = new FakeFrame(&destroyed);
      if (scenario == 0) frame->width = 1920;
      if (scenario == 1) frame->invalidTime = true;
      if (scenario == 2) frame->badBytes = true;
      if (scenario == 3) frame->frameDuration = 1000;
      if (scenario == 4) frame->negativeTime = true;
      events = 0;
      callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock);
      callback->VideoInputFrameArrived(frame, nullptr); callback->VideoInputFrameArrived(frame, nullptr);
      if (events != 1 || callback->accepting || frames != 2 || ![lastMessage hasPrefix:@"Capture error: "])
        return fail(error, @"Invalid native frame did not stop with one permanent capture error.");
      if (retained) { CVPixelBufferRelease(retained); retained = nullptr; }
      frame->Release(); callback->Release();
      if (!destroyed) return fail(error, @"Rejected native frame leaked.");
    }
    // Success and every partial startup failure must detach the callback and
    // disable the input; restart constructs a fresh accepting callback.
    for (int scenario = 0; scenario != 4; ++scenario) {
      FakeInput input;
      if (scenario == 1) input.callbackResult = E_FAIL;
      if (scenario == 2) input.enableResult = E_ACCESSDENIED;
      if (scenario == 3) input.startResult = E_FAIL;
      callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock);
      HRESULT status = startInput(&input, callback, bmdMode4K2160p5994, bmdVideoInputFlagDefault);
      if ((scenario == 0) != (status == S_OK)) return fail(error, @"SDK startup did not preserve failure status.");
      const bool audioRequested = scenario == 0 || scenario == 3;  // Video enabled and callback installed.
      if (audioRequested && (input.enabledAudioType != bmdAudioSampleType32bitInteger || input.enabledAudioChannels != 2))
        return fail(error, @"Stats startup did not request 32-bit stereo embedded audio.");
      if (scenario == 0) stopInput(&input, callback);
      if (input.callback || callback->accepting || callback->references != 1 || input.calls.size() < 4 ||
        input.calls[input.calls.size() - 3] != "stop" || input.calls[input.calls.size() - 2] != "clear" || input.calls.back() != "disable")
        return fail(error, @"SDK teardown order or callback references failed.");
      callback->Release();
    }
    events = 0;
    callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock);
    FakeMode mode;
    callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, bmdDetectedVideoInputYCbCr422);
    if (events || !callback->accepting) return fail(error, @"Matching input detection incorrectly stopped capture.");
    mode.mode = bmdMode4K2160p2997;
    callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, bmdDetectedVideoInputYCbCr422);
    callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, bmdDetectedVideoInputYCbCr422);
    if (events != 1 || callback->accepting) return fail(error, @"Mode change did not reject frames with one error.");
    callback->Release();

    FakeConfiguration configuration;
    {
      HDMILease lease; lease.configuration.value = &configuration; configuration.AddRef();
      lease.previous = bmdVideoConnectionSDI; lease.changed = true;
      configuration.connection = bmdVideoConnectionHDMI;
    }
    if (configuration.connection != bmdVideoConnectionSDI || configuration.writes != 1 || configuration.references != 1)
      return fail(error, @"HDMI lease failed to restore the original connection.");
    {
      HDMILease lease; lease.configuration.value = &configuration; configuration.AddRef();
      lease.previous = bmdVideoConnectionSDI; lease.changed = true;
      configuration.connection = bmdVideoConnectionOpticalSDI;
    }
    if (configuration.connection != bmdVideoConnectionOpticalSDI || configuration.writes != 1 || configuration.persistentWrites != 0)
      return fail(error, @"HDMI lease clobbered a later owner or persisted settings.");

    // Automatic-format startup supplies no ordinary frame handler. Verify the
    // callback adapter also remains safe when an event block is absent, as can
    // happen on a failed/partial startup callback or a future API caller.
    callback = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, nil);
    if (!callback->frameHandler || !callback->eventHandler)
      return fail(error, @"Capture callback did not install safe no-op handlers.");
    callback->accepting = false;
    callback->Release();
    return YES;
  }
}

// MARK: SDK 16 device fakes. Stack objects with non-deleting reference counts.

class FakeAttributes final : public IDeckLinkProfileAttributes {
 public:
  ULONG references = 1;
  int64_t persistentID = 0x1234abcd;
  HRESULT persistentIDResult = S_OK;
  bool formatDetection = true, hdrMetadata = true, colorspaceMetadata = true;
  bool hdmiTimecode = true, highFrameRateTimecode = false;
  int64_t maximumHDMIAudioChannels = 8, maximumAudioChannels = 16;
  int64_t audioInputConnections = bmdAudioConnectionEmbedded | bmdAudioConnectionAnalog;
  int64_t videoInputConnections = bmdVideoConnectionHDMI;
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { return --references; }
  HRESULT GetFlag(BMDDeckLinkAttributeID key, bool *value) override {
    switch (key) {
      case BMDDeckLinkSupportsInputFormatDetection: *value = formatDetection; return S_OK;
      case BMDDeckLinkSupportsHDRMetadata: *value = hdrMetadata; return S_OK;
      case BMDDeckLinkSupportsColorspaceMetadata: *value = colorspaceMetadata; return S_OK;
      case BMDDeckLinkSupportsHDMITimecode: *value = hdmiTimecode; return S_OK;
      case BMDDeckLinkSupportsHighFrameRateTimecode: *value = highFrameRateTimecode; return S_OK;
      default: return E_INVALIDARG;
    }
  }
  HRESULT GetInt(BMDDeckLinkAttributeID key, int64_t *value) override {
    if (key == BMDDeckLinkMaximumAudioChannels) { *value = maximumAudioChannels; return S_OK; }
    if (key == BMDDeckLinkAudioInputConnections) { *value = audioInputConnections; return S_OK; }
    if (key == BMDDeckLinkVideoInputConnections) { *value = videoInputConnections; return S_OK; }
    if (key == BMDDeckLinkPersistentID) { *value = persistentID; return persistentIDResult; }
    if (key == BMDDeckLinkMaximumHDMIAudioChannels) { if (maximumHDMIAudioChannels <= 0) return E_INVALIDARG; *value = maximumHDMIAudioChannels; return S_OK; }
    return E_INVALIDARG;
  }
  HRESULT GetFloat(BMDDeckLinkAttributeID, double *) override { return E_NOTIMPL; }
  HRESULT GetString(BMDDeckLinkAttributeID, CFStringRef *) override { return E_NOTIMPL; }
  HRESULT GetStringWithParam(BMDDeckLinkAttributeID, uint64_t, CFStringRef *) override { return E_NOTIMPL; }
};

class FakeStatus final : public IDeckLinkStatus {
 public:
  ULONG references = 1;
  bool available = true, interfaceAvailable = true;
  FakeMode detectedMode;
  int64_t formatFlags = bmdDetectedVideoInputYCbCr422 | bmdDetectedVideoInput10BitDepth;
  int64_t colorspace = bmdColorspaceRec709, dynamicRange = bmdDynamicRangeSDR;
  int64_t busy = 0;  // BMDDeviceBusyState
  bool locked = true;
  FakeStatus() { detectedMode.mode = bmdMode4K2160p2997; }
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { return --references; }
  HRESULT GetFlag(BMDDeckLinkStatusID key, bool *value) override {
    if (key != bmdDeckLinkStatusVideoInputSignalLocked) return E_INVALIDARG;
    *value = locked; return S_OK;
  }
  HRESULT GetInt(BMDDeckLinkStatusID key, int64_t *value) override {
    if (!available) return E_FAIL;
    switch (key) {
      case bmdDeckLinkStatusDetectedVideoInputMode: *value = detectedMode.mode; return S_OK;
      case bmdDeckLinkStatusDetectedVideoInputFormatFlags: *value = formatFlags; return S_OK;
      case bmdDeckLinkStatusDetectedVideoInputColorspace: *value = colorspace; return S_OK;
      case bmdDeckLinkStatusDetectedVideoInputDynamicRange: *value = dynamicRange; return S_OK;
      case bmdDeckLinkStatusBusy: *value = busy; return S_OK;
      default: return E_INVALIDARG;
    }
  }
  HRESULT GetFloat(BMDDeckLinkStatusID, double *) override { return E_NOTIMPL; }
  HRESULT GetString(BMDDeckLinkStatusID, CFStringRef *) override { return E_NOTIMPL; }
  HRESULT GetBytes(BMDDeckLinkStatusID, void *, uint32_t *) override { return E_NOTIMPL; }
  HRESULT GetInterface(BMDDeckLinkStatusID key, void **result) override {
    if (!available || !interfaceAvailable || key != bmdDeckLinkStatusDetectedVideoInputMode) return E_NOTIMPL;
    detectedMode.AddRef(); *result = static_cast<IDeckLinkDisplayMode *>(&detectedMode); return S_OK;
  }
  HRESULT GetFlagWithParam(BMDDeckLinkStatusID, uint64_t, bool *) override { return E_NOTIMPL; }
  HRESULT GetIntWithParam(BMDDeckLinkStatusID, uint64_t, int64_t *) override { return E_NOTIMPL; }
  HRESULT GetFloatWithParam(BMDDeckLinkStatusID, uint64_t, double *) override { return E_NOTIMPL; }
  HRESULT GetStringWithParam(BMDDeckLinkStatusID, uint64_t, CFStringRef *) override { return E_NOTIMPL; }
  HRESULT GetBytesWithParam(BMDDeckLinkStatusID, uint64_t, void *, uint32_t *) override { return E_NOTIMPL; }
};

class FakeEDID final : public IDeckLinkHDMIInputEDID {
 public:
  ULONG references = 1;
  int64_t value = bmdDynamicRangeSDR | bmdDynamicRangeHDRStaticPQ;
  int writes = 0;
  HRESULT writeResult = S_OK;
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  // Like the driver: the final release restores the default EDID.
  ULONG Release() override {
    if (--references == 1) value = bmdDynamicRangeSDR | bmdDynamicRangeHDRStaticPQ;
    return references;
  }
  HRESULT SetInt(BMDDeckLinkHDMIInputEDIDID key, int64_t next) override {
    if (key != bmdDeckLinkHDMIInputEDIDDynamicRange) return E_INVALIDARG;
    value = next; return S_OK;
  }
  HRESULT GetInt(BMDDeckLinkHDMIInputEDIDID key, int64_t *current) override {
    if (key != bmdDeckLinkHDMIInputEDIDDynamicRange) return E_INVALIDARG;
    *current = value; return S_OK;
  }
  HRESULT WriteToEDID() override { ++writes; return writeResult; }
};

class FakeNotification final : public IDeckLinkNotification {
 public:
  ULONG references = 1;
  std::vector<std::pair<BMDNotifications, IDeckLinkNotificationCallback *>> subscriptions;
  ~FakeNotification() { for (auto &entry : subscriptions) entry.second->Release(); }
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { return --references; }
  HRESULT Subscribe(BMDNotifications topic, IDeckLinkNotificationCallback *callback) override {
    callback->AddRef(); subscriptions.push_back({topic, callback}); return S_OK;
  }
  HRESULT Unsubscribe(BMDNotifications topic, IDeckLinkNotificationCallback *callback) override {
    for (auto it = subscriptions.begin(); it != subscriptions.end(); ++it) {
      if (it->first != topic || it->second != callback) continue;
      it->second->Release(); subscriptions.erase(it); return S_OK;
    }
    return E_INVALIDARG;
  }
  void post(BMDNotifications topic, uint64_t parameter) {
    for (auto &entry : subscriptions) if (entry.first == topic) entry.second->Notify(topic, parameter, 0);
  }
};

class FakeStatistics final : public IDeckLinkStatistics {
 public:
  ULONG references = 1;
  int64_t temperature = 47;
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { return --references; }
  HRESULT GetInt(BMDDeckLinkStatisticID key, int64_t *value) override {
    if (key != bmdDeckLinkStatisticDeviceTemperature) return E_INVALIDARG;
    *value = temperature; return S_OK;
  }
  HRESULT GetIntWithParam(BMDDeckLinkStatisticID, uint64_t, int64_t *) override { return E_NOTIMPL; }
  HRESULT GetStringWithParam(BMDDeckLinkStatisticID, uint64_t, CFStringRef *) override { return E_NOTIMPL; }
};

class FakeDeckLink final : public IDeckLink {
 public:
  ULONG references = 1;
  CFStringRef name = CFSTR("UltraStudio Mini Recorder 12G");
  bool hasInput = true, hasStatus = true, hasEDID = true;
  FakeInput input;
  FakeConfiguration configuration;
  FakeAttributes attributes;
  FakeStatus status;
  FakeEDID edid;
  FakeNotification notification;
  FakeStatistics statistics;
  HRESULT QueryInterface(REFIID iid, LPVOID *result) override {
    *result = nullptr;
    IUnknown *found = nullptr;
    if (sameIID(iid, IID_IDeckLinkInput) && hasInput) found = &input;
    else if (sameIID(iid, IID_IDeckLinkConfiguration)) found = &configuration;
    else if (sameIID(iid, IID_IDeckLinkProfileAttributes)) found = &attributes;
    else if (sameIID(iid, IID_IDeckLinkStatus) && hasStatus) found = &status;
    else if (sameIID(iid, IID_IDeckLinkHDMIInputEDID) && hasEDID) found = &edid;
    else if (sameIID(iid, IID_IDeckLinkNotification)) found = &notification;
    else if (sameIID(iid, IID_IDeckLinkStatistics)) found = &statistics;
    if (!found) return E_NOINTERFACE;
    found->AddRef(); *result = found; return S_OK;
  }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { return --references; }
  HRESULT GetModelName(CFStringRef *value) override { *value = static_cast<CFStringRef>(CFRetain(name)); return S_OK; }
  HRESULT GetDisplayName(CFStringRef *value) override { *value = static_cast<CFStringRef>(CFRetain(name)); return S_OK; }
  bool balanced() const {
    return references == 1 && input.references == 1 && configuration.references == 1 && attributes.references == 1 &&
      status.references == 1 && edid.references == 1 && notification.references == 1 && statistics.references == 1 &&
      status.detectedMode.references == 1;
  }
};

class FakeAPIInformation final : public IDeckLinkAPIInformation {
 public:
  ULONG references = 1;
  int64_t version;
  CFStringRef text;
  FakeAPIInformation(int64_t value, CFStringRef display) : version(value), text(display) {}
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { return --references; }
  HRESULT GetFlag(BMDDeckLinkAPIInformationID, bool *) override { return E_NOTIMPL; }
  HRESULT GetInt(BMDDeckLinkAPIInformationID key, int64_t *value) override {
    if (key != BMDDeckLinkAPIVersion) return E_INVALIDARG;
    *value = version; return S_OK;
  }
  HRESULT GetFloat(BMDDeckLinkAPIInformationID, double *) override { return E_NOTIMPL; }
  HRESULT GetString(BMDDeckLinkAPIInformationID key, CFStringRef *value) override {
    if (key != BMDDeckLinkAPIVersion || !text) return E_NOTIMPL;
    *value = static_cast<CFStringRef>(CFRetain(text)); return S_OK;
  }
};

static NSString *attachmentString(CVPixelBufferRef buffer, CFStringRef key) {
  return CFBridgingRelease(CVBufferCopyAttachment(buffer, key, nullptr));
}

// Frame-level SDK 16 features, through the production callback.
static BOOL runFrameFeatureChecks(NSError **error) {
  {  // No inner pool: a failure returns its autoreleased NSError through the out-parameter.
    __block CVPixelBufferRef retained = nullptr;
    __block NSString *timecodeText = nil;
    __block int frames = 0, events = 0;
    __block NSString *lastMessage = nil;
    auto framesBlock = ^(CVPixelBufferRef buffer, CMTime, BOOL valid) {
      if (!valid) return;
      ++frames;
      if (retained) CVPixelBufferRelease(retained);
      retained = CVPixelBufferRetain(buffer);
    };
    auto eventsBlock = ^(NSString *message) { ++events; lastMessage = message; };
    auto mediaBlock = ^(NSString *timecode, CMTime, NSUInteger, NSUInteger, float, float, float, float, NSUInteger, BOOL) {
      timecodeText = timecode;
    };
    auto releaseRetained = ^{ if (retained) { CVPixelBufferRelease(retained); retained = nullptr; } };

    // Timecode: RP188 at 59.94 counts 0-29 with a field mark on the second
    // frame of each pair; HFRTC already counts 0-59; 29.97 is unchanged.
    {
      bool destroyed = false;
      auto frame = new FakeFrame(&destroyed);
      auto timecode = new FakeTimecode(); frame->timecode = timecode;
      auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock, mediaBlock);
      timecode->frames = 14; timecode->flags = bmdTimecodeFieldMark;
      callback->VideoInputFrameArrived(frame, nullptr);
      if (![timecodeText isEqualToString:@"01:02:03:29"]) return fail(error, @"Field-marked RP188 frame was not converted to the 59.94 label.");
      timecode->flags = bmdTimecodeIsDropFrame;
      callback->VideoInputFrameArrived(frame, nullptr);
      if (![timecodeText isEqualToString:@"01:02:03;28"]) return fail(error, @"59.94 drop-frame RP188 label was wrong.");
      auto hfr = new FakeTimecode(); hfr->frames = 45; hfr->flags = bmdTimecodeFlagDefault; frame->hfrTimecode = hfr;
      callback->VideoInputFrameArrived(frame, nullptr);
      if (![timecodeText isEqualToString:@"01:02:03:45"]) return fail(error, @"HFR timecode was doubled or ignored.");
      frame->hfrTimecode = nullptr; hfr->Release();
      callback->accepting = false; callback->Release();

      // A device counting 0-59 without HFRTC: one frame per label. Four
      // consecutive +1 steps prove it, so at most the first four are doubled.
      callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock, mediaBlock);
      timecode->flags = bmdTimecodeFlagDefault;
      NSMutableArray<NSString *> *labels = [NSMutableArray array];
      for (uint8_t value = 10; value != 17; ++value) {
        timecode->frames = value;
        callback->VideoInputFrameArrived(frame, nullptr);
        [labels addObject:timecodeText ?: @"nil"];
      }
      if (![labels isEqualToArray:@[@"01:02:03:20", @"01:02:03:22", @"01:02:03:24", @"01:02:03:26",
            @"01:02:03:14", @"01:02:03:15", @"01:02:03:16"]])
        return fail(error, [@"Full-rate RP188 was not recognised after four steps: " stringByAppendingString:[labels componentsJoinedByString:@" "]]);
      // An unchanged label reuses its string instead of formatting a new one.
      NSString *previous = timecodeText;
      callback->VideoInputFrameArrived(frame, nullptr);
      if (timecodeText != previous) return fail(error, @"An unchanged RP188 label was formatted again.");
      // Signal loss relearns the cadence, but meanwhile labels follow the
      // one latched before, so a full-rate source is not shown doubled again.
      frame->noSignal = true;
      callback->VideoInputFrameArrived(frame, nullptr);
      frame->noSignal = false; timecode->frames = 5; timecode->flags = bmdTimecodeFieldMark;
      callback->VideoInputFrameArrived(frame, nullptr);
      if (![timecodeText isEqualToString:@"01:02:03:05"]) return fail(error, @"Full-rate RP188 was doubled again after signal loss.");
      // A pair counter after it is recognised by its own evidence.
      for (uint8_t value = 6; value != 9; ++value) {
        timecode->frames = value; timecode->flags = bmdTimecodeFlagDefault;
        callback->VideoInputFrameArrived(frame, nullptr);
        timecode->flags = bmdTimecodeFieldMark;
        callback->VideoInputFrameArrived(frame, nullptr);
      }
      if (![timecodeText isEqualToString:@"01:02:03:17"]) return fail(error, @"A pair counter after signal loss was not recognised.");
      callback->accepting = false; callback->Release();

      // 59.94 drop-frame skips labels 00-03 at a minute not divisible by
      // ten: a full-rate count goes 59 -> 04. That boundary keeps the evidence.
      callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock, mediaBlock);
      timecode->flags = bmdTimecodeIsDropFrame; timecode->seconds = 59;
      for (uint8_t value = 56; value != 60; ++value) { timecode->frames = value; callback->VideoInputFrameArrived(frame, nullptr); }
      timecode->minutes = 3; timecode->seconds = 0;
      for (uint8_t value = 4; value != 8; ++value) { timecode->frames = value; callback->VideoInputFrameArrived(frame, nullptr); }
      if (![timecodeText isEqualToString:@"01:03:00;07"])
        return fail(error, [@"A drop-frame minute boundary reset the full-rate RP188 evidence: " stringByAppendingString:timecodeText ?: @"nil"]);
      timecode->minutes = 2; timecode->seconds = 3;
      callback->accepting = false; callback->Release();

      // A pair counter (repeat, +1, ...) with one corrupt label above 29: the
      // label is rejected and the cadence does not latch to full rate.
      callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock, mediaBlock);
      auto pair = [&](uint8_t value, bool second) {
        timecode->frames = value; timecode->flags = second ? bmdTimecodeFieldMark : bmdTimecodeFlagDefault;
        callback->VideoInputFrameArrived(frame, nullptr);
      };
      for (uint8_t value = 5; value != 9; ++value) { pair(value, false); pair(value, true); }
      if (![timecodeText isEqualToString:@"01:02:03:17"]) return fail(error, @"Paired RP188 was not doubled.");
      pair(31, false);
      if (timecodeText) return fail(error, @"A corrupt RP188 label above 29 was reported at 59.94.");
      pair(9, false);
      if (![timecodeText isEqualToString:@"01:02:03:18"]) return fail(error, @"One corrupt RP188 label latched full-rate counting.");
      pair(9, true);
      if (![timecodeText isEqualToString:@"01:02:03:19"]) return fail(error, @"Paired RP188 lost its field mark after a corrupt label.");
      // A reconfiguration also starts over, following the latched cadence meanwhile.
      for (uint8_t value = 20; value != 26; ++value) pair(value, false);
      if (![timecodeText isEqualToString:@"01:02:03:25"]) return fail(error, @"Full-rate RP188 was not recognised after a pair counter.");
      callback->resetTimecodeCadence = true;
      pair(4, false);
      if (![timecodeText isEqualToString:@"01:02:03:04"]) return fail(error, @"A reconfiguration doubled a full-rate RP188 label.");
      for (uint8_t value = 5; value != 8; ++value) { pair(value, false); pair(value, true); }
      if (![timecodeText isEqualToString:@"01:02:03:15"]) return fail(error, @"A reconfiguration did not relearn the RP188 cadence.");
      callback->accepting = false; callback->Release();
      // 29.97: labels pass through, with the field mark ignored.
      callback = new CaptureCallback(bmdMode4K2160p2997, 30000, framesBlock, eventsBlock, mediaBlock);
      frame->frameDuration = 1001; timecode->frames = 14; timecode->flags = bmdTimecodeFieldMark | bmdTimecodeIsDropFrame;
      callback->VideoInputFrameArrived(frame, nullptr);
      if (![timecodeText isEqualToString:@"01:02:03;14"]) return fail(error, @"29.97 RP188 label was altered.");
      // Components unavailable: the SDK string is reported as-is.
      timecode->componentsFail = true;
      callback->VideoInputFrameArrived(frame, nullptr);
      if (![timecodeText isEqualToString:@"01:02:03:04"]) return fail(error, @"Timecode string fallback was lost.");
      callback->accepting = false; callback->Release();
      releaseRetained();
      frame->timecode = nullptr; timecode->Release(); frame->Release();
      if (!destroyed) return fail(error, @"Timecode fixture leaked its frame.");
    }

    // Host capture time: the hardware reference clock mapped onto the host clock.
    {
      FakeInput input; input.provideClock = true; input.clockOffsetMicros = 5000000;
      HostClockSample sample;
      if (!sampleHostOffset(&input, &sample) || std::llabs(sample.offsetMicros - 5000000) > 1000 ||
          sample.windowMicros >= kMaximumHostWindowMicros)
        return fail(error, @"Hardware reference clock was not mapped to the host clock.");
      FakeInput silent;
      if (sampleHostOffset(&silent, &sample)) return fail(error, @"Unavailable reference clock produced a host mapping.");
      FakeInput slow; slow.provideClock = true; slow.clockDelayMicros = 2500;
      if (sampleHostOffset(&slow, &sample)) return fail(error, @"A reference-clock read with a 2.5 ms bracket was accepted.");
      // The filter keeps the narrowest bracket of recent polls, smooths
      // toward it, ignores wide brackets and adopts a genuine step at once.
      HostOffsetFilter filter;
      int64_t offset = 0;
      if (filter.offer(HostClockSample{1000, 1500}, &offset)) return fail(error, @"A 1.5 ms bracket produced a host offset.");
      if (!filter.offer(HostClockSample{1000, 400}, &offset) || offset != 1000)
        return fail(error, @"The first usable bracket did not set the host offset.");
      if (!filter.offer(HostClockSample{1400, 900}, &offset) || offset != 1000)
        return fail(error, @"A wider bracket moved the host offset.");
      if (!filter.offer(HostClockSample{1200, 50}, &offset) || offset != 1050)
        return fail(error, @"A narrower bracket was not smoothed in.");
      if (!filter.offer(HostClockSample{900, 800}, &offset) || offset != 1088)
        return fail(error, @"The filter did not keep the narrowest bracket.");
      if (!filter.offer(HostClockSample{1000, 5000}, &offset) || offset != 1088)
        return fail(error, @"A rejected bracket changed the host offset.");
      if (!filter.offer(HostClockSample{90000, 200}, &offset) || offset != 90000)
        return fail(error, @"A tight reading far from the estimate was not adopted as a step.");
      bool destroyed = false;
      auto frame = new FakeFrame(&destroyed);
      frame->hardwareTime = 42000000;
      auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock);
      callback->VideoInputFrameArrived(frame, nullptr);
      if (!retained || CVBufferCopyAttachment(retained, CFSTR("UltracamCaptureHostTime"), nullptr))
        return fail(error, @"Host capture time was attached before the clock was mapped.");
      callback->stats->hostOffsetMicros = 5000000; callback->stats->hostOffsetValid = true;
      callback->VideoInputFrameArrived(frame, nullptr);
      NSNumber *host = CFBridgingRelease(CVBufferCopyAttachment(retained, CFSTR("UltracamCaptureHostTime"), nullptr));
      if (![host isKindOfClass:[NSNumber class]] || CFNumberGetType((__bridge CFNumberRef)host) != kCFNumberFloat64Type ||
          std::abs(host.doubleValue - 47.0) > 1e-9)
        return fail(error, @"Host capture time attachment was missing or not a Float64 in host seconds.");
      frame->hardwareTime = 0;
      callback->VideoInputFrameArrived(frame, nullptr);
      if (CVBufferCopyAttachment(retained, CFSTR("UltracamCaptureHostTime"), nullptr))
        return fail(error, @"A frame without a hardware timestamp carried a host capture time.");
      callback->accepting = false; callback->Release();
      releaseRetained(); frame->Release();
      if (!destroyed) return fail(error, @"Host-time fixture leaked its frame.");
    }

    // Device drops from stream-time gaps; signal loss and restarts start over.
    {
      bool destroyed = false;
      auto frame = new FakeFrame(&destroyed);
      auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock);
      for (BMDTimeValue time : {0, 1001, 3003, 7007, 8008}) { frame->streamTime = time; callback->VideoInputFrameArrived(frame, nullptr); }
      if (callback->stats->deviceDrops != 4) return fail(error, @"Stream-time gaps were not counted as device drops.");
      frame->noSignal = true; frame->streamTime = 9009; callback->VideoInputFrameArrived(frame, nullptr);
      frame->noSignal = false; frame->streamTime = 90090; callback->VideoInputFrameArrived(frame, nullptr);
      callback->resetStreamClock = true; frame->streamTime = 1001; callback->VideoInputFrameArrived(frame, nullptr);
      frame->streamTime = 2002; callback->VideoInputFrameArrived(frame, nullptr);
      if (callback->stats->deviceDrops != 4) return fail(error, @"Signal loss or a driver restart was counted as device drops.");
      callback->accepting = false; callback->Release();
      releaseRetained(); frame->Release();
      if (!destroyed) return fail(error, @"Drop fixture leaked its frame.");
    }

    // IDeckLinkVideoBuffer::GetSize validation; a missing interface is tolerated.
    {
      bool destroyed = false;
      auto frame = new FakeFrame(&destroyed);
      frame->bufferSize = 10240 * 2160;
      events = 0; frames = 0;
      auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock);
      callback->VideoInputFrameArrived(frame, nullptr);
      if (frames != 1 || events) return fail(error, @"A full-size frame buffer was rejected.");
      frame->bufferSize = 10240 * 2000;
      callback->VideoInputFrameArrived(frame, nullptr);
      if (frames != 1 || events != 1 || callback->accepting || ![lastMessage containsString:@"byte frame buffer"])
        return fail(error, @"A short frame buffer was not rejected with one capture error.");
      callback->Release();
      releaseRetained(); frame->Release();
      if (!destroyed) return fail(error, @"Buffer-size fixture leaked its frame.");
    }

    // Colorimetry: frame metadata overrides; detection fills only empty keys.
    {
      bool destroyed = false;
      auto frame = new FakeFrame(&destroyed);
      auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock);
      callback->signalColorspace = bmdColorspaceRec709;
      callback->VideoInputFrameArrived(frame, nullptr);
      if (![attachmentString(retained, kCVImageBufferYCbCrMatrixKey) isEqualToString:(__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_709_2] ||
          ![attachmentString(retained, kCVImageBufferColorPrimariesKey) isEqualToString:(__bridge NSString *)kCVImageBufferColorPrimaries_ITU_R_709_2] ||
          attachmentString(retained, kCVImageBufferTransferFunctionKey))
        return fail(error, @"Detected Rec.709 was not attached, or an unknown transfer function was invented.");
      callback->supportsHDRMetadata = true; callback->supportsColorspaceMetadata = true;
      frame->metadataAvailable = true; frame->hdrFlag = true;
      frame->metadataColorspace = bmdColorspaceRec2020; frame->metadataEOTF = 3;
      frame->sdkTransfer = kCVImageBufferTransferFunction_ITU_R_709_2;
      callback->VideoInputFrameArrived(frame, nullptr);
      if (![attachmentString(retained, kCVImageBufferYCbCrMatrixKey) isEqualToString:(__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_2020] ||
          ![attachmentString(retained, kCVImageBufferColorPrimariesKey) isEqualToString:(__bridge NSString *)kCVImageBufferColorPrimaries_ITU_R_2020] ||
          ![attachmentString(retained, kCVImageBufferTransferFunctionKey) isEqualToString:(__bridge NSString *)kCVImageBufferTransferFunction_ITU_R_2100_HLG] ||
          callback->observedEOTF != 3 || callback->observedColorspace != bmdColorspaceRec2020)
        return fail(error, @"HLG Rec.2020 frame metadata did not override the buffer attachments.");
      frame->metadataEOTF = 2;
      callback->VideoInputFrameArrived(frame, nullptr);
      if (![attachmentString(retained, kCVImageBufferTransferFunctionKey) isEqualToString:(__bridge NSString *)kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ])
        return fail(error, @"PQ frame metadata was not attached.");
      // No HDR InfoFrame on an HDR-capable device: SDR, but never over the SDK's own value.
      frame->hdrFlag = false; frame->sdkTransfer = kCVImageBufferTransferFunction_SMPTE_ST_428_1;
      callback->VideoInputFrameArrived(frame, nullptr);
      if (![attachmentString(retained, kCVImageBufferTransferFunctionKey) isEqualToString:(__bridge NSString *)kCVImageBufferTransferFunction_SMPTE_ST_428_1] ||
          callback->observedEOTF != kEOTFUnknown)
        return fail(error, @"Inferred SDR overrode the SDK transfer function or counted as frame metadata.");
      frame->sdkTransfer = nullptr;
      callback->VideoInputFrameArrived(frame, nullptr);
      if (![attachmentString(retained, kCVImageBufferTransferFunctionKey) isEqualToString:(__bridge NSString *)kCVImageBufferTransferFunction_ITU_R_709_2])
        return fail(error, @"An SDR frame without SDK colorimetry was not labelled Rec.709.");
      callback->accepting = false; callback->Release();
      releaseRetained(); frame->Release();
      if (!destroyed) return fail(error, @"Colorimetry fixture leaked its frame.");
    }

    // EDID: advertise SDR | PQ | HLG; the held reference keeps it, the last release restores.
    {
      FakeDeckLink device;
      {
        ComRef<IDeckLinkHDMIInputEDID> held;
        if (advertiseHDR(&device, held) != S_OK || !held || device.edid.writes != 1 ||
            device.edid.value != kAdvertisedDynamicRange || device.edid.references != 2)
          return fail(error, @"HLG was not written to the HDMI EDID.");
        ComRef<IDeckLinkHDMIInputEDID> again;
        if (advertiseHDR(&device, again) != S_FALSE || !again || device.edid.writes != 1 || device.edid.references != 3)
          return fail(error, @"An EDID already advertising HLG was rewritten or not held.");
      }
      if (device.edid.value != (bmdDynamicRangeSDR | bmdDynamicRangeHDRStaticPQ) || !device.balanced())
        return fail(error, @"Releasing the advertisement did not restore the default EDID.");
      device.hasEDID = false;
      ComRef<IDeckLinkHDMIInputEDID> unsupported;
      if (advertiseHDR(&device, unsupported) != E_NOINTERFACE || unsupported)
        return fail(error, @"A device without IDeckLinkHDMIInputEDID did not skip quietly.");
    }

    // Detected-mode status read (GetInterface first, then GetInt + GetDisplayMode).
    {
      FakeDeckLink device;
      auto detected = detectedStatusInput(&device.status, &device.input);
      if (!detected || !detected->supported || detected->mode != bmdMode4K2160p2997 ||
          detected->colorspace != bmdColorspaceRec709 || detected->eotf != kEOTFSDR ||
          ![detected->fullDescription() containsString:@"Rec.709 · SDR"] || !device.balanced())
        return fail(error, @"Detected input status was not read through IDeckLinkStatus::GetInterface.");
      device.status.interfaceAvailable = false;
      if (detectedStatusInput(&device.status, &device.input))
        return fail(error, @"Detected status fabricated a display mode the input could not resolve.");
      device.status.available = false;
      if (detectedStatusInput(&device.status, &device.input)) return fail(error, @"Unavailable status produced a detection.");
    }
    return YES;
  }
}

// Version check and hot-plug discovery against fake SDK objects only.
BOOL UltracamRunDiscoverySyntheticChecks(NSError **error) {
  {
    FakeDeckLink a, b, c;
    a.attributes.persistentIDResult = b.attributes.persistentIDResult = c.attributes.persistentIDResult = E_FAIL;
    dispatch_queue_t queue = dispatch_queue_create("org.ultracam.legacy-identity", DISPATCH_QUEUE_SERIAL);
    {
    DeviceRegistry registry(queue);
    registry.arrived(&a); registry.arrived(&b); registry.drain();
    if (a.references != 3 || b.references != 3)
      return fail(error, @"Legacy identity storage lost a COM reference while growing.");
    NSString *aID = registry.snapshot()[0].identifier;
    NSString *bID = registry.snapshot()[1].identifier;
    registry.removed(&a); registry.drain();
    registry.arrived(&c); registry.drain();
    if (a.references != 2 || b.references != 3 || c.references != 3)
      return fail(error, @"Legacy identity storage lost references after removal and reallocation.");
    NSArray<UltracamDevice *> *devices = registry.snapshot();
    if (devices.count != 2 || [devices[0].identifier isEqualToString:devices[1].identifier])
      return fail(error, @"Legacy hotplug reused a live device identifier.");
    ComRef<IDeckLink> selectedB, selectedC;
    selectedB.value = registry.copyDevice(bID, nullptr);
    selectedC.value = registry.copyDevice(devices[1].identifier, nullptr);
    if (selectedB.value != &b || selectedC.value != &c)
      return fail(error, @"Legacy identifiers selected the wrong live COM device.");
    if (![registry.identifierForDevice(&b) isEqualToString:bID] ||
        ![registry.identifierForDevice(&c) isEqualToString:devices[1].identifier])
      return fail(error, @"Legacy iterator identity disagreed with discovery.");
    auto session = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, nil);
    registry.attachSession(bID, session, session->stats);
    registry.removed(&c); registry.drain();
    const bool stillAccepting = session->accepting;
    registry.detachSession(session); session->Release();
    if (!stillAccepting)
      return fail(error, @"Removing another legacy device disconnected the surviving session.");
    registry.arrived(&a); registry.drain();
    if (![registry.snapshot()[1].identifier isEqualToString:aID])
      return fail(error, @"Legacy rearrival changed its discovery-lifetime identity.");
    }
    if (!a.balanced() || !b.balanced() || !c.balanced())
      return fail(error, @"Legacy identity teardown did not release exactly its owned COM references.");
  }
  {  // No inner pool: a failure returns its autoreleased NSError through the out-parameter.
    FakeAPIInformation old(0x0F030000, CFSTR("15.3")), current(0x10040000, CFSTR("16.4")), unnamed(0x10000000, nullptr);
    UltracamDriverInfo *oldInfo = driverInfoFrom(&old), *currentInfo = driverInfoFrom(&current);
    UltracamDriverInfo *unnamedInfo = driverInfoFrom(&unnamed), *missing = driverInfoFrom(nullptr);
    if (oldInfo.supported || !oldInfo.installed || ![oldInfo.message containsString:@"Update Desktop Video to 16 or later"] ||
        ![oldInfo.message containsString:@"15.3"])
      return fail(error, @"A pre-16 Desktop Video driver was not reported with an update message.");
    if (!currentInfo.supported || currentInfo.message || ![currentInfo.version isEqualToString:@"16.4"] ||
        !unnamedInfo.supported || ![unnamedInfo.version isEqualToString:@"16.0.0"])
      return fail(error, @"A Desktop Video 16 driver was not accepted.");
    if (missing.installed || missing.supported || !missing.message)
      return fail(error, @"A missing Desktop Video driver was not reported.");

    dispatch_queue_t observers = dispatch_queue_create("org.ultracam.tests.observers", DISPATCH_QUEUE_SERIAL);
    __block NSArray<UltracamDevice *> *published = nil;
    __block int publications = 0;
    FakeDeckLink first, second, outputOnly;
    second.attributes.persistentID = 0x55;
    second.name = CFSTR("UltraStudio Recorder 3G");
    outputOnly.hasInput = false; outputOnly.attributes.persistentID = 0x66;
    {
      DeviceRegistry registry(observers);
      id token = registry.addObserver(^(NSArray<UltracamDevice *> *list) { published = list; ++publications; });
      auto settle = [&] { registry.drain(); dispatch_sync(observers, ^{}); };
      settle();
      if (publications != 1 || published.count != 0)
        return fail(error, @"A new observer did not receive its empty initial snapshot.");
      DiscoveryCallback *notifications = new DiscoveryCallback(&registry);
      notifications->DeckLinkDeviceArrived(&first);
      notifications->DeckLinkDeviceArrived(&outputOnly);
      notifications->DeckLinkDeviceArrived(&second);
      notifications->DeckLinkDeviceArrived(&first);  // Duplicate arrival.
      settle();
      if (published.count != 2 || ![published[0].identifier isEqualToString:@"decklink:000000001234abcd"] ||
          ![published[1].name isEqualToString:@"UltraStudio Recorder 3G"] || publications != 3 ||
          first.references != 2 || outputOnly.references != 1)
        return fail(error, @"Arrivals were not published once per usable device, keyed by persistent ID.");
      __block NSArray<UltracamDevice *> *late = nil;
      id lateToken = registry.addObserver(^(NSArray<UltracamDevice *> *list) { late = list; });
      settle();
      if (late.count != 2) return fail(error, @"A late observer missed the already-discovered devices.");
      registry.removeObserver(lateToken);
      DeviceCapabilities capabilities;
      IDeckLink *held = registry.copyDevice(@"decklink:000000001234abcd", &capabilities);
      if (held != &first || capabilities.maximumHDMIAudioChannels != 8 || !capabilities.hdrMetadata || first.references != 3)
        return fail(error, @"Discovery did not hold the arrived device for start.");
      held->Release();
      UltracamDeviceDiagnostics *diagnostics = registry.diagnostics(@"decklink:000000001234abcd");
      if (diagnostics.maximumHDMIAudioChannels != 8 || diagnostics.capturedAudioChannels != 2 || !diagnostics.supportsHDMITimecode ||
          diagnostics.sessionActive || diagnostics.temperatureCelsius != NSNotFound)
        return fail(error, @"Device diagnostics did not report the cached attributes.");

      // Removal of the active device reports a disconnection, once.
      __block NSString *message = nil;
      __block int messages = 0;
      auto session = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, ^(NSString *value) { message = value; ++messages; });
      registry.attachSession(@"decklink:000000001234abcd", session, session->stats);
      notifications->DeckLinkDeviceRemoved(&outputOnly);  // Never listed: ignored.
      notifications->DeckLinkDeviceRemoved(&first);
      settle();
      if (published.count != 1 || ![published[0].identifier isEqualToString:@"decklink:0000000000000055"] ||
          messages != 1 || ![message containsString:@"UltraStudio disconnected"] || session->accepting ||
          first.references != 1 || session->references != 2)
        return fail(error, @"Removing the active device did not update the list and report the disconnection.");
      if (registry.copyDevice(@"decklink:000000001234abcd", nullptr))
        return fail(error, @"A removed device was still available to start.");
      registry.detachSession(session);
      if (session->references != 1) return fail(error, @"Detached session kept a registry reference.");
      session->Release();
      registry.removeObserver(token);
      notifications->DeckLinkDeviceRemoved(&second);
      settle();
      if (publications != 4) return fail(error, @"A removed observer was still notified.");
      notifications->Release();
    }
    if (first.references != 1 || second.references != 1 || outputOnly.references != 1)
      return fail(error, @"Discovery leaked device references.");
    return YES;
  }
}
