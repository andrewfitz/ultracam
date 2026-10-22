#import "UltracamBackend.h"
#include <atomic>
#include <memory>
#include <cstring>
#include <mutex>
#include <optional>
#include <cmath>
#include <cstdint>
#include <algorithm>
#include <limits>

#if __has_include("DeckLinkAPI.h")
#include "DeckLinkAPI.h"
#include "DeckLinkAPIConfiguration.h"
#include "DeckLinkAPIVersion.h"
#define ULTRACAM_HAS_SDK 1
#else
#define ULTRACAM_HAS_SDK 0
#endif

@interface UltracamMode ()
@property(nonatomic) NSInteger width;
@property(nonatomic) NSInteger height;
@property(nonatomic) CMTime frameDuration;
@property(nonatomic, copy) NSString *name;
@end
@implementation UltracamMode
@end

@interface UltracamDevice ()
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSArray<UltracamMode *> *modes;
@end
@implementation UltracamDevice
@end

static BOOL fail(NSError **error, NSString *message, NSInteger code = 1) {
  if (error) *error = [NSError errorWithDomain:@"org.ultracam.decklink" code:code
    userInfo:@{NSLocalizedDescriptionKey: message}];
  return NO;
}

#if ULTRACAM_HAS_SDK
// Own exactly one COM reference. Discovery/start failure paths release partial
// resources automatically; callback/frame references have independent lives.
template <typename T> struct ComRef {
  T *value = nullptr;
  ~ComRef() { if (value) value->Release(); }
  T **out() { return &value; }
  T *operator->() const { return value; }
  explicit operator bool() const { return value != nullptr; }
  T *take() { T *result = value; value = nullptr; return result; }
};

// Session-only HDMI selection. Never persist device preferences. Restore only
// the value this session still owns, preserving a subsequent outside change.
struct HDMILease {
  ComRef<IDeckLinkConfiguration> configuration;
  int64_t previous = bmdVideoConnectionHDMI;
  bool changed = false;
  bool started = false;
  ~HDMILease() {
    int64_t current = 0;
    if (started && changed && configuration && configuration->GetInt(bmdDeckLinkConfigVideoInputConnection, &current) == S_OK && current == bmdVideoConnectionHDMI)
      configuration->SetInt(bmdDeckLinkConfigVideoInputConnection, previous);
  }
  HRESULT select(IDeckLink *device) {
    HRESULT status = device->QueryInterface(IID_IDeckLinkConfiguration, reinterpret_cast<void **>(configuration.out()));
    if (status != S_OK) return status;
    status = configuration->GetInt(bmdDeckLinkConfigVideoInputConnection, &previous);
    if (status != S_OK || previous == bmdVideoConnectionHDMI) return status;
    status = configuration->SetInt(bmdDeckLinkConfigVideoInputConnection, bmdVideoConnectionHDMI);
    changed = status == S_OK;
    return status;
  }
};

static NSString *deviceIdentifier(IDeckLink *device, NSUInteger index) {
  ComRef<IDeckLinkProfileAttributes> attributes;
  int64_t persistentID = 0;
  if (device->QueryInterface(IID_IDeckLinkProfileAttributes,
      reinterpret_cast<void **>(attributes.out())) == S_OK &&
      attributes->GetInt(BMDDeckLinkPersistentID, &persistentID) == S_OK) {
    return [NSString stringWithFormat:@"decklink:%016llx", (unsigned long long)persistentID];
  }
  // Legacy devices without persistent IDs are distinguished within the current
  // iterator; start re-enumerates and verifies this same identifier.
  CFStringRef name = nullptr;
  device->GetDisplayName(&name);
  NSString *result = [NSString stringWithFormat:@"decklink:%@:%lu",
    name ? (__bridge NSString *)name : @"Unknown", (unsigned long)index];
  if (name) CFRelease(name);
  return result;
}

static NSArray<UltracamMode *> *supportedModes(IDeckLinkInput *input) {
  NSMutableArray<UltracamMode *> *result = [NSMutableArray array];
  ComRef<IDeckLinkDisplayModeIterator> iterator;
  if (input->GetDisplayModeIterator(iterator.out()) != S_OK) return result;
  IDeckLinkDisplayMode *raw = nullptr;
  while (iterator->Next(&raw) == S_OK) {
    ComRef<IDeckLinkDisplayMode> mode; mode.value = raw;
    BMDTimeValue duration = 0; BMDTimeScale scale = 0;
    mode->GetFrameRate(&duration, &scale);
    if (mode->GetWidth() != 3840 || mode->GetHeight() != 2160 || duration <= 0 || scale <= 0 || scale > INT32_MAX ||
        (CMTimeCompare(CMTimeMake(duration, (int32_t)scale), CMTimeMake(1001, 30000)) != 0 &&
         CMTimeCompare(CMTimeMake(duration, (int32_t)scale), CMTimeMake(1001, 60000)) != 0)) continue;
    bool supported = false;
    if (input->DoesSupportVideoMode(bmdVideoConnectionHDMI, mode->GetDisplayMode(),
      bmdFormat10BitYUV, bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, nullptr, &supported) != S_OK || !supported) continue;
    UltracamMode *description = [UltracamMode new];
    description.width = mode->GetWidth(); description.height = mode->GetHeight();
    description.frameDuration = CMTimeMake(duration, (int32_t)scale);
    CFStringRef name = nullptr; mode->GetName(&name);
    description.name = name ? (__bridge NSString *)name : @"4K";
    if (name) CFRelease(name);
    [result addObject:description];
  }
  return result;
}

static bool sameIID(REFIID a, CFUUIDBytes b) { return std::memcmp(&a, &b, sizeof(a)) == 0; }

// DeckLink's stream clock is requested at either 30 kHz or 60 kHz, but a
// malformed driver can still return an arbitrary positive duration. Keep the
// native boundary strict so invalid cadence never reaches media metadata or
// the asynchronous Swift pipeline. CMTimeCompare preserves the exact 1001
// based NTSC rationals across either requested time scale.
static bool supportedFrameDuration(BMDTimeValue duration, BMDTimeScale scale) {
  if (duration <= 0 || scale <= 0 || scale > INT32_MAX) return false;
  CMTime value = CMTimeMake(duration, static_cast<int32_t>(scale));
  return CMTimeCompare(value, CMTimeMake(1001, 30000)) == 0 ||
    CMTimeCompare(value, CMTimeMake(1001, 60000)) == 0;
}

struct DetectedInput {
  BMDDisplayMode mode = bmdModeUnknown;
  CMTime duration = kCMTimeInvalid;
  BMDDetectedVideoInputFormatFlags flags = 0;
  NSString *description = @"Unknown HDMI input";
  bool supported = false;
  uint64_t sequence = 0;
};

