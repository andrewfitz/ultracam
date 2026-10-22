// Included only with ULTRACAM_BACKEND_TESTING; no mock code in the shipped app.
#include <vector>
#include <string>

class FakeTimecode final : public IDeckLinkTimecode {
 public:
  std::atomic<ULONG> references{1};
  CFStringRef value = CFSTR("01:02:03:04");
  ~FakeTimecode() override = default;
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG n = --references; if (!n) delete this; return n; }
  BMDTimecodeBCD GetBCD() override { return 0; }
  HRESULT GetComponents(uint8_t *hours, uint8_t *minutes, uint8_t *seconds, uint8_t *frames) override {
    if (hours) *hours = 1; if (minutes) *minutes = 2; if (seconds) *seconds = 3; if (frames) *frames = 4; return S_OK;
  }
  HRESULT GetString(CFStringRef *result) override { if (!result) return E_INVALIDARG; *result = static_cast<CFStringRef>(CFRetain(value)); return S_OK; }
  BMDTimecodeFlags GetFlags() override { return bmdTimecodeIsDropFrame; }
  HRESULT GetTimecodeUserBits(BMDTimecodeUserBits *bits) override { if (bits) *bits = 0; return S_OK; }
};

class FakeAudioPacket final : public IDeckLinkAudioInputPacket {
 public:
  std::atomic<ULONG> references{1};
  std::vector<int16_t> samples;
  BMDTimeValue packetTime = 960;
  explicit FakeAudioPacket(std::initializer_list<int16_t> values) : samples(values) {}
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
  BMDTimeValue packetTime = 48000 * 3 + 17;
  explicit FakeRawAudioPacket(std::initializer_list<int32_t> values) : samples(values) {}
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG n = --references; if (!n) delete this; return n; }
  long GetSampleFrameCount() override { return static_cast<long>(samples.size() / 2); }
  HRESULT GetBytes(void **result) override { if (!result) return E_INVALIDARG; *result = samples.data(); return S_OK; }
  HRESULT GetPacketTime(BMDTimeValue *result, BMDTimeScale) override { if (!result) return E_INVALIDARG; *result = packetTime; return S_OK; }
};

class FakeFrame;

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
  FakeTimecode *timecode = nullptr;
  BMDTimeValue frameDuration = 1001;
  long width = 3840;
  FakeFrame(bool *result) : destroyed(result) {}
  ~FakeFrame() override { *destroyed = true; }
  HRESULT QueryInterface(REFIID iid, LPVOID *result) override {
    *result = nullptr;
    if (!sameIID(iid, IID_IDeckLinkMacVideoBuffer)) return E_NOINTERFACE;
    *result = static_cast<IDeckLinkMacVideoBuffer *>(new FakeMacVideoBuffer(this));
    return S_OK;
  }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG n = --references; if (!n) delete this; return n; }
  long GetWidth() override { return width; }
  long GetHeight() override { return 2160; }
  long GetRowBytes() override { return 10240; }
  BMDPixelFormat GetPixelFormat() override { return bmdFormat10BitYUV; }
  BMDFrameFlags GetFlags() override { return noSignal ? bmdFrameHasNoInputSource : bmdFrameFlagDefault; }
  HRESULT GetTimecode(BMDTimecodeFormat, IDeckLinkTimecode **result) override {
    if (!result || !timecode) return E_NOTIMPL;
    timecode->AddRef(); *result = timecode; return S_OK;
  }
  HRESULT GetAncillaryData(IDeckLinkVideoFrameAncillary **) override { return E_NOTIMPL; }
  HRESULT GetStreamTime(BMDTimeValue *pts, BMDTimeValue *duration, BMDTimeScale) override {
    *pts = negativeTime ? -1 : 123123; *duration = frameDuration; return invalidTime ? E_FAIL : S_OK;
  }
  HRESULT GetHardwareReferenceTimestamp(BMDTimeScale, BMDTimeValue *, BMDTimeValue *) override { return E_NOTIMPL; }
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
  if (CVPixelBufferCreate(kCFAllocatorDefault, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      (__bridge CFDictionaryRef)attributes, &buffer) != kCVReturnSuccess || !buffer) return E_FAIL;
  frame->AddRef();
  FakeFrame *owner = frame;
  id holder = [[FakeFrameLifetime alloc] initWithRelease:^{ owner->Release(); }];
  CVBufferSetAttachment(buffer, CFSTR("UltracamTestFrameLifetime"), (__bridge CFTypeRef)holder, kCVAttachmentMode_ShouldNotPropagate);
  *result = buffer;
  return S_OK;
}