static DetectedInput describeInput(IDeckLinkDisplayMode *mode, BMDDetectedVideoInputFormatFlags flags) {
  DetectedInput result; result.flags = flags;
  if (!mode) return result;
  result.mode = mode->GetDisplayMode();
  BMDTimeValue duration = 0; BMDTimeScale scale = 0;
  if (mode->GetFrameRate(&duration, &scale) == S_OK && duration > 0 && scale > 0 && scale <= INT32_MAX)
    result.duration = CMTimeMake(duration, (int32_t)scale);
  NSString *color = (flags & bmdDetectedVideoInputRGB444) ? @"RGB 4:4:4" :
    ((flags & bmdDetectedVideoInputYCbCr422) ? @"YUV 4:2:2" : @"unknown color format");
  NSString *depth = (flags & bmdDetectedVideoInput10BitDepth) ? @"10-bit" :
    ((flags & bmdDetectedVideoInput12BitDepth) ? @"12-bit" : ((flags & bmdDetectedVideoInput8BitDepth) ? @"8-bit" : @"unreported bit depth"));
  double fps = CMTIME_IS_NUMERIC(result.duration) ? 1.0 / CMTimeGetSeconds(result.duration) : 0;
  NSString *cadence = fps > 0 ? [NSString stringWithFormat:@"%.2f fps", fps] : @"unknown frame rate";
  result.description = [NSString stringWithFormat:@"%ld × %ld · %@ · %@ · %@",
    mode->GetWidth(), mode->GetHeight(), cadence, color, depth];
  result.supported = mode->GetWidth() == 3840 && mode->GetHeight() == 2160 &&
    CMTIME_IS_NUMERIC(result.duration) &&
    (result.mode == bmdMode4K2160p2997 || result.mode == bmdMode4K2160p5994) &&
    supportedFrameDuration(duration, scale) &&
    // Treat an omitted depth flag as unsupported.  The capture contract needs
    // a provably 10/12-bit source; accepting "unreported bit depth" here
    // would let an 8-bit/unknown signal through the auto reconfiguration path
    // and silently promote it to a 10-bit output.
    (flags & bmdDetectedVideoInputYCbCr422) &&
    (flags & (bmdDetectedVideoInput10BitDepth | bmdDetectedVideoInput12BitDepth)) &&
    !(flags & (bmdDetectedVideoInputRGB444 | bmdDetectedVideoInput8BitDepth | bmdDetectedVideoInputDualStream3D));
  return result;
}

// One latest mode and at most one scheduled reconfiguration. Changes during
// driver restart are coalesced; cancellation cannot resurrect a stopped input.
struct AutoModeMailbox {
  std::mutex mutex;
  bool cancelled = false, scheduled = false;
  DetectedInput latest;
  bool push(DetectedInput input, std::atomic<bool> *framesEnabled = nullptr) {
    std::lock_guard<std::mutex> guard(mutex);
    if (cancelled) return false;
    if (framesEnabled) *framesEnabled = false;
    input.sequence = latest.sequence + 1; latest = input;
    if (scheduled) return false;
    scheduled = true; return true;
  }
  std::optional<DetectedInput> snapshot() {
    std::lock_guard<std::mutex> guard(mutex);
    if (cancelled) return std::nullopt;
    return latest;
  }
  bool isCurrent(uint64_t sequence) {
    std::lock_guard<std::mutex> guard(mutex);
    return !cancelled && latest.sequence == sequence;
  }
  bool enableCurrent(uint64_t sequence, std::atomic<bool> &framesEnabled,
    const std::atomic<bool> *accepting = nullptr) {
    std::lock_guard<std::mutex> guard(mutex);
    if (cancelled || latest.sequence != sequence || (accepting && !accepting->load())) return false;
    framesEnabled = true;
    return true;
  }
  bool cancelCurrent(uint64_t sequence, std::atomic<bool> &accepting) {
    std::lock_guard<std::mutex> guard(mutex);
    if (cancelled || latest.sequence != sequence) return false;
    accepting = false; cancelled = true; scheduled = false;
    return true;
  }
  bool finish(uint64_t sequence) {
    std::lock_guard<std::mutex> guard(mutex);
    if (cancelled || latest.sequence == sequence) { scheduled = false; return false; }
    return true;
  }
  void cancel() { std::lock_guard<std::mutex> guard(mutex); cancelled = true; scheduled = false; }
};

// Audio packets from EnableAudioInput(48 kHz, 16-bit, 2 channels) are
// interleaved little-endian signed PCM.  DeckLink does not expose a byte count
// on IDeckLinkAudioInputPacket, so the count is derived from the sample-frame
// count and the configured stream format.  Keep this helper bounded: a bad
// driver packet must never make the callback walk an untrusted allocation.
static void reportMedia(IDeckLinkVideoInputFrame *frame, IDeckLinkAudioInputPacket *audio,
  CMTimeScale videoScale, UltracamMediaStatsHandler handler, bool rawAudio = false) {
  if (!handler) return;
  NSString *timecodeString = nil;
  ComRef<IDeckLinkTimecode> timecode;
  if (frame && frame->GetTimecode(bmdTimecodeRP188Any, timecode.out()) == S_OK && timecode) {
    CFStringRef raw = nullptr;
    if (timecode->GetString(&raw) == S_OK && raw && CFStringGetLength(raw) > 0) {
      // Transfer the SDK-owned CFString retain into ARC exactly once. This
      // avoids mixing Objective-C copy semantics with the SDK's CF ownership.
      timecodeString = CFBridgingRelease(raw);
    } else if (raw) {
      CFRelease(raw);
    }
  }

  CMTime packetTime = kCMTimeInvalid;
  NSUInteger sampleFrames = 0;
  NSUInteger bytes = 0;
  float leftPeak = 0.0f, rightPeak = 0.0f;
  float leftRMS = 0.0f, rightRMS = 0.0f;
  BOOL present = NO;
  constexpr NSUInteger channels = 2;
  if (audio) {
    long count = audio->GetSampleFrameCount();
    // A normal callback contains a video-frame-sized audio packet (typically
    // 800 or 1600 frames).  96k frames is a generous two-second bound and
    // prevents overflow or pathological work on malformed driver data.
    if (count > 0 && static_cast<uint64_t>(count) <= 96000) {
      BMDTimeValue timestamp = 0;
      if (audio->GetPacketTime(&timestamp, bmdAudioSampleRate48kHz) == S_OK && timestamp >= 0)
        packetTime = CMTimeMake(timestamp, bmdAudioSampleRate48kHz);
      void *raw = nullptr;
      const NSUInteger frameCount = static_cast<NSUInteger>(count);
      const NSUInteger bytesPerSample = rawAudio ? sizeof(int32_t) : sizeof(int16_t);
      const NSUInteger expectedBytes = frameCount * channels * bytesPerSample;
      if (audio->GetBytes(&raw) == S_OK && raw && expectedBytes > 0) {
        const int16_t *samples16 = static_cast<const int16_t *>(raw);
        const int32_t *samples32 = static_cast<const int32_t *>(raw);
        double leftSum = 0.0, rightSum = 0.0;
        double leftMaximum = 0.0, rightMaximum = 0.0;
        for (NSUInteger index = 0; index < frameCount; ++index) {
          const double left = rawAudio ? static_cast<double>(samples32[index * channels]) / 2147483648.0
            : static_cast<double>(samples16[index * channels]) / 32768.0;
          const double right = rawAudio ? static_cast<double>(samples32[index * channels + 1]) / 2147483648.0
            : static_cast<double>(samples16[index * channels + 1]) / 32768.0;
          leftMaximum = std::max(leftMaximum, std::abs(left));
          rightMaximum = std::max(rightMaximum, std::abs(right));
          const double leftValue = left;
          const double rightValue = right;
          leftSum += leftValue * leftValue;
          rightSum += rightValue * rightValue;
        }
        sampleFrames = frameCount;
        bytes = expectedBytes;
        leftPeak = static_cast<float>(std::min(1.0, leftMaximum));
        rightPeak = static_cast<float>(std::min(1.0, rightMaximum));
        leftRMS = static_cast<float>(std::sqrt(leftSum / frameCount));
        rightRMS = static_cast<float>(std::sqrt(rightSum / frameCount));
        present = YES;
      }
    }
  }
  (void)videoScale;
  handler(timecodeString, packetTime, sampleFrames, present ? channels : 0, leftPeak, rightPeak,
    leftRMS, rightRMS, bytes, present);
}

// Raw audio is a separate capture mode: the DeckLink input must be enabled
// with bmdAudioSampleType32bitInteger, and every packet is copied before the
// callback returns. Keep the same conservative frame bound as the stats path
// so malformed driver metadata cannot produce an oversized allocation.
static void reportRawAudio(IDeckLinkAudioInputPacket *audio, UltracamRawAudioHandler handler) {
  if (!handler) return;
  constexpr NSUInteger channels = 2;
  constexpr NSUInteger bytesPerSample = sizeof(int32_t);
  CMTime packetTime = kCMTimeInvalid;
  NSData *samplesData = nil;
  NSUInteger sampleFrames = 0;
  if (audio) {
    long count = audio->GetSampleFrameCount();
    if (count > 0 && static_cast<uint64_t>(count) <= 96000) {
      BMDTimeValue timestamp = 0;
      if (audio->GetPacketTime(&timestamp, bmdAudioSampleRate48kHz) == S_OK && timestamp >= 0)
        packetTime = CMTimeMake(timestamp, bmdAudioSampleRate48kHz);
      const NSUInteger frameCount = static_cast<NSUInteger>(count);
      const NSUInteger bytesPerFrame = channels * bytesPerSample;
      if (frameCount <= (std::numeric_limits<NSUInteger>::max() / bytesPerFrame)) {
        const NSUInteger expectedBytes = frameCount * bytesPerFrame;
        void *raw = nullptr;
        if (audio->GetBytes(&raw) == S_OK && raw && expectedBytes > 0) {
          samplesData = [NSData dataWithBytes:raw length:expectedBytes];
          sampleFrames = frameCount;
        }
      }
    }
  }
  handler(samplesData, packetTime, sampleFrames, samplesData ? channels : 0, bytesPerSample);
}

class CaptureCallback final : public IDeckLinkInputCallback {
 public:
  std::atomic<ULONG> references{1};
  std::atomic<bool> accepting{true};
  std::atomic<int> signalState{-1};
  std::atomic<bool> fatalReported{false};
  std::atomic<bool> framesEnabled{true};
  std::atomic<BMDDisplayMode> requestedMode;
  std::atomic<bool> audioEnabled{false};
  std::atomic<uint64_t> lastDetection{UINT64_MAX};
  CMTimeScale timeScale;
  void (^frameHandler)(CVPixelBufferRef, CMTime, BOOL);
  UltracamMediaStatsHandler mediaHandler;
  UltracamRawAudioHandler rawAudioHandler;
  void (^eventHandler)(NSString *);
  void (^autoFrameHandler)(CVPixelBufferRef, CMTime, CMTime, BOOL) = nil;
  void (^modeHandler)(DetectedInput) = nil;
  CaptureCallback(BMDDisplayMode mode, CMTimeScale scale,
    void (^frames)(CVPixelBufferRef, CMTime, BOOL), void (^events)(NSString *),
    UltracamMediaStatsHandler media = nil, UltracamRawAudioHandler rawAudio = nil)
    : requestedMode(mode), timeScale(scale), frameHandler([frames copy]), mediaHandler([media copy]),
      rawAudioHandler([rawAudio copy]), eventHandler([events copy]) {
    // The automatic-format path intentionally leaves the ordinary frame
    // handler nil and installs autoFrameHandler immediately afterwards. Keep
    // the callback object safe if a late driver callback arrives during a
    // failed/partial start, or if a test/future caller omits an event block.
    // Blocks are copied so these fallbacks never refer to stack storage.
    if (!frameHandler) frameHandler = [^(CVPixelBufferRef, CMTime, BOOL) {} copy];
    if (!eventHandler) eventHandler = [^(NSString *) {} copy];
  }
  HRESULT QueryInterface(REFIID iid, LPVOID *object) override {
    if (!object) return E_INVALIDARG;
    *object = nullptr;
    if (sameIID(iid, CFUUIDGetUUIDBytes(IUnknownUUID)) || sameIID(iid, IID_IDeckLinkInputCallback)) {
      *object = static_cast<IDeckLinkInputCallback *>(this); AddRef(); return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG remaining = --references; if (!remaining) delete this; return remaining; }
  void reportFatal(NSString *message) {
    accepting = false;
    if (!fatalReported.exchange(true)) eventHandler([@"Capture error: " stringByAppendingString:message]);
  }
  HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents,
    IDeckLinkDisplayMode *mode, BMDDetectedVideoInputFormatFlags flags) override {
    @autoreleasepool {
      if (!accepting) return S_OK;
      if (modeHandler) {
        DetectedInput detection = describeInput(mode, flags);
        uint64_t signature = (uint64_t(detection.mode) << 32) | flags;
        if (lastDetection.exchange(signature) != signature) {
          framesEnabled = false;
          modeHandler(detection);
        }
        return S_OK;
      }
      if (!mode || mode->GetDisplayMode() != requestedMode.load()) {
        reportFatal(@"Input changed from the selected 4K 10-bit YUV mode. Check the FX3 HDMI output and selected frame rate, then restart.");
      }
    }
    return S_OK;
  }
  HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame *frame, IDeckLinkAudioInputPacket *audioPacket) override {
    @autoreleasepool {
      if (!accepting) return S_OK;
      // Desktop Video can deliver an audio packet while the video input is
      // absent (for example during a source reconnect).  Keep reporting that
      // packet even when the paired video frame is nil; the media path owns
      // its own clock and should not acquire an artificial audio hole merely
      // because no video object was supplied for this callback.
      reportMedia(frame, audioPacket, timeScale, mediaHandler, rawAudioHandler != nil);
      reportRawAudio(audioPacket, rawAudioHandler);
      if (!frame) return S_OK;
      bool valid = !(frame->GetFlags() & bmdFrameHasNoInputSource);
      int prior = signalState.exchange(valid ? 1 : 0);
      // Embedded audio has its own packet clock. Preserve it across video
      // signal loss and format reconfiguration so recordings do not acquire
      // an artificial audio hole merely because the paired video frame is
      // flagged invalid.
      if (!valid) {
        if (prior != 0) eventHandler(modeHandler ? @"No HDMI video signal — waiting for the camera to reconnect." :
          @"No video signal. Check the FX3 HDMI output and selected frame rate.");
        return S_OK;
      }
      if (!framesEnabled) return S_OK;
      if (frame->GetWidth() != 3840 || frame->GetHeight() != 2160 || frame->GetPixelFormat() != bmdFormat10BitYUV) {
        reportFatal([NSString stringWithFormat:@"Unsupported capture frame: %ld × %ld, pixel format 0x%08x. Requires 3840 × 2160 10-bit YUV 4:2:2.",
          frame->GetWidth(), frame->GetHeight(), (unsigned)frame->GetPixelFormat()]); return S_OK;
      }
      BMDTimeValue timestamp = 0, duration = 0;
      if (frame->GetStreamTime(&timestamp, &duration, timeScale) != S_OK || timestamp < 0 ||
          !supportedFrameDuration(duration, timeScale)) {
        reportFatal(@"UltraStudio supplied an invalid frame timestamp."); return S_OK;
      }
      CVPixelBufferRef buffer = nullptr;
#if BLACKMAGIC_DECKLINK_API_VERSION >= 0x0e030000
      ComRef<IDeckLinkMacVideoBuffer> macBuffer;
      if (frame->QueryInterface(IID_IDeckLinkMacVideoBuffer,
        reinterpret_cast<void **>(macBuffer.out())) != S_OK ||
        macBuffer->CreateCVPixelBufferRef(reinterpret_cast<void **>(&buffer)) != S_OK || !buffer) {
        reportFatal(@"Desktop Video could not expose its native 10-bit pixel buffer. Update the Desktop Video driver."); return S_OK;
      }
      // SDK14.3+ carries a reference to the frame and allocation internally.
#else
      // SDK12 uses the versioned legacy frame interface. Retain the native
      // frame until the CVPixelBuffer's final release; do not copy ~22 MB/frame.
      void *bytes = nullptr;
      if (frame->GetBytes(&bytes) != S_OK || !bytes || frame->GetRowBytes() < 10240) {
        reportFatal(@"Desktop Video could not expose its native 10-bit frame bytes."); return S_OK;
      }
      frame->AddRef();
      CVReturn result = CVPixelBufferCreateWithBytes(kCFAllocatorDefault, 3840, 2160,
        kCVPixelFormatType_422YpCbCr10, bytes, frame->GetRowBytes(),
        [](void *context, const void *) { static_cast<IDeckLinkVideoInputFrame *>(context)->Release(); },
        frame, nullptr, &buffer);
      if (result != kCVReturnSuccess || !buffer) {
        frame->Release(); reportFatal(@"Cannot wrap the native UltraStudio 10-bit frame."); return S_OK;
      }
#endif
      // Keep the producer contract explicit even if future SDK wrappers use a
      // different CoreVideo format. The controller's untouched sink is v210.
      if (CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_422YpCbCr10) {
        CVPixelBufferRelease(buffer);
        reportFatal(@"Desktop Video supplied a pixel format incompatible with the native v210 feed."); return S_OK;
      }
      // Swift retaining the buffer safely extends the native frame lifetime.
      if (accepting && framesEnabled) {
        if (autoFrameHandler) autoFrameHandler(buffer, CMTimeMake(timestamp, timeScale), CMTimeMake(duration, timeScale), YES);
        else frameHandler(buffer, CMTimeMake(timestamp, timeScale), YES);
      }
      CVPixelBufferRelease(buffer);
    }
    return S_OK;
  }
};
// Driver setup/teardown stays ordered and is independently exercised with a
// fake SDK input in tests. Disable callbacks before a synchronous driver stop.
static void stopInput(IDeckLinkInput *input, CaptureCallback *callback) {
  if (callback) callback->accepting = false;
  if (input) {
    input->StopStreams();
    input->SetCallback(nullptr);
    if (callback && callback->audioEnabled.exchange(false)) input->DisableAudioInput();
    input->DisableVideoInput();
  }
}