class FakeMode final : public IDeckLinkDisplayMode {
 public:
  ULONG references = 1;
  BMDDisplayMode mode = bmdMode4K2160p5994;
  long width = 3840, height = 2160;
  bool invalidRate = false;
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { return --references; }
  HRESULT GetName(CFStringRef *name) override { *name = CFSTR("Synthetic 4K"); CFRetain(*name); return S_OK; }
  BMDDisplayMode GetDisplayMode() override { return mode; }
  long GetWidth() override { return width; }
  long GetHeight() override { return height; }
  HRESULT GetFrameRate(BMDTimeValue *duration, BMDTimeScale *scale) override {
    *duration = 1001; *scale = mode == bmdMode4K2160p2997 ? 30000 : 60000; return invalidRate ? E_FAIL : S_OK;
  }
  BMDFieldDominance GetFieldDominance() override { return bmdProgressiveFrame; }
  BMDDisplayModeFlags GetFlags() override { return bmdDisplayModeColorspaceRec709; }
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
    if ((mode != bmdMode4K2160p5994 && mode != bmdMode4K2160p2997) || format != bmdFormat10BitYUV) return E_INVALIDARG;
    enabledMode = mode;
    return enableResult;
  }
  HRESULT DisableVideoInput() override { calls.push_back("disable"); return S_OK; }
  HRESULT GetAvailableVideoFrameCount(uint32_t *) override { return E_NOTIMPL; }
  HRESULT EnableVideoInputWithAllocatorProvider(BMDDisplayMode mode, BMDPixelFormat format, BMDVideoInputFlags flags,
    IDeckLinkVideoBufferAllocatorProvider *) override { return EnableVideoInput(mode, format, flags); }
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
  HRESULT GetHardwareReferenceClock(BMDTimeScale, BMDTimeValue *, BMDTimeValue *, BMDTimeValue *) override { return E_NOTIMPL; }
};

class FakeConfiguration final : public IDeckLinkConfiguration {
 public:
  ULONG references = 1;
  int64_t connection = bmdVideoConnectionSDI;
  int writes = 0, persistentWrites = 0;
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { return --references; }
  HRESULT SetFlag(BMDDeckLinkConfigurationID, bool) override { return E_NOTIMPL; }
  HRESULT GetFlag(BMDDeckLinkConfigurationID, bool *) override { return E_NOTIMPL; }
  HRESULT SetInt(BMDDeckLinkConfigurationID key, int64_t value) override {
    if (key != bmdDeckLinkConfigVideoInputConnection) return E_INVALIDARG;
    connection = value; ++writes; return S_OK;
  }
  HRESULT GetInt(BMDDeckLinkConfigurationID key, int64_t *value) override {
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
  @autoreleasepool {
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

BOOL UltracamRunSyntheticChecks(NSError **error) {
  @autoreleasepool {
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
      ++mediaCallbacks; mediaTimecodeMatches = [timecode isEqualToString:@"01:02:03:04"]; mediaTimecodeAbsent = timecode == nil; mediaPacketTime = packetTime;
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
      mediaChannels != 2 || mediaBytes != 8 || !mediaPresent || mediaLeftPeak != 1.0f ||
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
    auto emptyTimecode = new FakeTimecode(); emptyTimecode->value = CFSTR(""); frame->timecode = emptyTimecode;
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
      if (input.enabledAudioType != bmdAudioSampleType16bitInteger)
        return fail(error, @"Stats startup unexpectedly requested non-16-bit embedded audio.");
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