static HRESULT startInput(IDeckLinkInput *input, CaptureCallback *callback,
  BMDDisplayMode mode, BMDVideoInputFlags flags, bool rawAudio = false) {
  // Claim video before installing callbacks so a competing EnableVideoInput
  // failure cannot replace or detach the active owner's callback.
  HRESULT status = input->EnableVideoInput(mode, bmdFormat10BitYUV, flags);
  bool videoEnabled = status == S_OK;
  if (status == S_OK) status = input->SetCallback(callback);
  bool callbackSet = status == S_OK;
  if (status == S_OK) {
    // Embedded audio is optional unless raw audio was requested.
    HRESULT audioStatus = input->EnableAudioInput(bmdAudioSampleRate48kHz,
      rawAudio ? bmdAudioSampleType32bitInteger : bmdAudioSampleType16bitInteger, 2);
    if (audioStatus == S_OK) callback->audioEnabled = true;
    else if (rawAudio) status = audioStatus;
  }
  if (status == S_OK) status = input->StartStreams();
  if (status != S_OK) {
    callback->accepting = false;
    // This instance never started streams. Undo only its successful setup;
    // StopStreams belongs exclusively to teardown of a successful start.
    if (callbackSet) input->SetCallback(nullptr);
    if (callback->audioEnabled.exchange(false)) input->DisableAudioInput();
    if (videoEnabled) input->DisableVideoInput();
  }
  return status;
}

// The caller must run this on the native control queue, never a driver callback.
static HRESULT reconfigureInput(IDeckLinkInput *input, CaptureCallback *callback, const DetectedInput &mode) {
  callback->framesEnabled = false;
  if (!callback->accepting) return E_FAIL;
  HRESULT status = input->PauseStreams();
  if (!callback->accepting) return E_FAIL;
  if (status == S_OK) status = input->EnableVideoInput(mode.mode, bmdFormat10BitYUV, bmdVideoInputEnableFormatDetection);
  if (!callback->accepting) return E_FAIL;
  if (status == S_OK) status = input->FlushStreams();
  if (!callback->accepting) return E_FAIL;
  if (status == S_OK) {
    callback->requestedMode = mode.mode;
    status = input->StartStreams();
  }
  return status;
}

#if defined(ULTRACAM_BACKEND_TESTING)
#include "BackendTestSupport.inc"
#endif

#endif

static const void *UltracamControlQueueKey = &UltracamControlQueueKey;

@implementation UltracamBackend {
  dispatch_queue_t _controlQueue;
#if ULTRACAM_HAS_SDK
  IDeckLinkInput *_input;
  CaptureCallback *_callback;
  std::unique_ptr<HDMILease> _connection;
  std::shared_ptr<AutoModeMailbox> _autoMode;
#if defined(ULTRACAM_BACKEND_TESTING)
  BOOL _scheduledOffControlQueue;
#endif
#endif
}

- (instancetype)init {
  if ((self = [super init])) {
    _controlQueue = dispatch_queue_create("org.ultracam.decklink.control", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_controlQueue, UltracamControlQueueKey, (__bridge void *)self, nullptr);
  }
  return self;
}

- (void)onControlQueue:(void (^)(void))action {
  if (dispatch_get_specific(UltracamControlQueueKey) == (__bridge void *)self) action();
  else dispatch_sync(_controlQueue, action);
}

+ (NSArray<UltracamDevice *> *)devicesWithError:(NSError **)error {
#if ULTRACAM_HAS_SDK
  ComRef<IDeckLinkIterator> iterator; iterator.value = CreateDeckLinkIteratorInstance();
  if (!iterator) { fail(error, @"Blackmagic Desktop Video is not available. Install the compatible Desktop Video driver."); return nil; }
  NSMutableArray<UltracamDevice *> *result = [NSMutableArray array];
  IDeckLink *raw = nullptr; NSUInteger index = 0;
  while (iterator->Next(&raw) == S_OK) {
    ComRef<IDeckLink> device; device.value = raw;
    NSString *identifier = deviceIdentifier(device.value, index++);
    ComRef<IDeckLinkInput> input;
    if (device->QueryInterface(IID_IDeckLinkInput, reinterpret_cast<void **>(input.out())) != S_OK) continue;
    UltracamDevice *description = [UltracamDevice new]; description.identifier = identifier;
    CFStringRef name = nullptr; device->GetDisplayName(&name);
    description.name = name ? (__bridge NSString *)name : @"Blackmagic capture device";
    if (name) CFRelease(name);
    description.modes = supportedModes(input.value);
    [result addObject:description];
  }
  return result;
#else
  fail(error, @"This app was built without the Blackmagic Desktop Video SDK. Configure DECKLINK_SDK_DIR and rebuild."); return nil;
#endif
}

- (BOOL)startWithDeviceID:(NSString *)deviceID inputFast:(BOOL)inputFast
  frameHandler:(void (^)(CVPixelBufferRef, CMTime, BOOL))frameHandler
  mediaHandler:(UltracamMediaStatsHandler)mediaHandler
  eventHandler:(void (^)(NSString *))eventHandler error:(NSError **)error {
  __block BOOL result = NO;
  __block NSError *localError = nil;
  [self onControlQueue:^{ result = [self startOnQueue:deviceID inputFast:inputFast
    frameHandler:frameHandler autoFrameHandler:nil mediaHandler:mediaHandler rawAudioHandler:nil
    eventHandler:eventHandler error:&localError]; }];
  if (!result && error) *error = localError;
  return result;
}

- (BOOL)startWithDeviceID:(NSString *)deviceID inputFast:(BOOL)inputFast
  frameHandler:(void (^)(CVPixelBufferRef, CMTime, BOOL))frameHandler
  rawAudioHandler:(UltracamRawAudioHandler)rawAudioHandler
  eventHandler:(void (^)(NSString *))eventHandler error:(NSError **)error {
  __block BOOL result = NO;
  __block NSError *localError = nil;
  [self onControlQueue:^{ result = [self startOnQueue:deviceID inputFast:inputFast
    frameHandler:frameHandler autoFrameHandler:nil mediaHandler:nil rawAudioHandler:rawAudioHandler
    eventHandler:eventHandler error:&localError]; }];
  if (!result && error) *error = localError;
  return result;
}

- (BOOL)startWithDeviceID:(NSString *)deviceID inputFast:(BOOL)inputFast
  frameHandler:(void (^)(CVPixelBufferRef, CMTime, BOOL))frameHandler
  mediaHandler:(UltracamMediaStatsHandler)mediaHandler
  rawAudioHandler:(UltracamRawAudioHandler)rawAudioHandler
  eventHandler:(void (^)(NSString *))eventHandler error:(NSError **)error {
  __block BOOL result = NO;
  __block NSError *localError = nil;
  [self onControlQueue:^{ result = [self startOnQueue:deviceID inputFast:inputFast
    frameHandler:frameHandler autoFrameHandler:nil mediaHandler:mediaHandler rawAudioHandler:rawAudioHandler
    eventHandler:eventHandler error:&localError]; }];
  if (!result && error) *error = localError;
  return result;
}

- (BOOL)startWithDeviceID:(NSString *)deviceID inputFast:(BOOL)inputFast
  frameHandler:(void (^)(CVPixelBufferRef, CMTime, BOOL))frameHandler
  eventHandler:(void (^)(NSString *))eventHandler error:(NSError **)error {
  return [self startWithDeviceID:deviceID inputFast:inputFast frameHandler:frameHandler
    mediaHandler:nil eventHandler:eventHandler error:error];
}

- (BOOL)startAutoWithDeviceID:(NSString *)deviceID
  frameHandler:(void (^)(CVPixelBufferRef, CMTime, CMTime, BOOL))frameHandler
  mediaHandler:(UltracamMediaStatsHandler)mediaHandler
  eventHandler:(void (^)(NSString *))eventHandler error:(NSError **)error {
  __block BOOL result = NO;
  __block NSError *localError = nil;
  [self onControlQueue:^{ result = [self startOnQueue:deviceID inputFast:YES
    frameHandler:nil autoFrameHandler:frameHandler mediaHandler:mediaHandler rawAudioHandler:nil
    eventHandler:eventHandler error:&localError]; }];
  if (!result && error) *error = localError;
  return result;
}

- (BOOL)startAutoWithDeviceID:(NSString *)deviceID
  frameHandler:(void (^)(CVPixelBufferRef, CMTime, CMTime, BOOL))frameHandler
  rawAudioHandler:(UltracamRawAudioHandler)rawAudioHandler
  eventHandler:(void (^)(NSString *))eventHandler error:(NSError **)error {
  __block BOOL result = NO;
  __block NSError *localError = nil;
  [self onControlQueue:^{ result = [self startOnQueue:deviceID inputFast:YES
    frameHandler:nil autoFrameHandler:frameHandler mediaHandler:nil rawAudioHandler:rawAudioHandler
    eventHandler:eventHandler error:&localError]; }];
  if (!result && error) *error = localError;
  return result;
}

- (BOOL)startAutoWithDeviceID:(NSString *)deviceID
  frameHandler:(void (^)(CVPixelBufferRef, CMTime, CMTime, BOOL))frameHandler
  mediaHandler:(UltracamMediaStatsHandler)mediaHandler
  rawAudioHandler:(UltracamRawAudioHandler)rawAudioHandler
  eventHandler:(void (^)(NSString *))eventHandler error:(NSError **)error {
  __block BOOL result = NO;
  __block NSError *localError = nil;
  [self onControlQueue:^{ result = [self startOnQueue:deviceID inputFast:YES
    frameHandler:nil autoFrameHandler:frameHandler mediaHandler:mediaHandler rawAudioHandler:rawAudioHandler
    eventHandler:eventHandler error:&localError]; }];
  if (!result && error) *error = localError;
  return result;
}

- (BOOL)startAutoWithDeviceID:(NSString *)deviceID
  frameHandler:(void (^)(CVPixelBufferRef, CMTime, CMTime, BOOL))frameHandler
  eventHandler:(void (^)(NSString *))eventHandler error:(NSError **)error {
  return [self startAutoWithDeviceID:deviceID frameHandler:frameHandler mediaHandler:nil
    eventHandler:eventHandler error:error];
}

- (BOOL)startOnQueue:(NSString *)deviceID inputFast:(BOOL)inputFast
  frameHandler:(void (^)(CVPixelBufferRef, CMTime, BOOL))frameHandler
  autoFrameHandler:(void (^)(CVPixelBufferRef, CMTime, CMTime, BOOL))autoFrameHandler
  mediaHandler:(UltracamMediaStatsHandler)mediaHandler
  rawAudioHandler:(UltracamRawAudioHandler)rawAudioHandler
  eventHandler:(void (^)(NSString *))eventHandler error:(NSError **)error {
  [self stopOnQueue];
#if ULTRACAM_HAS_SDK
  ComRef<IDeckLinkIterator> iterator; iterator.value = CreateDeckLinkIteratorInstance();
  if (!iterator) return fail(error, @"Blackmagic Desktop Video is not available.");
  ComRef<IDeckLinkInput> input; IDeckLink *raw = nullptr; NSUInteger index = 0;
  auto connection = std::make_unique<HDMILease>();
  BMDVideoInputFlags inputFlags = bmdVideoInputFlagDefault;
  while (iterator->Next(&raw) == S_OK) {
    ComRef<IDeckLink> device; device.value = raw;
    NSString *identifier = deviceIdentifier(device.value, index++);
    if (![identifier isEqualToString:deviceID]) continue;
    if (device->QueryInterface(IID_IDeckLinkInput, reinterpret_cast<void **>(input.out())) != S_OK)
      return fail(error, @"The selected Blackmagic device has no capture input.");
    HRESULT connectionStatus = connection->select(device.value);
    if (connectionStatus != S_OK) return fail(error, @"Cannot select the UltraStudio HDMI input. Close other capture apps, then restart.", connectionStatus);
    ComRef<IDeckLinkProfileAttributes> attributes;
    bool detectsFormat = false;
    if (device->QueryInterface(IID_IDeckLinkProfileAttributes, reinterpret_cast<void **>(attributes.out())) == S_OK &&
        attributes->GetFlag(BMDDeckLinkSupportsInputFormatDetection, &detectsFormat) == S_OK && detectsFormat)
      inputFlags = bmdVideoInputEnableFormatDetection;
    if (autoFrameHandler && !detectsFormat)
      return fail(error, @"This Blackmagic device/driver does not support automatic HDMI format detection.");
    break;
  }
  if (!input) return fail(error, @"UltraStudio is disconnected. Refresh the input list.");
  BMDDisplayMode requestedMode = inputFast ? bmdMode4K2160p5994 : bmdMode4K2160p2997;
  bool supported = false;
  HRESULT status = input->DoesSupportVideoMode(bmdVideoConnectionHDMI, requestedMode,
    bmdFormat10BitYUV, bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, nullptr, &supported);
  if (autoFrameHandler && (status != S_OK || !supported)) {
    requestedMode = bmdMode4K2160p2997;
    status = input->DoesSupportVideoMode(bmdVideoConnectionHDMI, requestedMode,
      bmdFormat10BitYUV, bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, nullptr, &supported);
  }
  if (status != S_OK || !supported)
    return fail(error, @"UltraStudio does not support 3840 × 2160 10-bit 4:2:2 at the selected frame rate.", status);
  auto callback = new CaptureCallback(requestedMode, inputFast ? 60000 : 30000, frameHandler, eventHandler,
    mediaHandler, rawAudioHandler);
  if (autoFrameHandler) {
    [self configureAutoCallback:callback frameHandler:autoFrameHandler];
  }
  status = startInput(input.value, callback, requestedMode, inputFlags, rawAudioHandler != nil);
  if (status != S_OK) {
    if (_autoMode) { _autoMode->cancel(); _autoMode.reset(); }
    callback->Release();
    return fail(error, status == E_ACCESSDENIED ?
      @"UltraStudio is in use by another app. Close the other capture app, then restart." :
      [NSString stringWithFormat:@"UltraStudio could not start the 4K 10-bit input (0x%08x). Check Desktop Video and HDMI settings.", (unsigned)status], status);
  }
  connection->started = true;
  _input = input.take(); _callback = callback; _connection = std::move(connection);
  return YES;
#else
  return fail(error, @"This app was built without the Blackmagic Desktop Video SDK. Configure DECKLINK_SDK_DIR and rebuild.");
#endif
}

#if ULTRACAM_HAS_SDK
- (void)configureAutoCallback:(CaptureCallback *)callback
  frameHandler:(void (^)(CVPixelBufferRef, CMTime, CMTime, BOOL))frameHandler {
  // Frames stay enabled until a format notification says otherwise. Desktop Video
  // only notifies when the signal differs from the opened mode, so an input that
  // already matches it never gets a notification and would otherwise never be delivered.
  // A mismatched signal arrives flagged without an input source, or fails the
  // 3840 × 2160 10-bit check in VideoInputFrameArrived.
  callback->framesEnabled = true;
  _autoMode = std::make_shared<AutoModeMailbox>();
  auto mailbox = _autoMode;
  callback->autoFrameHandler = [frameHandler copy];
  __weak UltracamBackend *weakSelf = self;
  dispatch_queue_t nativeQueue = _controlQueue;
  callback->modeHandler = ^(DetectedInput detected) {
    if (mailbox->push(detected, &callback->framesEnabled)) {
      // Never promote the weak backend on the driver callback thread. Releasing
      // its final reference there could run dealloc/StopStreams inside the
      // very callback StopStreams is waiting to finish.
      dispatch_async(nativeQueue, ^{
        UltracamBackend *owner = weakSelf;
        if (owner) [owner performDetection:mailbox];
        else mailbox->cancel();
      });
    }
  };
}

- (void)scheduleDetection:(std::shared_ptr<AutoModeMailbox>)mailbox {
#if defined(ULTRACAM_BACKEND_TESTING)
  if (dispatch_get_specific(UltracamControlQueueKey) != (__bridge void *)self) _scheduledOffControlQueue = YES;
#endif
  __weak UltracamBackend *weakSelf = self;
  dispatch_async(_controlQueue, ^{
    UltracamBackend *owner = weakSelf;
    if (owner) [owner performDetection:mailbox];
    else mailbox->cancel();
  });
}

- (void)performDetection:(std::shared_ptr<AutoModeMailbox>)mailbox {
  if (_autoMode != mailbox || !_input || !_callback) return;
  auto detected = mailbox->snapshot();
  if (!detected) return;
  CaptureCallback *callback = _callback;
  if (!callback->accepting) { mailbox->cancel(); return; }
  if (!detected->supported) {
    if (mailbox->isCurrent(detected->sequence))
      callback->eventHandler([NSString stringWithFormat:@"Unsupported HDMI input: %@. Requires 4K YUV 4:2:2 at 29.97 or 59.94 fps with at least 10-bit source precision.", detected->description]);
  } else {
    bool supported = false;
    HRESULT status = _input->DoesSupportVideoMode(bmdVideoConnectionHDMI, detected->mode,
      bmdFormat10BitYUV, bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, nullptr, &supported);
    if (status == S_OK && supported) status = reconfigureInput(_input, callback, *detected);
    if (status != S_OK || !supported) {
      if (mailbox->cancelCurrent(detected->sequence, callback->accepting))
        callback->reportFatal([NSString stringWithFormat:@"Cannot capture detected HDMI input: %@ (0x%08x).", detected->description, (unsigned)status]);
    } else if (mailbox->enableCurrent(detected->sequence, callback->framesEnabled, &callback->accepting)) {
      callback->eventHandler([NSString stringWithFormat:@"Detected HDMI input: %@ — capturing 10-bit YUV 4:2:2.", detected->description]);
    }
  }
  if (mailbox->finish(detected->sequence)) [self scheduleDetection:mailbox];
}
#endif

- (void)stop { [self onControlQueue:^{ [self stopOnQueue]; }]; }

- (void)stopOnQueue {
#if ULTRACAM_HAS_SDK
  if (_autoMode) { _autoMode->cancel(); _autoMode.reset(); }
  if (_input) {
    stopInput(_input, _callback);
    // Restore while this successful session still holds its input, never after release.
    _connection.reset();
    _input->Release(); _input = nullptr;
  } else {
    if (_connection) _connection->started = false;
    _connection.reset();
  }
  if (_callback) { _callback->Release(); _callback = nullptr; }
#endif
}

#if defined(ULTRACAM_BACKEND_TESTING) && ULTRACAM_HAS_SDK && BLACKMAGIC_DECKLINK_API_VERSION < 0x0e030000
- (BOOL)runOwnershipChecks:(NSError **)error {
  // Keep the legacy callback/media coverage here; its included lifecycle fixture
  // requires StopStreams on failed starts and cannot exercise owned startup.
  {
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
  }
  // Fake SDK objects only. Exercise the same control queue and teardown as the API.
  __block bool nested = false;
  [self onControlQueue:^{
    [self onControlQueue:^{ nested = true; }];
    [self stop];
  }];
  if (!nested) return fail(error, @"Reentrant control-queue execution did not run inline.");

  for (int scenario = 0; scenario != 5; ++scenario) {
    FakeInput input;
    if (scenario == 1) input.enableResult = E_ACCESSDENIED;
    if (scenario == 2) input.callbackResult = E_FAIL;
    if (scenario == 3) input.startResult = E_FAIL;
    ComRef<CaptureCallback> callback;
    callback.value = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, nil);
    HRESULT status = startInput(&input, callback.value, bmdMode4K2160p5994,
      bmdVideoInputFlagDefault, scenario == 4);
    if ((scenario == 0) != (status == S_OK))
      return fail(error, @"Owned startup did not preserve failure status.");
    if (scenario == 0) {
      stopInput(&input, callback.value);
      if (input.calls != std::vector<std::string>{"enable", "callback", "start", "stop", "clear", "disable"})
        return fail(error, @"Successful input teardown changed its synchronous stop order.");
    }
    auto stops = std::count(input.calls.begin(), input.calls.end(), "stop");
    if (stops != (scenario == 0 ? 1 : 0) || input.callback ||
        callback->accepting || callback->references != 1)
      return fail(error, @"A failed start stopped streams or retained a callback.");
    if (scenario == 1 && input.calls != std::vector<std::string>{"enable"})
      return fail(error, @"Competing startup changed an input it did not acquire.");
  }

  FakeInput shared;
  ComRef<CaptureCallback> owner, competitor;
  owner.value = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, nil);
  competitor.value = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, nil);
  if (startInput(&shared, owner.value, bmdMode4K2160p5994, bmdVideoInputFlagDefault) != S_OK)
    return fail(error, @"Synthetic owner failed to start.");
  shared.calls.clear();
  shared.enableResult = E_ACCESSDENIED;
  if (startInput(&shared, competitor.value, bmdMode4K2160p5994, bmdVideoInputFlagDefault) == S_OK ||
      shared.callback != owner.value || shared.calls != std::vector<std::string>{"enable"})
    return fail(error, @"Failed competing start disturbed the active owner's input.");
  stopInput(&shared, owner.value);

  for (int scenario = 0; scenario != 5; ++scenario) {
    FakeInput input;
    FakeConfiguration configuration;
    configuration.connection = scenario == 3 ? bmdVideoConnectionOpticalSDI : bmdVideoConnectionHDMI;
    FakeInput *inputPointer = &input;
    FakeConfiguration *configurationPointer = &configuration;
    [self onControlQueue:^{
      auto lease = std::make_unique<HDMILease>();
      lease->configuration.value = configurationPointer; configurationPointer->AddRef();
      lease->previous = bmdVideoConnectionSDI;
      lease->changed = scenario != 4;
      lease->started = scenario != 1;
      self->_connection = std::move(lease);
      // Scenarios 1 and 2 represent never-started and already-released inputs.
      if (scenario != 1 && scenario != 2) {
        self->_input = inputPointer; inputPointer->AddRef();
        self->_callback = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, nil);
      }
      [self stop];
      [self stop];
    }];
    if (configuration.writes != (scenario == 0 ? 1 : 0) || configuration.references != 1 ||
        input.references != 1 || configuration.persistentWrites)
      return fail(error, @"Connector restore escaped successful input ownership.");
    if (scenario == 0 && configuration.connection != bmdVideoConnectionSDI)
      return fail(error, @"Owned HDMI connection was not restored before input release.");
    if ((scenario == 1 || scenario == 2) && !input.calls.empty())
      return fail(error, @"Never-started or released input was stopped.");
  }

  // Preserve the legacy fixture's post-start callback checks as well.
  __block int events = 0;
  ComRef<CaptureCallback> callback;
  callback.value = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, ^(NSString *) { ++events; });
  FakeMode mode;
  callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, bmdDetectedVideoInputYCbCr422);
  if (events || !callback->accepting) return fail(error, @"Matching mode stopped capture.");
  mode.mode = bmdMode4K2160p2997;
  callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, bmdDetectedVideoInputYCbCr422);
  callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, bmdDetectedVideoInputYCbCr422);
  if (events != 1 || callback->accepting) return fail(error, @"Changed mode was not rejected once.");
  ComRef<CaptureCallback> noHandlers;
  noHandlers.value = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, nil);
  if (!noHandlers->frameHandler || !noHandlers->eventHandler)
    return fail(error, @"Callback did not install safe no-op handlers.");
  return YES;
}

- (BOOL)runAutoChecks:(NSError **)error {
  // Uses the production queue, callback adapter and reconfiguration method.
  // No real device is enumerated or opened by this fixture.
  FakeInput input;
  struct StopGuard {
    __unsafe_unretained UltracamBackend *owner;
    ~StopGuard() { [owner stop]; }
  } stopGuard{self};
  FakeInput *inputPointer = &input;
  __block int events = 0, frames = 0, fatalEvents = 0;
  __block NSString *lastEvent = nil;
  __block CMTime deliveredDuration = kCMTimeInvalid;
  auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000, nil,
    ^(NSString *message) { ++events; lastEvent = message; if ([message hasPrefix:@"Capture error: "]) ++fatalEvents; });
  callback->AddRef(); // Test retains the old callback beyond backend stop.
  ComRef<CaptureCallback> callbackReference; callbackReference.value = callback;
  [self onControlQueue:^{
    self->_input = inputPointer; inputPointer->AddRef(); self->_callback = callback;
    [self configureAutoCallback:callback frameHandler:^(CVPixelBufferRef, CMTime, CMTime duration, BOOL valid) {
      if (valid) { ++frames; deliveredDuration = duration; }
    }];
    inputPointer->SetCallback(callback);
  }];
  FakeMode mode;
  mode.mode = bmdMode4K2160p2997;
  auto flags = bmdDetectedVideoInputYCbCr422 | bmdDetectedVideoInput10BitDepth;
  callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, flags);
  [self onControlQueue:^{}]; // Drain the actual native reconfiguration.
  const std::vector<std::string> expected = {"callback", "support", "pause", "enable", "flush", "start"};
  if (_scheduledOffControlQueue || input.calls != expected || input.reconfiguredOnMainThread || !callback->framesEnabled ||
      input.enabledMode != bmdMode4K2160p2997 || events != 1 || ![lastEvent containsString:@"29.97"])
    return fail(error, @"Auto detection did not reconfigure 29.97 on the native control queue.");
  bool destroyed = false;
  auto frame = new FakeFrame(&destroyed); frame->frameDuration = 2002;
  ComRef<IDeckLinkVideoInputFrame> frameReference; frameReference.value = frame;
  callback->VideoInputFrameArrived(frame, nullptr);
  if (frames != 1 || CMTimeCompare(deliveredDuration, CMTimeMake(1001, 30000)) != 0)
    return fail(error, @"Auto frame handler did not report the actual rational source duration.");

  // A repeat notification must not restart the driver; source-rate changes do.
  callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, flags);
  [self onControlQueue:^{}];
  if (input.calls != expected) return fail(error, @"Repeated auto detection restarted the input.");
  mode.mode = bmdMode4K2160p5994;
  callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, flags);
  [self onControlQueue:^{}];
  frame->frameDuration = 1001;
  callback->VideoInputFrameArrived(frame, nullptr);
  if (frames != 2 || input.enabledMode != bmdMode4K2160p5994 ||
      CMTimeCompare(deliveredDuration, CMTimeMake(1001, 60000)) != 0)
    return fail(error, @"Live 29.97 to 59.94 change did not update the source duration.");

  // Unsupported dimensions and source precision are reported accurately and
  // gated without destroying the detector, so a later valid source recovers.
  mode.width = 1920; mode.height = 1080; mode.mode = bmdModeHD1080p5994;
  callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, flags);
  [self onControlQueue:^{}];
  callback->VideoInputFrameArrived(frame, nullptr);
  if (callback->framesEnabled || frames != 2 || ![lastEvent containsString:@"1920 × 1080"] || ![lastEvent containsString:@"59.94"])
    return fail(error, @"Unsupported HDMI detection fabricated expected input metadata.");
  mode.width = 3840; mode.height = 2160; mode.mode = bmdMode4K2160p5994;
  callback->VideoInputFormatChanged(bmdVideoInputColorspaceChanged, &mode,
    bmdDetectedVideoInputYCbCr422 | bmdDetectedVideoInput8BitDepth);
  [self onControlQueue:^{}];
  if (callback->framesEnabled || ![lastEvent containsString:@"8-bit"])
    return fail(error, @"Auto mode silently promoted an explicitly 8-bit source.");
  callback->VideoInputFormatChanged(bmdVideoInputColorspaceChanged, &mode, flags);
  [self onControlQueue:^{}];
  if (!callback->framesEnabled) return fail(error, @"Auto mode did not recover from unsupported source format.");
  int priorEvents = events;
  frame->noSignal = true;
  callback->VideoInputFrameArrived(frame, nullptr); callback->VideoInputFrameArrived(frame, nullptr);
  if (events != priorEvents + 1 || !callback->accepting)
    return fail(error, @"Auto mode did not remain armed after deduplicated signal loss.");
  frame->noSignal = false;
  callback->VideoInputFrameArrived(frame, nullptr);
  if (frames != 3) return fail(error, @"Auto mode did not resume after signal returned.");

  // A newer format notification can arrive while the older mode is pausing.
  // An error for that obsolete mode must not terminate the newer valid input.
  FakeMode *modePointer = &mode;
  input.pauseResult = E_FAIL;
  input.onPause = ^{
    inputPointer->onPause = nil;
    inputPointer->pauseResult = S_OK;
    modePointer->mode = bmdMode4K2160p5994;
    callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, modePointer, flags);
  };
  mode.mode = bmdMode4K2160p2997;
  callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, flags);
  [self onControlQueue:^{}];
  [self onControlQueue:^{}];
  if (fatalEvents || !callback->accepting || !callback->framesEnabled || input.enabledMode != bmdMode4K2160p5994)
    return fail(error, @"An obsolete format-change failure stopped a newer valid source.");

  input.pauseResult = E_FAIL;
  mode.mode = bmdMode4K2160p2997;
  callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, flags);
  [self onControlQueue:^{}];
  if (callback->accepting || callback->framesEnabled || fatalEvents != 1 || ![lastEvent hasPrefix:@"Capture error: "])
    return fail(error, @"Permanent auto reconfiguration failure was presented as recoverable signal loss.");

  auto cancelled = _autoMode;
  [self stop];
  callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, flags);
  callback->VideoInputFrameArrived(frame, nullptr);
  DetectedInput late = describeInput(&mode, flags);
  if (frames != 3 || cancelled->push(late) || cancelled->snapshot() || input.callback)
    return fail(error, @"Stopped auto detection resurrected a callback or queued mode.");
  frameReference.take()->Release(); callbackReference.take()->Release();
  if (!destroyed || input.references != 1) return fail(error, @"Auto detection leaked native frame/input references.");

  AutoModeMailbox mailbox;
  std::atomic<bool> gate{true};
  if (!mailbox.push(late, &gate) || gate) return fail(error, @"Auto mailbox did not gate the initial transition.");
  auto first = mailbox.snapshot();
  for (int index = 0; index != 1000; ++index) {
    late.mode = index % 2 ? bmdMode4K2160p2997 : bmdMode4K2160p5994;
    if (mailbox.push(late, &gate)) return fail(error, @"Mode burst queued more than one reconfiguration.");
  }
  if (!first || mailbox.enableCurrent(first->sequence, gate) || !mailbox.finish(first->sequence))
    return fail(error, @"A stale mode enabled frames during a newer pending transition.");
  auto latest = mailbox.snapshot();
  if (!latest || latest->mode != bmdMode4K2160p2997 || !mailbox.enableCurrent(latest->sequence, gate) ||
      mailbox.finish(latest->sequence) || !gate)
    return fail(error, @"Coalesced auto mode did not publish only the newest detection.");
  mailbox.cancel();
  if (mailbox.push(late, &gate) || mailbox.enableCurrent(latest->sequence, gate))
    return fail(error, @"Cancelled auto mailbox accepted new work.");

  FakeMode invalidMode;
  invalidMode.invalidRate = true;
  auto invalidDetection = describeInput(&invalidMode, flags);
  if (invalidDetection.supported || ![invalidDetection.description containsString:@"unknown frame rate"])
    return fail(error, @"Failed native frame-rate query fabricated a supported cadence.");
  FakeMode validMode;
  auto unknownDepth = describeInput(&validMode, bmdDetectedVideoInputYCbCr422);
  auto unknownColor = describeInput(&validMode, bmdDetectedVideoInput10BitDepth);
  if (unknownDepth.supported || unknownColor.supported)
    return fail(error, @"Auto detection accepted an input without explicit 10-bit YUV 4:2:2 metadata.");

  // Every partial driver reconfiguration failure keeps frames disabled.
  for (int scenario = 0; scenario != 4; ++scenario) {
    FakeInput failure;
    if (scenario == 0) failure.pauseResult = E_FAIL;
    if (scenario == 1) failure.enableResult = E_FAIL;
    if (scenario == 2) failure.flushResult = E_FAIL;
    if (scenario == 3) failure.startResult = E_FAIL;
    callback = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, ^(NSString *) {});
    if (reconfigureInput(&failure, callback, late) == S_OK || callback->framesEnabled)
      return fail(error, @"Partial auto reconfiguration delivered stale-format frames.");
    callback->Release();
  }
  FakeInput terminal;
  callback = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, ^(NSString *) {});
  terminal.onPause = ^{ callback->reportFatal(@"Synthetic terminal frame error"); };
  if (reconfigureInput(&terminal, callback, late) == S_OK ||
      terminal.calls != std::vector<std::string>{"pause"} || callback->framesEnabled)
    return fail(error, @"Driver restarted after a terminal callback error during reconfiguration.");
  callback->Release();
  return YES;
}
#endif

- (void)dealloc {
  // A synchronous cleanup must not retain self in a block during deallocation.
  __unsafe_unretained UltracamBackend *owner = self;
  if (dispatch_get_specific(UltracamControlQueueKey) == (__bridge void *)self) [self stopOnQueue];
  else dispatch_sync(_controlQueue, ^{ [owner stopOnQueue]; });
}
@end

#if defined(ULTRACAM_BACKEND_TESTING)
BOOL UltracamRunOwnershipSyntheticChecks(NSError **error) {
#if ULTRACAM_HAS_SDK && BLACKMAGIC_DECKLINK_API_VERSION < 0x0e030000
  UltracamBackend *backend = [UltracamBackend new];
  return [backend runOwnershipChecks:error];
#else
  return fail(error, @"Ownership SDK mocks require the pinned SDK12 interfaces.");
#endif
}

BOOL UltracamRunAutoSyntheticChecks(NSError **error) {
#if ULTRACAM_HAS_SDK && BLACKMAGIC_DECKLINK_API_VERSION < 0x0e030000
  UltracamBackend *backend = [UltracamBackend new];
  return [backend runAutoChecks:error];
#else
  return fail(error, @"Auto SDK mocks require the pinned SDK12 interfaces.");
#endif
}
#endif
