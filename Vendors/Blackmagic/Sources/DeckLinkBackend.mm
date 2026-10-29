#import "DeckLinkBackend.h"
#import <os/log.h>
#include <atomic>
#include <vector>
#include <utility>
#include <memory>
#include <cstring>
#include <mutex>
#include <optional>
#include <cmath>
#include <cstdint>
#include <algorithm>
#include <limits>
#include <map>
#include <string>

// The DeckLink SDK 16 headers are in the repo (Vendors/Blackmagic/SDK/include);
// every build adds them to the header search path. There is no SDK-less build.
#if !__has_include("DeckLinkAPI.h")
#error "DeckLinkAPI.h not found: add Vendors/Blackmagic/SDK/include (or DECKLINK_SDK_DIR) to the header search path."
#endif
#include "DeckLinkAPI.h"
#include "DeckLinkAPIConfiguration.h"
#include "DeckLinkAPIVersion.h"
// Capture relies on SDK 16's IOSurface-backed input buffers (Vendors/Blackmagic/SDK).
#if BLACKMAGIC_DECKLINK_API_VERSION < 0x10000000
#error "Ultracam requires DeckLink SDK 16.0 or later (Vendors/Blackmagic/SDK)."
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
@property(nonatomic) uint32_t videoInputConnections;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSArray<UltracamMode *> *modes;
@end
@implementation UltracamDevice
@end

@interface UltracamDriverInfo ()
@property(nonatomic) BOOL installed;
@property(nonatomic) BOOL supported;
@property(nonatomic) int64_t versionValue;
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy, nullable) NSString *message;
@end
@implementation UltracamDriverInfo
@end

@interface UltracamHDRAdvertisementState ()
@property(nonatomic) BOOL enabled;
@property(nonatomic, nullable) NSError *applicationError;
@end
@implementation UltracamHDRAdvertisementState
@end
@interface UCDeckLinkConnectorState ()
@property(nonatomic) uint32_t connection;
@property(nonatomic, nullable) NSError *applicationError;
@end
@implementation UCDeckLinkConnectorState
@end

@interface UltracamDeviceDiagnostics ()
@property(nonatomic, nullable) NSNumber *signalPresent;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *driverVersion;
@property(nonatomic) NSInteger maximumHDMIAudioChannels;
@property(nonatomic) NSInteger capturedAudioChannels;
@property(nonatomic) BOOL supportsFormatDetection;
@property(nonatomic) BOOL supportsHDRMetadata;
@property(nonatomic) BOOL supportsColorspaceMetadata;
@property(nonatomic) BOOL supportsHDMITimecode;
@property(nonatomic) BOOL supportsHighFrameRateTimecode;
@property(nonatomic) BOOL sessionActive;
@property(nonatomic) uint64_t deviceDroppedFrames;
@property(nonatomic) uint32_t frameBacklog;
@property(nonatomic) uint32_t maximumFrameBacklog;
@property(nonatomic) NSInteger temperatureCelsius;
@property(nonatomic) BOOL hostTimeMapped;
@property(nonatomic, copy, nullable) NSString *signal;
@property(nonatomic, copy) NSString *hdmiDynamicRange;
@end
@implementation UltracamDeviceDiagnostics
@end



static os_log_t backendLog() {
  static os_log_t log = os_log_create("org.ultracam.app", "decklink");
  return log;
}
static NSError *hdrSettingsError(HRESULT result) {
  NSInteger code = result == E_INVALIDARG ? 1 : result == E_NOINTERFACE ? 2 : result == E_ACCESSDENIED ? 3 : 4;
  NSString *message = code == 1 ? @"The DeckLink device is no longer available." :
    code == 2 ? @"This DeckLink device does not support HDMI EDID advertisement." :
    code == 3 ? @"Another application is capturing this device; its HDMI EDID was left unchanged." :
    [NSString stringWithFormat:@"Desktop Video could not update the HDMI EDID (0x%08x).", (unsigned)result];
  return [NSError errorWithDomain:@"UCDeckLinkSettings" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}
static NSError *connectorSettingsError(HRESULT result) {
  const NSInteger code = result == E_INVALIDARG ? 1 : result == E_NOINTERFACE ? 2 : result == E_ACCESSDENIED ? 3 : 4;
  NSString *message = code == 1 ? @"The capture device is no longer available." :
    code == 2 ? @"This device does not support the requested input connector." :
    code == 3 ? @"Stop capture before changing the input connector; another application may also be using it." :
    @"Desktop Video did not confirm the requested input connector.";
  return [NSError errorWithDomain:@"UCDeckLinkSettings" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL fail(NSError **error, NSString *message, NSInteger code = 1) {
  if (error) *error = [NSError errorWithDomain:@"org.ultracam.decklink" code:code
    userInfo:@{NSLocalizedDescriptionKey: message}];
  return NO;
}

// Own exactly one COM reference. Discovery/start failure paths release partial
// resources automatically; callback/frame references have independent lives.
template <typename T> struct ComRef {
  T *value = nullptr;
  ~ComRef() { if (value) value->Release(); }
  T **out() { return &value; }
  T *operator->() const { return value; }
  explicit operator bool() const { return value != nullptr; }
  T *take() { T *result = value; value = nullptr; return result; }
  void reset() { if (value) value->Release(); value = nullptr; }
};

// The HDMI EDID Ultracam advertises when "Advertise HDR to cameras" is on: SDR
// plus both static HDR transfer functions, so an FX3 in HLG keeps signalling
// HLG instead of falling back. The driver default is SDR | PQ (DeckLinkAPI.h,
// bmdDeckLinkHDMIInputEDIDDynamicRange).
static constexpr int64_t kAdvertisedDynamicRange =
  bmdDynamicRangeSDR | bmdDynamicRangeHDRStaticPQ | bmdDynamicRangeHDRStaticHLG;

static NSString *dynamicRangeList(int64_t value) {
  NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:@"SDR"];
  if (value & bmdDynamicRangeHDRStaticPQ) [parts addObject:@"PQ"];
  if (value & bmdDynamicRangeHDRStaticHLG) [parts addObject:@"HLG"];
  return [parts componentsJoinedByString:@" · "];
}

// Advertises kAdvertisedDynamicRange and returns the reference that keeps it:
// releasing every IDeckLinkHDMIInputEDID reference restores the default EDID
// (DeckLinkAPI.h). Writing the EDID is an HDMI hot-plug (the camera re-reads it
// and drops its signal for seconds), so only the device registry calls this,
// when a device is discovered or the setting is turned on; a capture start
// never does. S_OK: written. S_FALSE: already advertised, held, not rewritten.
static HRESULT advertiseHDR(IDeckLink *device, ComRef<IDeckLinkHDMIInputEDID> &held) {
  ComRef<IDeckLinkHDMIInputEDID> candidate;
  HRESULT status = device->QueryInterface(IID_IDeckLinkHDMIInputEDID, reinterpret_cast<void **>(candidate.out()));
  if (status != S_OK || !candidate) return status == S_OK ? E_NOINTERFACE : status;
  int64_t current = 0;
  if (candidate->GetInt(bmdDeckLinkHDMIInputEDIDDynamicRange, &current) == S_OK &&
      (current & kAdvertisedDynamicRange) == kAdvertisedDynamicRange) {
    held.value = candidate.take();
    return S_FALSE;
  }
  status = candidate->SetInt(bmdDeckLinkHDMIInputEDIDDynamicRange, kAdvertisedDynamicRange);
  if (status == S_OK) status = candidate->WriteToEDID();
  if (status != S_OK) return status;  // Releasing the candidate restores the default.
  held.value = candidate.take();
  return S_OK;
}

// Session-only HDMI selection. Never persist device preferences. Restore only
// the value this session still owns, preserving a subsequent outside change.
// The EDID is not the session's: see advertiseHDR.
struct HDMILease {
  ComRef<IDeckLinkConfiguration> configuration;
  int64_t previous = bmdVideoConnectionHDMI;
  bool changed = false;
  bool started = false;
  BMDVideoConnection selected = bmdVideoConnectionHDMI;
  ~HDMILease() {
    if (started) restoreConnector();
  }
  // A start that failed after select: put back the connector now, while the
  // caller still holds the device's input, so a failed claim leaves the other
  // app's HDMI setup as it found it.
  void abandon() { restoreConnector(); }
  void restoreConnector() {
    int64_t current = 0;
    if (changed && configuration && configuration->GetInt(bmdDeckLinkConfigVideoInputConnection, &current) == S_OK && current == selected)
      configuration->SetInt(bmdDeckLinkConfigVideoInputConnection, previous);
    changed = false;
  }
  HRESULT select(IDeckLink *device, BMDVideoConnection connection = bmdVideoConnectionHDMI) {
    selected = connection;
    HRESULT status = device->QueryInterface(IID_IDeckLinkConfiguration, reinterpret_cast<void **>(configuration.out()));
    if (status != S_OK) return status;
    status = configuration->GetInt(bmdDeckLinkConfigVideoInputConnection, &previous);
    if (status != S_OK || previous == selected) return status;
    status = configuration->SetInt(bmdDeckLinkConfigVideoInputConnection, selected);
    changed = status == S_OK;
    if (status == S_OK) {
      int64_t actual = 0;
      status = configuration->GetInt(bmdDeckLinkConfigVideoInputConnection, &actual);
      if (status == S_OK && actual != selected) status = E_FAIL;
    }
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

// Native wire validation precedes the Swift route/table admission. This is the
// current two-mode SDK contract, not another extensible pixel-format table.
struct NativeFrameContract {
  long width = 3840, height = 2160;
  CMTime duration;
  BMDPixelFormat pixel = bmdFormat10BitYUV;
};
static std::optional<NativeFrameContract> nativeFrameContract(IDeckLinkDisplayMode *mode) {
  if (!mode || mode->GetFieldDominance() != bmdProgressiveFrame) return std::nullopt;
  BMDTimeValue duration = 0; BMDTimeScale scale = 0;
  if (mode->GetFrameRate(&duration, &scale) != S_OK || duration <= 0 || scale <= 0 || scale > INT32_MAX ||
      mode->GetWidth() <= 0 || mode->GetHeight() <= 0 || mode->GetWidth() > 16384 || mode->GetHeight() > 16384) return std::nullopt;
  const double fps = double(scale) / double(duration);
  if (fps < 23 || fps > 120) return std::nullopt;
  return NativeFrameContract{mode->GetWidth(), mode->GetHeight(), CMTimeMake(duration, int32_t(scale))};
}
static std::optional<NativeFrameContract> nativeFrameContract(BMDDisplayMode mode) {
  if (mode == bmdMode4K2160p2997) return NativeFrameContract{3840, 2160, CMTimeMake(1001, 30000)};
  if (mode == bmdMode4K2160p5994) return NativeFrameContract{3840, 2160, CMTimeMake(1001, 60000)};
  return std::nullopt;
}
static uint64_t minimumV210RowBytes(uint64_t width) {
  // v210 wire packing: six pixels in sixteen bytes. The Swift table owns route
  // policy; these checked SDK boundary operations never access CPU pixels.
  if (!width || width > UINT64_MAX - 5) return 0;
  const uint64_t groups = (width + 5) / 6;
  return groups > UINT64_MAX / 16 ? 0 : groups * 16;
}
static bool validPackedExtent(uint64_t width, uint64_t height, uint64_t rowBytes,
  uint64_t size, bool sizeKnown, BMDPixelFormat pixel = bmdFormat10BitYUV) {
  uint64_t minimum = minimumV210RowBytes(width);
  uint64_t alignment = 4;
  if (pixel == bmdFormat8BitYUV) { minimum = width <= UINT64_MAX / 2 ? width * 2 : 0; alignment = 2; }
  else if (pixel == bmdFormat10BitRGB) minimum = width <= UINT64_MAX / 4 ? width * 4 : 0;
  else if (pixel == bmdFormat12BitRGBLE) { minimum = width <= (UINT64_MAX - 1) / 9 ? (width * 9 + 1) / 2 : 0; alignment = 1; }
  if (!minimum || !height || rowBytes < minimum || rowBytes % alignment ||
      rowBytes > UINT64_MAX / height) return false;
  return !sizeKnown || size >= rowBytes * height;
}
static NSArray<UltracamMode *> *supportedModes(IDeckLinkInput *input, BMDVideoConnection connection = bmdVideoConnectionHDMI) {
  NSMutableArray<UltracamMode *> *result = [NSMutableArray array];
  ComRef<IDeckLinkDisplayModeIterator> iterator;
  if (input->GetDisplayModeIterator(iterator.out()) != S_OK) return result;
  IDeckLinkDisplayMode *raw = nullptr;
  while (iterator->Next(&raw) == S_OK) {
    ComRef<IDeckLinkDisplayMode> mode; mode.value = raw;
    BMDTimeValue duration = 0; BMDTimeScale scale = 0;
    mode->GetFrameRate(&duration, &scale);
    auto contract = nativeFrameContract(mode.value);
    if (!contract || mode->GetWidth() != contract->width || mode->GetHeight() != contract->height ||
        mode->GetFieldDominance() != bmdProgressiveFrame) continue;
    bool supported = false;
    if (input->DoesSupportVideoMode(connection, mode->GetDisplayMode(),
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


// MARK: Colorimetry

// Display-mode colorspace flags (IDeckLinkDisplayMode::GetFlags) to BMDColorspace.
static BMDColorspace colorspaceFromModeFlags(BMDDisplayModeFlags flags) {
  if (flags & bmdDisplayModeColorspaceRec2020) return bmdColorspaceRec2020;
  if (flags & bmdDisplayModeColorspaceRec709) return bmdColorspaceRec709;
  if (flags & bmdDisplayModeColorspaceRec601) return bmdColorspaceRec601;
  return 0;
}

static NSString *colorspaceName(BMDColorspace colorspace) {
  switch (colorspace) {
    case bmdColorspaceRec709: return @"Rec.709";
    case bmdColorspaceRec2020: return @"Rec.2020";
    case bmdColorspaceRec601: return @"Rec.601";
    default: return nil;
  }
}

// CEA-861.3 EOTF codes, as reported by bmdDeckLinkFrameMetadataHDRElectroOpticalTransferFunc.
enum : int64_t { kEOTFUnknown = -1, kEOTFSDR = 0, kEOTFHDRGamma = 1, kEOTFPQ = 2, kEOTFHLG = 3 };

static int64_t eotfFromDynamicRange(int64_t range) {
  if (range & bmdDynamicRangeHDRStaticHLG) return kEOTFHLG;
  if (range & bmdDynamicRangeHDRStaticPQ) return kEOTFPQ;
  return kEOTFSDR;
}

static NSString *eotfName(int64_t eotf) {
  switch (eotf) {
    case kEOTFSDR: return @"SDR";
    case kEOTFHDRGamma: return @"HDR gamma";
    case kEOTFPQ: return @"HDR PQ";
    case kEOTFHLG: return @"HDR HLG";
    default: return nil;
  }
}

static NSString *colorimetryText(BMDColorspace colorspace, int64_t eotf) {
  NSString *space = colorspaceName(colorspace) ?: @"unreported colorspace";
  NSString *range = eotfName(eotf) ?: @"unreported dynamic range";
  return [NSString stringWithFormat:@"%@ · %@", space, range];
}

// Writes primaries, matrix and transfer function. Values from the frame's own
// metadata override whatever the SDK attached; values from detection (status
// or display-mode flags) only fill attachments the SDK left empty.
static void applyColorimetry(CVPixelBufferRef buffer, BMDColorspace colorspace, bool colorspaceFromFrame,
  int64_t eotf, bool eotfFromFrame) {
  CFStringRef primaries = nullptr, matrix = nullptr, transfer = nullptr;
  switch (colorspace) {
    case bmdColorspaceRec709:
      primaries = kCVImageBufferColorPrimaries_ITU_R_709_2; matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2; break;
    case bmdColorspaceRec2020:
      primaries = kCVImageBufferColorPrimaries_ITU_R_2020; matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020; break;
    case bmdColorspaceRec601:
      primaries = kCVImageBufferColorPrimaries_SMPTE_C; matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4; break;
    default: break;
  }
  switch (eotf) {
    case kEOTFSDR: transfer = kCVImageBufferTransferFunction_ITU_R_709_2; break;
    case kEOTFPQ: transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ; break;
    case kEOTFHLG: transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG; break;
    default: break;
  }
  auto set = [buffer](CFStringRef key, CFStringRef value, bool authoritative) {
    if (!value) return;
    if (!authoritative) {
      CFTypeRef existing = CVBufferCopyAttachment(buffer, key, nullptr);
      if (existing) { CFRelease(existing); return; }
    }
    CVBufferSetAttachment(buffer, key, value, kCVAttachmentMode_ShouldPropagate);
  };
  set(kCVImageBufferColorPrimariesKey, primaries, colorspaceFromFrame);
  set(kCVImageBufferYCbCrMatrixKey, matrix, colorspaceFromFrame);
  set(kCVImageBufferTransferFunctionKey, transfer, eotfFromFrame);
}

// MARK: Host clock

static int64_t hostMicroseconds() {
  return CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), 1000000,
    kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
}

// The hardware reference clock is locked to the system clock but its absolute
// value is unspecified (manual 2.5.4.17). Map it by bracketing a clock read
// with host reads and keeping the tightest bracket. Microseconds match the
// SDK's own InputLoopThrough sample and keep driver arithmetic far from overflow.
static constexpr BMDTimeScale kReferenceTimeScale = 1000000;

// A reading is only as good as its bracket: the offset is known to within half
// the window. Readings whose window is a millisecond or wider (preempted, or a
// slow driver call) are discarded rather than smoothed in.
static constexpr int64_t kMaximumHostWindowMicros = 1000;

struct HostClockSample {
  int64_t offsetMicros = 0;  // Host time minus hardware reference time.
  int64_t windowMicros = INT64_MAX;
};

static bool sampleHostOffset(IDeckLinkInput *input, HostClockSample *sample) {
  HostClockSample best;
  for (int attempt = 0; attempt != 6; ++attempt) {
    BMDTimeValue hardware = 0, timeInFrame = 0, ticksPerFrame = 0;
    int64_t before = hostMicroseconds();
    HRESULT status = input->GetHardwareReferenceClock(kReferenceTimeScale, &hardware, &timeInFrame, &ticksPerFrame);
    int64_t after = hostMicroseconds();
    if (status != S_OK || after < before) continue;
    if (after - before < best.windowMicros) {
      best.windowMicros = after - before;
      best.offsetMicros = before + (after - before) / 2 - hardware;
    }
  }
  if (best.windowMicros >= kMaximumHostWindowMicros) return false;
  *sample = best;
  return true;
}

// Control queue only. The two clocks are locked, so the true offset is
// constant and the readings differ only by bracket jitter. Keep the
// narrowest-window reading of the last few polls (a min-window filter) and
// move the published offset toward it gradually. A tight reading far from the
// estimate means the mapping itself moved (a driver restart), so it is
// adopted at once instead of being averaged in.
struct HostOffsetFilter {
  static constexpr int kHistory = 8;
  static constexpr int64_t kStepMicros = 2000;
  HostClockSample history[kHistory];
  int count = 0, next = 0;
  bool valid = false;
  double estimate = 0;
  void reset() { count = 0; next = 0; valid = false; estimate = 0; }
  // Returns whether `offsetMicros` holds a usable estimate after this reading.
  bool offer(HostClockSample sample, int64_t *offsetMicros) {
    if (sample.windowMicros >= 0 && sample.windowMicros < kMaximumHostWindowMicros) {
      if (valid && std::llabs(sample.offsetMicros - std::llround(estimate)) > kStepMicros) {
        count = 0; next = 0; valid = false;
      }
      history[next] = sample; next = (next + 1) % kHistory; count = std::min(count + 1, kHistory);
      const HostClockSample *narrowest = &history[0];
      for (int index = 1; index < count; ++index)
        if (history[index].windowMicros < narrowest->windowMicros) narrowest = &history[index];
      if (!valid) { estimate = double(narrowest->offsetMicros); valid = true; }
      else estimate += (double(narrowest->offsetMicros) - estimate) * 0.25;
    }
    if (valid) *offsetMicros = std::llround(estimate);
    return valid;
  }
};

// MARK: Session statistics

// Shared between the frame callback, the control queue and diagnostics. One
// instance per backend for its whole life, so readers never race a swap.
struct SessionStats {
  std::atomic<int> signalPresent{-1}; // -1 unknown, 0 absent, 1 present
  std::atomic<uint64_t> deviceDrops{0};
  std::atomic<uint32_t> backlog{0}, maxBacklog{0};
  std::atomic<int64_t> hostOffsetMicros{0};
  std::atomic<bool> hostOffsetValid{false};
  std::atomic<int64_t> temperature{INT64_MIN};
  std::atomic<bool> active{false};
  std::atomic<uint32_t> capturedAudioChannels{2};
  std::mutex textMutex;
  NSString *signal = nil;
  void reset() {
    deviceDrops = 0; backlog = 0; maxBacklog = 0; hostOffsetValid = false; temperature = INT64_MIN;
    signalPresent = -1;
    std::lock_guard<std::mutex> guard(textMutex);
    signal = nil;
  }
  void setSignal(NSString *value) { std::lock_guard<std::mutex> guard(textMutex); signal = [value copy]; }
};

// MARK: Timecode

// Reads RP188 as components and flags. HFRTC (SMPTE ST 12-3) already counts
// 0-59 at 59.94. Other RP188 timecode usually counts 0-29 with
// bmdTimecodeFieldMark on the second frame of each pair (manual 3.31), so the
// frame label becomes frames * 2 + field. Drop-frame stays correct: 29.97 DF
// skips labels 0-1, which map to 0-3, exactly the labels 59.94 DF skips.
//
// Some devices count 0-59 without HFRTC. The two cadences differ frame to
// frame: a pair counter repeats each value once (repeat, +1, repeat, +1), a
// full-rate counter advances by exactly one every frame. The reader switches
// only after kEvidenceSteps consecutive steps of one pattern, so one corrupt
// label can never latch a cadence, and it starts over on signal loss and on
// every input reconfiguration.
//
// While it relearns, labels follow the cadence the session last latched (the
// camera is usually the same one), so a full-rate source is not shown doubled
// for its first frames after every reconfiguration. Before anything latched,
// labels below 30 are read as pairs, the RP188 convention (manual 3.31). That
// default also decides what a static label shows: a camera in standby holds
// one label, which never latches either cadence.
struct TimecodeReader {
  enum class Cadence { unknown, pairs, fullRate };
  static constexpr int kEvidenceSteps = 4;
  bool highFrameRateSupported = true;
  Cadence cadence = Cadence::unknown;
  // The cadence last latched this session; kept across reset().
  Cadence previousCadence = Cadence::unknown;
  int fullRateSteps = 0, pairSteps = 0;
  bool lastWasRepeat = false;
  bool hasLast = false;
  uint32_t lastSeconds = 0;
  uint8_t lastFrames = 0;
  // The previous label: an unchanged label reuses its string (frame thread only).
  uint32_t cachedKey = UINT32_MAX;
  NSString *cachedText = nil;

  void reset() {
    cadence = Cadence::unknown;
    fullRateSteps = 0; pairSteps = 0;
    lastWasRepeat = false; hasLast = false;
  }

  // One RP188 reading at 59.94 without HFRTC.
  void observe(uint8_t hours, uint8_t minutes, uint8_t seconds, uint8_t frames) {
    const uint32_t total = (uint32_t(hours) * 60 + minutes) * 60 + seconds;
    if (hasLast) {
      const bool sameSecond = total == lastSeconds;
      if (sameSecond && frames == lastFrames) {
        // Only a pair counter repeats; two repeats in a row fit neither.
        fullRateSteps = 0;
        pairSteps = lastWasRepeat ? 0 : pairSteps + 1;
        lastWasRepeat = true;
      } else if (sameSecond && frames == lastFrames + 1) {
        // A pair counter never advances twice in a row.
        fullRateSteps += 1;
        pairSteps = lastWasRepeat ? pairSteps + 1 : 0;
        lastWasRepeat = false;
      } else if (total == (lastSeconds + 1) % 86400 && frames <= 4) {
        // A second boundary: fits both. Drop-frame skips labels 00-03 at
        // each minute not divisible by ten (SMPTE ST 12-1), so a full-rate
        // count resumes at 4 and a pair count at 2 (its 00-01 are 00-03).
        lastWasRepeat = false;
      } else {
        fullRateSteps = 0; pairSteps = 0; lastWasRepeat = false;
      }
      if (fullRateSteps >= kEvidenceSteps) cadence = Cadence::fullRate;
      else if (pairSteps >= kEvidenceSteps) cadence = Cadence::pairs;
      if (cadence != Cadence::unknown) previousCadence = cadence;
    }
    hasLast = true; lastSeconds = total; lastFrames = frames;
  }

  NSString *read(IDeckLinkVideoInputFrame *frame, bool highFrameRate, unsigned nominalFPS = 0) {
    if (!frame) return nil;
    ComRef<IDeckLinkTimecode> timecode;
    bool hfr = false;
    if (highFrameRate && highFrameRateSupported &&
        frame->GetTimecode(bmdTimecodeRP188HighFrameRate, timecode.out()) == S_OK && timecode) hfr = true;
    if (!hfr) {
      timecode.reset();
      if (frame->GetTimecode(bmdTimecodeRP188Any, timecode.out()) != S_OK || !timecode) return nil;
    }
    uint8_t hours = 0, minutes = 0, seconds = 0, frames = 0;
    if (timecode->GetComponents(&hours, &minutes, &seconds, &frames) != S_OK) {
      CFStringRef raw = nullptr;
      if (timecode->GetString(&raw) == S_OK && raw && CFStringGetLength(raw) > 0) return CFBridgingRelease(raw);
      if (raw) CFRelease(raw);
      return nil;
    }
    BMDTimecodeFlags flags = timecode->GetFlags();
    unsigned frameLabel = frames;
    if (highFrameRate && !hfr && nominalFPS <= 60) {
      observe(hours, minutes, seconds, frames);
      // Before the cadence is known a label above 29 cannot be a pair
      // counter's; show it as is, without deciding anything. Below 30, the
      // previously latched cadence (pairs if none) decides.
      const bool pairs = cadence == Cadence::pairs ||
        (cadence == Cadence::unknown && frames < 30 && previousCadence != Cadence::fullRate);
      if (pairs) frameLabel = frames * 2u + ((flags & bmdTimecodeFieldMark) ? 1u : 0u);
    }
    const unsigned labels = nominalFPS ? nominalFPS : highFrameRate ? 60 : 30;
    if (hours > 23 || minutes > 59 || seconds > 59 || frameLabel >= labels) return nil;
    const bool dropFrame = flags & bmdTimecodeIsDropFrame;
    const uint32_t key = (uint32_t(hours) << 20) | (uint32_t(minutes) << 14) | (uint32_t(seconds) << 8) |
      (frameLabel << 1) | (dropFrame ? 1u : 0u);
    if (key != cachedKey || !cachedText) {
      cachedText = [NSString stringWithFormat:@"%02u:%02u:%02u%@%02u", hours, minutes, seconds,
        dropFrame ? @";" : @":", frameLabel];
      cachedKey = key;
    }
    return cachedText;
  }
};

struct DetectedInput {
  BMDPixelFormat pixel = bmdFormatUnspecified;
  std::optional<NativeFrameContract> contract;
  BMDDisplayMode mode = bmdModeUnknown;
  CMTime duration = kCMTimeInvalid;
  BMDDetectedVideoInputFormatFlags flags = 0;
  BMDColorspace colorspace = 0;
  int64_t eotf = kEOTFUnknown;
  NSString *description = @"Unknown HDMI input";
  bool supported = false;
  uint64_t sequence = 0;
  NSString *fullDescription() const {
    return [NSString stringWithFormat:@"%@ · %@", description, colorimetryText(colorspace, eotf)];
  }
};

static uint64_t detectionSignature(BMDDisplayMode mode, BMDDetectedVideoInputFormatFlags flags) {
  return (uint64_t(mode) << 32) | flags;
}

static DetectedInput describeInput(IDeckLinkDisplayMode *mode, BMDDetectedVideoInputFormatFlags flags) {
  DetectedInput result; result.flags = flags;
  if (!mode) return result;
  result.mode = mode->GetDisplayMode();
  result.colorspace = colorspaceFromModeFlags(mode->GetFlags());
  BMDTimeValue duration = 0; BMDTimeScale scale = 0;
  if (mode->GetFrameRate(&duration, &scale) == S_OK && duration > 0 && scale > 0 && scale <= INT32_MAX)
    result.duration = CMTimeMake(duration, (int32_t)scale);
  NSString *color = (flags & bmdDetectedVideoInputRGB444) ? @"RGB 4:4:4" :
    ((flags & bmdDetectedVideoInputYCbCr422) ? @"YUV 4:2:2" : @"unknown color format");
  NSString *depth = (flags & bmdDetectedVideoInput10BitDepth) ? @"10-bit" :
    ((flags & bmdDetectedVideoInput12BitDepth) ? @"12-bit" : ((flags & bmdDetectedVideoInput8BitDepth) ? @"8-bit" : @"unreported bit depth"));
  double fps = CMTIME_IS_NUMERIC(result.duration) ? 1.0 / CMTimeGetSeconds(result.duration) : 0;
  NSString *cadence = fps > 0 ? [NSString stringWithFormat:@"%.2f fps", fps] : @"unknown frame rate";
  NSString *scan = mode->GetFieldDominance() == bmdProgressiveFrame ? @"progressive" :
    mode->GetFieldDominance() == bmdProgressiveSegmentedFrame ? @"PsF" : @"interlaced or unknown scan";
  result.description = [NSString stringWithFormat:@"%ld × %ld · %@ · %@ · %@ · %@",
    mode->GetWidth(), mode->GetHeight(), scan, cadence, color, depth];
  auto contract = nativeFrameContract(mode);
  const bool yuv = flags & bmdDetectedVideoInputYCbCr422;
  const bool rgb = flags & bmdDetectedVideoInputRGB444;
  const unsigned depths = unsigned(bool(flags & bmdDetectedVideoInput8BitDepth)) +
    unsigned(bool(flags & bmdDetectedVideoInput10BitDepth)) + unsigned(bool(flags & bmdDetectedVideoInput12BitDepth));
  if (yuv != rgb && depths == 1) {
    if (yuv) result.pixel = flags & bmdDetectedVideoInput8BitDepth ? bmdFormat8BitYUV : bmdFormat10BitYUV;
    else if (flags & bmdDetectedVideoInput10BitDepth) result.pixel = bmdFormat10BitRGB;
    else if (flags & bmdDetectedVideoInput12BitDepth) result.pixel = bmdFormat12BitRGBLE;
  }
  if (contract) contract->pixel = result.pixel;
  result.contract = contract;
  result.supported = contract && mode->GetWidth() == contract->width && mode->GetHeight() == contract->height &&
    mode->GetFieldDominance() == bmdProgressiveFrame &&
    CMTIME_IS_NUMERIC(result.duration) &&
    // Treat an omitted depth flag as unsupported.  The capture contract needs
    // a provably 10/12-bit source; accepting "unreported bit depth" here
    // would let an 8-bit/unknown signal through the auto reconfiguration path
    // and silently promote it to a 10-bit output.
    result.pixel != bmdFormatUnspecified && !(flags & bmdDetectedVideoInputDualStream3D);
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

// Audio packets from EnableAudioInput(48 kHz, 32-bit, negotiated channels) are
// interleaved little-endian signed PCM. Capture always requests 32-bit integer
// samples, so the meters read the full source precision and starting a
// recording never needs an audio-format restart. DeckLink does not expose a
// byte count on IDeckLinkAudioInputPacket, so the count is derived from the
// sample-frame count and the configured stream format. Keep this helper
// bounded: a bad driver packet must never make the callback walk an
// untrusted allocation.
static void reportMedia(NSString *timecodeString, IDeckLinkAudioInputPacket *audio,
  UltracamMediaStatsHandler handler, NSUInteger channels = 2) {
  if (!handler) return;
  CMTime packetTime = kCMTimeInvalid;
  NSUInteger sampleFrames = 0;
  NSUInteger bytes = 0;
  float leftPeak = 0.0f, rightPeak = 0.0f;
  float leftRMS = 0.0f, rightRMS = 0.0f;
  BOOL present = NO;
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
      const NSUInteger expectedBytes = frameCount * channels * sizeof(int32_t);
      if (audio->GetBytes(&raw) == S_OK && raw && expectedBytes > 0) {
        const int32_t *samples = static_cast<const int32_t *>(raw);
        double leftSum = 0.0, rightSum = 0.0;
        double leftMaximum = 0.0, rightMaximum = 0.0;
        for (NSUInteger index = 0; index < frameCount; ++index) {
          const double left = static_cast<double>(samples[index * channels]) / 2147483648.0;
          const double right = static_cast<double>(samples[index * channels + 1]) / 2147483648.0;
          leftMaximum = std::max(leftMaximum, std::abs(left));
          rightMaximum = std::max(rightMaximum, std::abs(right));
          leftSum += left * left;
          rightSum += right * right;
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
  handler(timecodeString, packetTime, sampleFrames, present ? channels : 0, leftPeak, rightPeak,
    leftRMS, rightRMS, bytes, present);
}

// Raw audio packets (always bmdAudioSampleType32bitInteger) are copied before
// the callback returns. Keep the same conservative frame bound as the stats path
// so malformed driver metadata cannot produce an oversized allocation.
static void reportRawAudio(IDeckLinkAudioInputPacket *audio, UltracamRawAudioHandler handler, NSUInteger channels = 2) {
  if (!handler) return;
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

#include "OwnedCaptureAllocator.inc"

class CaptureCallback final : public IDeckLinkInputCallback {
 public:
  std::atomic<ULONG> references{1};
  std::atomic<bool> accepting{true};
  std::atomic<int> signalState{-1};
  std::atomic<bool> fatalReported{false};
  std::atomic<bool> framesEnabled{true};
  std::atomic<BMDDisplayMode> requestedMode;
  // The mode the streams last started in cleanly; bmdModeUnknown while a
  // reconfiguration is incomplete. The pixel format is always 10-bit YUV, so
  // a detection in this mode needs no restart.
  std::atomic<BMDDisplayMode> streamingMode;
  BMDVideoConnection connection = bmdVideoConnectionHDMI;
  std::shared_ptr<const NativeFrameContract> activeContract;
  void setActiveContract(const NativeFrameContract &contract) {
    std::atomic_store(&activeContract, std::make_shared<const NativeFrameContract>(contract));
  }
  std::atomic<bool> audioEnabled{false};
  std::atomic<uint64_t> lastDetection{UINT64_MAX};
  // Detected colorimetry (display-mode flags or IDeckLinkStatus), the fallback
  // when a frame carries no metadata of its own.
  std::atomic<uint32_t> signalColorspace{0};
  std::atomic<int64_t> signalEOTF{kEOTFUnknown};
  // Colorimetry the frames themselves last reported through metadata.
  std::atomic<uint32_t> observedColorspace{0};
  std::atomic<int64_t> observedEOTF{kEOTFUnknown};
  // Set on the control queue after a driver restart: stream time starts over.
  std::atomic<bool> resetStreamClock{false};
  // Set with resetStreamClock: the timecode cadence is learned again.
  std::atomic<bool> resetTimecodeCadence{false};
  // Valid frames discarded while frames are gated for a supported format
  // change, plus frames a reconfiguration flushed. The control queue settles
  // them when frames are enabled again (see settleGatedFrames).
  std::atomic<uint64_t> gatedFrames{0};
  // Whether frames gated now are lost frames of a supported signal (not the
  // frames of a source Ultracam cannot capture, which is reported instead).
  std::atomic<bool> gateCountsLosses{false};
  // Control queue only: the streams restarted since frames were last enabled.
  bool restartedWhileGated = false;
  // Device capabilities; written before StartStreams, then read-only.
  bool supportsHDRMetadata = false;
  bool supportsColorspaceMetadata = false;
  std::shared_ptr<SessionStats> stats = std::make_shared<SessionStats>();
  CMTimeScale timeScale;
  NSUInteger audioChannels = 2;
  void (^audioFormatHandler)(NSInteger) = nil;
  void (^cpuMemoryFrameHandler)(UCDeckLinkOwnedMemoryFrame *, CMTime, CMTime) = nil;
  ComRef<IDeckLinkVideoBufferAllocatorProvider> allocatorProvider;
  void (^frameHandler)(CVPixelBufferRef, CMTime, BOOL);
  UltracamMediaStatsHandler mediaHandler;
  UltracamRawAudioHandler rawAudioHandler;
  void (^groupBegin)(void) = nil;
  void (^groupEnd)(void) = nil;
  void (^timecodeHandler)(NSString *) = nil;
  void (^eventHandler)(NSString *);
  void (^autoFrameHandler)(CVPixelBufferRef, CMTime, CMTime, BOOL) = nil;
  // keepFrames: the detection is supported and in the running mode, so frames
  // stay enabled and the input is not restarted.
  void (^modeHandler)(DetectedInput, bool keepFrames) = nil;
  // Colorimetry-only change: same mode and format, so the input keeps running.
  void (^colorimetryHandler)(void) = nil;
  TimecodeReader timecodes;  // Frame thread only after start.
  CaptureCallback(BMDDisplayMode mode, CMTimeScale scale,
    void (^frames)(CVPixelBufferRef, CMTime, BOOL), void (^events)(NSString *),
    UltracamMediaStatsHandler media = nil, UltracamRawAudioHandler rawAudio = nil)
    : requestedMode(mode), streamingMode(mode), timeScale(scale), frameHandler([frames copy]), mediaHandler([media copy]),
      rawAudioHandler([rawAudio copy]), eventHandler([events copy]) {
    if (auto contract = nativeFrameContract(mode)) setActiveContract(*contract);
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
  HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents events,
    IDeckLinkDisplayMode *mode, BMDDetectedVideoInputFormatFlags flags) override {
    @autoreleasepool {
      if (!accepting) return S_OK;
      BMDColorspace colorspace = mode ? colorspaceFromModeFlags(mode->GetFlags()) : 0;
      if (modeHandler) {
        DetectedInput detection = describeInput(mode, flags);
        uint64_t signature = detectionSignature(detection.mode, flags);
        if (lastDetection.exchange(signature) != signature) {
          // Only the format flags moved (for example 10-bit to 12-bit) and the
          // running mode still captures it as 10-bit YUV: no gap, no restart.
          const auto active = std::atomic_load(&activeContract);
          const bool keepFrames = detection.supported && active && detection.pixel == active->pixel && detection.mode == streamingMode.load() && framesEnabled.load();
          if (!keepFrames) {
            gateCountsLosses = detection.supported;
            framesEnabled = false;
          }
          if (colorspace) signalColorspace = colorspace;
          modeHandler(detection, keepFrames);
        } else if ((colorspace && signalColorspace.exchange(colorspace) != colorspace) ||
            (events & bmdVideoInputColorspaceChanged)) {
          // The mode|flags signature is unchanged, so only colorimetry moved
          // (colorspace or HDR transfer). Report it without a driver restart.
          if (colorimetryHandler) colorimetryHandler();
        }
        return S_OK;
      }
      if (colorspace) signalColorspace = colorspace;
      if (!mode || mode->GetDisplayMode() != requestedMode.load()) {
        reportFatal(@"Input changed from the selected HDMI 10-bit YUV mode. Check the FX3 HDMI output and selected frame rate, then restart.");
      }
    }
    return S_OK;
  }
  HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame *frame, IDeckLinkAudioInputPacket *audioPacket) override {
    @autoreleasepool {
      if (!accepting) return S_OK;
      if (groupBegin) groupBegin();
      struct GroupEndScope {
        void (^handler)(void);
        ~GroupEndScope() { if (handler) handler(); }
      } groupEndScope{groupEnd};
      BMDTimeValue timestamp = 0, duration = 0;
      HRESULT timeStatus = frame ? frame->GetStreamTime(&timestamp, &duration, timeScale) : E_FAIL;
      const auto active = std::atomic_load(&activeContract);
      const bool timeValid = timeStatus == S_OK && timestamp >= 0 && duration > 0 && active &&
        CMTimeCompare(CMTimeMake(duration, timeScale), active->duration) == 0;
      // Above 30 fps: 1001/60000 stream durations, or the opened mode before time is valid.
      const bool highFrameRate = timeValid ? duration * 30 < timeScale :
        requestedMode.load() == bmdMode4K2160p5994;
      if (resetTimecodeCadence.load(std::memory_order_relaxed) && resetTimecodeCadence.exchange(false)) timecodes.reset();
      // Read before the frame is delivered: a signal loss there starts the cadence over.
      const unsigned nominalFPS = active ? unsigned(std::ceil(1.0 / CMTimeGetSeconds(active->duration))) : 0;
      NSString *timecode = (mediaHandler || timecodeHandler) ? timecodes.read(frame, highFrameRate, nominalFPS) : nil;
      if (timecodeHandler) timecodeHandler(timecode);
      // The callback's video frame is wrapped and handed off first, so the
      // frame consumers (recording admission, the capture queue) never wait
      // behind the audio work. Then the callback's audio, whatever path the
      // frame took, or with no frame at all: Desktop Video can deliver an
      // audio packet while the video input is absent (for example during a
      // source reconnect), and the media path owns its own clock, so it never
      // acquires an artificial audio hole for want of a video object.
      if (frame) deliverVideo(frame, timeValid, timestamp, duration);
      if (mediaHandler) reportMedia(timecode, audioPacket, mediaHandler, audioChannels);
      reportRawAudio(audioPacket, rawAudioHandler, audioChannels);
    }
    return S_OK;
  }

  // Frame thread, from VideoInputFrameArrived only: validates the callback's
  // frame, wraps its native buffer and hands it to the frame handler (or
  // counts it as gated). Input faults are reported here; the caller reports
  // the callback's audio afterwards on every path.
  void deliverVideo(IDeckLinkVideoInputFrame *frame, bool timeValid, BMDTimeValue timestamp, BMDTimeValue duration) {
    bool valid = !(frame->GetFlags() & bmdFrameHasNoInputSource);
    stats->signalPresent = valid ? 1 : 0;
    int prior = signalState.exchange(valid ? 1 : 0);
    trackStreamTime(timeValid, timestamp, duration, valid && prior == 0);
    // Embedded audio has its own packet clock: the caller reports this
    // callback's audio whatever happens to the frame here, so signal loss and
    // format reconfiguration never put an artificial hole in a recording.
    if (!valid) {
      if (prior != 0) timecodes.reset();
      if (prior != 0) eventHandler(modeHandler ? @"No HDMI video signal — waiting for the camera to reconnect." :
        @"No video signal. Check the FX3 HDMI output and selected frame rate.");
      return;
    }
    if (!framesEnabled) { noteGatedFrame(); return; }
    const auto contract = std::atomic_load(&activeContract);
    if (!contract || frame->GetWidth() != contract->width || frame->GetHeight() != contract->height || frame->GetPixelFormat() != contract->pixel) {
      reportFatal([NSString stringWithFormat:@"Unsupported capture frame: %ld × %ld, pixel format 0x%08x. Requires dimensions and cadence matching the active HDMI mode in 10-bit YUV 4:2:2.",
        frame->GetWidth(), frame->GetHeight(), (unsigned)frame->GetPixelFormat()]); return;
    }
    if (!timeValid) {
      reportFatal(@"UltraStudio supplied an invalid frame timestamp."); return;
    }
    // SDK 16 reports the buffer length (IDeckLinkVideoBuffer::GetSize, manual
    // 2.5.53.2). A short buffer would let GPU readers run past the image.
    {
      ComRef<IDeckLinkVideoBuffer> videoBuffer;
      uint64_t size = 0;
      const long rowBytes = frame->GetRowBytes();
      const bool sizeKnown = frame->QueryInterface(IID_IDeckLinkVideoBuffer, reinterpret_cast<void **>(videoBuffer.out())) == S_OK &&
          videoBuffer && videoBuffer->GetSize(&size) == S_OK;
      if (rowBytes <= 0 || !validPackedExtent(contract->width, contract->height, uint64_t(rowBytes), size, sizeKnown, contract->pixel)) {
        reportFatal(sizeKnown ? [NSString stringWithFormat:@"Desktop Video supplied a %llu-byte frame buffer with an invalid packed v210 stride or allocation extent.", (unsigned long long)size] :
          @"Desktop Video supplied an invalid packed v210 row stride or allocation extent."); return;
      }
    }
    if (contract->pixel == bmdFormat10BitRGB || contract->pixel == bmdFormat12BitRGBLE) {
      ComRef<IDeckLinkVideoBuffer> storage;
      if (!cpuMemoryFrameHandler || frame->QueryInterface(IID_IDeckLinkVideoBuffer, reinterpret_cast<void **>(storage.out())) != S_OK) {
        reportFatal(@"The RGB input requires the owned GPU memory capture path."); return;
      }
      UCDeckLinkOwnedMemoryFrame *owned = [[UCDeckLinkOwnedMemoryFrame alloc] initWithFrame:frame buffer:storage.value];
      if (!owned || !validPackedExtent(contract->width, contract->height, frame->GetRowBytes(), owned.allocationLength, true, contract->pixel)) {
        reportFatal(@"The RGB input did not use the plugin-owned SDK allocation."); return;
      }
      const auto colour = resolveColorimetry(frame);
      [owned setColorspace:colour.colorspace eotf:colour.eotf];
      [owned setCaptureHostTimeSeconds:captureHostTime(frame)];
      if (accepting && framesEnabled) cpuMemoryFrameHandler(owned, CMTimeMake(timestamp, timeScale), CMTimeMake(duration, timeScale));
      return;
    }
    CVPixelBufferRef buffer = nullptr;
    ComRef<IDeckLinkMacVideoBuffer> macBuffer;
    if (frame->QueryInterface(IID_IDeckLinkMacVideoBuffer,
      reinterpret_cast<void **>(macBuffer.out())) != S_OK ||
      macBuffer->CreateCVPixelBufferRef(reinterpret_cast<void **>(&buffer)) != S_OK || !buffer) {
      reportFatal(@"Desktop Video could not expose its native 10-bit pixel buffer. Update the Desktop Video driver."); return;
    }
    // The SDK's buffer is IOSurface-backed and holds the frame until its final release.
    // Keep the producer contract explicit even if future SDK wrappers use a
    // different CoreVideo format. The controller's untouched sink is v210.
    // Every consumer reads this IOSurface directly; there is no copy path.
    if (!CVPixelBufferGetIOSurface(buffer)) {
      CVPixelBufferRelease(buffer);
      reportFatal(@"Desktop Video supplied a frame without an IOSurface. Update Desktop Video to 16 or later."); return;
    }
    if (CVPixelBufferGetWidth(buffer) != uint64_t(contract->width) || CVPixelBufferGetHeight(buffer) != uint64_t(contract->height) ||
        CVPixelBufferGetPixelFormatType(buffer) != contract->pixel || CVPixelBufferIsPlanar(buffer) ||
        CVPixelBufferGetPlaneCount(buffer) != 0 ||
        !validPackedExtent(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), CVPixelBufferGetBytesPerRow(buffer),
          CVPixelBufferGetDataSize(buffer), CVPixelBufferGetDataSize(buffer) != 0, contract->pixel)) {
      CVPixelBufferRelease(buffer);
      reportFatal(@"Desktop Video supplied a pixel format incompatible with the native v210 feed."); return;
    }
    attachColorimetry(buffer, frame);
    attachHostTime(buffer, frame);
    // Swift retaining the buffer safely extends the native frame lifetime.
    if (accepting && framesEnabled) {
      if (autoFrameHandler) autoFrameHandler(buffer, CMTimeMake(timestamp, timeScale), CMTimeMake(duration, timeScale), YES);
      else frameHandler(buffer, CMTimeMake(timestamp, timeScale), YES);
    } else if (accepting) {
      noteGatedFrame();
    }
    CVPixelBufferRelease(buffer);
  }

  // Control queue, when frames are enabled again. Gated frames are device
  // drops only if the streams restarted meanwhile: the stream clock started
  // over, so no timestamp gap downstream can show them. Without a restart the
  // next delivered frame's stream time shows the gap, and consumers (capture
  // statistics, the recorder's skipped-frame count) count it there.
  void settleGatedFrames() {
    const uint64_t gated = gatedFrames.exchange(0);
    if (restartedWhileGated && gated) stats->deviceDrops.fetch_add(gated, std::memory_order_relaxed);
    restartedWhileGated = false;
  }

 private:
  BMDTimeValue lastStreamTime = -1;  // Frame thread only.

  // A valid frame discarded because frames are gated for a format change.
  void noteGatedFrame() {
    if (gateCountsLosses.load(std::memory_order_relaxed)) gatedFrames.fetch_add(1, std::memory_order_relaxed);
  }
  bool loggedSDKColorimetry = false;

  // Device-side drops: a stream-time step of two or more frame durations
  // means the device never delivered the frames in between (the SDK's
  // InputLoopThrough sample counts drops the same way). Signal loss and driver
  // restarts begin a new run. Steps beyond the elapsed-time bound are clock
  // discontinuities; a frame-count cutoff would change meaning with cadence.
  void trackStreamTime(bool valid, BMDTimeValue timestamp, BMDTimeValue duration, bool signalReturned) {
    if (signalReturned || (resetStreamClock.load(std::memory_order_relaxed) && resetStreamClock.exchange(false)))
      lastStreamTime = -1;
    if (!valid || timestamp < 0 || duration <= 0 || timeScale <= 0) return;
    if (lastStreamTime >= 0 && timestamp >= lastStreamTime) {
      // Both timestamps are nonnegative, so subtraction cannot overflow.
      // Divide before comparing; adding 2*duration to last time can overflow.
      const BMDTimeValue gap = timestamp - lastStreamTime;
      if (CMTimeCompare(CMTimeMake(gap, timeScale), CMTimeMake(UCDeckLinkMaximumSourceGapSeconds, 1)) <= 0) {
        const BMDTimeValue intervals = gap / duration;
        if (intervals >= 2) stats->deviceDrops.fetch_add(uint64_t(intervals - 1), std::memory_order_relaxed);
      } else { timecodes.reset(); }
    }
    lastStreamTime = timestamp;
  }

  // HDR and colorspace metadata from the frame (manual 2.4.12.1), gated on the
  // device attributes, then the detected signal.
  struct ResolvedColorimetry { BMDColorspace colorspace; int64_t eotf; bool colorspaceFromFrame, eotfFromFrame; };
  ResolvedColorimetry resolveColorimetry(IDeckLinkVideoInputFrame *frame) {
    BMDColorspace colorspace = 0;
    int64_t eotf = kEOTFUnknown;
    bool colorspaceFromFrame = false, eotfFromFrame = false;
    const BMDFrameFlags flags = frame->GetFlags();
    if (supportsColorspaceMetadata || (supportsHDRMetadata && (flags & bmdFrameContainsHDRMetadata))) {
      ComRef<IDeckLinkVideoFrameMetadataExtensions> metadata;
      if (frame->QueryInterface(IID_IDeckLinkVideoFrameMetadataExtensions,
          reinterpret_cast<void **>(metadata.out())) == S_OK && metadata) {
        int64_t value = 0;
        if (supportsColorspaceMetadata && metadata->GetInt(bmdDeckLinkFrameMetadataColorspace, &value) == S_OK &&
            colorspaceName(BMDColorspace(value))) {
          colorspace = BMDColorspace(value); colorspaceFromFrame = true;
        }
        if (supportsHDRMetadata && (flags & bmdFrameContainsHDRMetadata) &&
            metadata->GetInt(bmdDeckLinkFrameMetadataHDRElectroOpticalTransferFunc, &value) == S_OK &&
            value >= 0 && value <= 7) {
          eotf = value; eotfFromFrame = true;
        }
      }
    }
    const uint32_t seenColorspace = colorspaceFromFrame ? colorspace : 0;
    const int64_t seenEOTF = eotfFromFrame ? eotf : kEOTFUnknown;
    const bool colorspaceChanged = observedColorspace.exchange(seenColorspace) != seenColorspace;
    const bool eotfChanged = observedEOTF.exchange(seenEOTF) != seenEOTF;
    if ((colorspaceChanged || eotfChanged) && colorimetryHandler) colorimetryHandler();
    if (!colorspaceFromFrame) colorspace = BMDColorspace(signalColorspace.load());
    if (!eotfFromFrame) eotf = signalEOTF.load();
    // A device that carries HDR metadata marks every HDR frame, so without the
    // flag or a detected dynamic range the frame is SDR. That inference fills
    // empty attachments only (eotfFromFrame stays false).
    if (eotf == kEOTFUnknown && supportsHDRMetadata && !(flags & bmdFrameContainsHDRMetadata)) eotf = kEOTFSDR;
    return {colorspace, eotf, colorspaceFromFrame, eotfFromFrame};
  }
  void attachColorimetry(CVPixelBufferRef buffer, IDeckLinkVideoInputFrame *frame) {
    const auto resolved = resolveColorimetry(frame);
    const auto colorspace = resolved.colorspace;
    const auto eotf = resolved.eotf;
    if (!loggedSDKColorimetry) {
      loggedSDKColorimetry = true;
      CFTypeRef existing = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nullptr);
      os_log(backendLog(), "First frame: the SDK %{public}s a transfer-function attachment; signal is %{public}@",
        existing ? "set" : "did not set", colorimetryText(colorspace, eotf));
      if (existing) CFRelease(existing);
    }
    applyColorimetry(buffer, colorspace, resolved.colorspaceFromFrame, eotf, resolved.eotfFromFrame);
  }

  // The frame's hardware reference timestamp marks when the device finished
  // receiving it (InputLoopThrough subtracts the duration for the start).
  NSNumber *captureHostTime(IDeckLinkVideoInputFrame *frame) {
    if (!stats->hostOffsetValid.load(std::memory_order_acquire)) return nil;
    BMDTimeValue referenceTime = 0, referenceDuration = 0;
    if (frame->GetHardwareReferenceTimestamp(kReferenceTimeScale, &referenceTime, &referenceDuration) != S_OK ||
        referenceTime <= 0) return nil;
    Float64 host = (Float64(referenceTime) + Float64(stats->hostOffsetMicros.load(std::memory_order_relaxed))) /
      Float64(kReferenceTimeScale);
    return std::isfinite(host) && host > 0 ? @(host) : nil;
  }
  void attachHostTime(CVPixelBufferRef buffer, IDeckLinkVideoInputFrame *frame) {
    NSNumber *number = captureHostTime(frame);
    if (!number) return;
    CVBufferSetAttachment(buffer, (__bridge CFStringRef)UltracamCaptureHostTimeAttachmentKey, (__bridge CFTypeRef)number,
      kCVAttachmentMode_ShouldPropagate);
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
  const auto active = std::atomic_load(&callback->activeContract);
  const auto pixel = active ? active->pixel : bmdFormat10BitYUV;
  if (pixel == bmdFormat10BitRGB || pixel == bmdFormat12BitRGBLE) callback->allocatorProvider.value = new OwnedCaptureAllocatorProvider();
  HRESULT status = callback->allocatorProvider ? input->EnableVideoInputWithAllocatorProvider(mode, pixel, flags, callback->allocatorProvider.value) :
    input->EnableVideoInput(mode, pixel, flags);
  bool videoEnabled = status == S_OK;
  if (status == S_OK) status = input->SetCallback(callback);
  bool callbackSet = status == S_OK;
  if (status == S_OK) {
    // Embedded audio is optional unless raw audio was requested. Always
    // 32-bit integer PCM: meters read the full source precision, and a
    // recording that later wants raw samples never forces a restart.
    HRESULT audioStatus = input->EnableAudioInput(bmdAudioSampleRate48kHz, bmdAudioSampleType32bitInteger, uint32_t(callback->audioChannels));
    if (audioStatus == S_OK) callback->audioEnabled = true;
    else if (rawAudio) status = audioStatus;
    if (callback->audioFormatHandler) callback->audioFormatHandler(audioStatus == S_OK ? callback->audioChannels : 0);
    callback->stats->capturedAudioChannels = audioStatus == S_OK ? uint32_t(callback->audioChannels) : 0;
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
// Only a real mode change gets here: the pixel format is always 10-bit YUV.
static HRESULT reconfigureInput(IDeckLinkInput *input, CaptureCallback *callback, const DetectedInput &mode) {
  callback->gateCountsLosses = true;
  callback->framesEnabled = false;
  // Until StartStreams succeeds the streams are in no known mode.
  callback->streamingMode = bmdModeUnknown;
  if (!callback->accepting) return E_FAIL;
  HRESULT status = input->PauseStreams();
  if (!callback->accepting) return E_FAIL;
  // Frames still queued in the driver are about to be flushed: count them.
  uint32_t queued = 0;
  if (status == S_OK && input->GetAvailableVideoFrameCount(&queued) != S_OK) queued = 0;
  if (status == S_OK) {
    callback->allocatorProvider.reset();
    if (mode.pixel == bmdFormat10BitRGB || mode.pixel == bmdFormat12BitRGBLE) callback->allocatorProvider.value = new OwnedCaptureAllocatorProvider();
    status = callback->allocatorProvider ? input->EnableVideoInputWithAllocatorProvider(mode.mode, mode.pixel, bmdVideoInputEnableFormatDetection, callback->allocatorProvider.value) :
      input->EnableVideoInput(mode.mode, mode.pixel, bmdVideoInputEnableFormatDetection);
  }
  if (!callback->accepting) return E_FAIL;
  if (status == S_OK) status = input->FlushStreams();
  if (!callback->accepting) return E_FAIL;
  if (status == S_OK) {
    callback->gatedFrames.fetch_add(queued, std::memory_order_relaxed);
    callback->restartedWhileGated = true;
    callback->requestedMode = mode.mode;
    if (mode.contract) callback->setActiveContract(*mode.contract);
    // Stream time restarts with the streams; the next frame begins a new run.
    callback->resetStreamClock = true;
    callback->resetTimecodeCadence = true;
    status = input->StartStreams();
    if (status == S_OK) callback->streamingMode = mode.mode;
  }
  return status;
}

// MARK: Driver version

// BMDDeckLinkAPIVersion is major << 24 | minor << 16 | sub << 8 | extra
// (manual 3.16). SDK 16 interface IDs need a 16.0 or later driver.
static constexpr int64_t kMinimumDriverVersion = 0x10000000;

static UltracamDriverInfo *driverInfoFrom(IDeckLinkAPIInformation *information) {
  UltracamDriverInfo *info = [UltracamDriverInfo new];
  if (!information) {
    info.version = @"Not installed";
    info.message = @"Blackmagic Desktop Video is not installed. Install Desktop Video 16 or later, then restart the Mac.";
    return info;
  }
  info.installed = YES;
  CFStringRef text = nullptr;
  if (information->GetString(BMDDeckLinkAPIVersion, &text) == S_OK && text && CFStringGetLength(text) > 0)
    info.version = CFBridgingRelease(text);
  else if (text) CFRelease(text);
  int64_t value = 0;
  if (information->GetInt(BMDDeckLinkAPIVersion, &value) == S_OK) {
    info.versionValue = value;
    if (!info.version) info.version = [NSString stringWithFormat:@"%lld.%lld.%lld",
      (long long)((value >> 24) & 0xff), (long long)((value >> 16) & 0xff), (long long)((value >> 8) & 0xff)];
  }
  if (!info.version) info.version = @"unknown version";
  info.supported = info.versionValue >= kMinimumDriverVersion;
  if (!info.supported)
    info.message = [NSString stringWithFormat:@"Desktop Video %@ is too old for this app. "
      "Update Desktop Video to 16 or later, then restart the Mac.", info.version];
  return info;
}

static UltracamDriverInfo *installedDriverInfo() {
  static UltracamDriverInfo *info;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ComRef<IDeckLinkAPIInformation> information;
    information.value = CreateDeckLinkAPIInformationInstance();
    info = driverInfoFrom(information.value);
    os_log(backendLog(), "Desktop Video %{public}@ (0x%08llx), %{public}s", info.version,
      (unsigned long long)info.versionValue, info.supported ? "supported" : "older than 16.0");
  });
  return info;
}

// MARK: Device discovery

struct DeviceCapabilities {
  BMDVideoConnection connections = bmdVideoConnectionHDMI;
  bool formatDetection = false;
  bool hdrMetadata = false;
  bool colorspaceMetadata = false;
  bool hdmiTimecode = false;
  bool highFrameRateTimecode = false;
  int64_t maximumHDMIAudioChannels = 0;
};

static DeviceCapabilities readCapabilities(IDeckLink *device) {
  DeviceCapabilities result;
  ComRef<IDeckLinkProfileAttributes> attributes;
  if (device->QueryInterface(IID_IDeckLinkProfileAttributes, reinterpret_cast<void **>(attributes.out())) != S_OK ||
      !attributes) return result;
  auto flag = [&attributes](BMDDeckLinkAttributeID key) {
    bool value = false;
    return attributes->GetFlag(key, &value) == S_OK && value;
  };
  result.formatDetection = flag(BMDDeckLinkSupportsInputFormatDetection);
  result.hdrMetadata = flag(BMDDeckLinkSupportsHDRMetadata);
  result.colorspaceMetadata = flag(BMDDeckLinkSupportsColorspaceMetadata);
  result.hdmiTimecode = flag(BMDDeckLinkSupportsHDMITimecode);
  result.highFrameRateTimecode = flag(BMDDeckLinkSupportsHighFrameRateTimecode);
  int64_t connections = 0;
  if (attributes->GetInt(BMDDeckLinkVideoInputConnections, &connections) == S_OK)
    result.connections = BMDVideoConnection(connections);
  int64_t channels = 0;
  if (attributes->GetInt(BMDDeckLinkMaximumHDMIAudioChannels, &channels) == S_OK && channels > 0)
    result.maximumHDMIAudioChannels = channels;
  return result;
}

class DeviceRegistry;

// Arrival and removal arrive on an API-private thread (manual 2.4.4). They
// only take a reference and hop to the registry's serial queue.
class DiscoveryCallback final : public IDeckLinkDeviceNotificationCallback {
 public:
  explicit DiscoveryCallback(DeviceRegistry *registry) : owner(registry) {}
  HRESULT QueryInterface(REFIID iid, LPVOID *object) override {
    if (!object) return E_INVALIDARG;
    *object = nullptr;
    if (sameIID(iid, CFUUIDGetUUIDBytes(IUnknownUUID)) || sameIID(iid, IID_IDeckLinkDeviceNotificationCallback)) {
      *object = static_cast<IDeckLinkDeviceNotificationCallback *>(this); AddRef(); return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG remaining = --references; if (!remaining) delete this; return remaining; }
  HRESULT DeckLinkDeviceArrived(IDeckLink *device) override;
  HRESULT DeckLinkDeviceRemoved(IDeckLink *device) override;
 private:
  std::atomic<ULONG> references{1};
  DeviceRegistry *owner;
};

// Process-wide: every per-feed UCDeckLinkBackend shares one discovery. Devices
// are held by IDeckLink reference and matched on removal by pointer, never by
// querying the departing device.
class DeviceRegistry {
 public:
  explicit DeviceRegistry(dispatch_queue_t observers) : observerQueue(observers) {
    queue = dispatch_queue_create("org.ultracam.decklink.discovery", DISPATCH_QUEUE_SERIAL);
    observerBlocks = [NSMutableDictionary dictionary];
  }
  ~DeviceRegistry() {
    if (discovery) discovery->UninstallDeviceNotifications();
    drain();
    if (discovery) discovery->Release();
    if (callback) callback->Release();
    for (auto &entry : entries) {
      if (entry.edid) entry.edid->Release();
      entry.device->Release();
    }
    for (auto &session : sessions) session.callback->Release();
  }
  static DeviceRegistry &shared() {
    // Intentionally immortal: driver threads may call it until process exit.
    static DeviceRegistry *registry = new DeviceRegistry(dispatch_get_main_queue());
    return *registry;
  }

  void startDiscovery() {
#if defined(ULTRACAM_BACKEND_TESTING)
    // Tests drive arrival and removal directly and never install real
    // notifications: the driver would report the real UltraStudio.
    return;
#else
    std::call_once(discoveryOnce, [this] {
      if (!installedDriverInfo().supported) return;
      IDeckLinkDiscovery *created = CreateDeckLinkDiscoveryInstance();
      if (!created) return;
      auto notifications = new DiscoveryCallback(this);
      // Arrival also fires for devices already connected (manual 2.4.4).
      HRESULT status = created->InstallDeviceNotifications(notifications);
      if (status != S_OK) {
        os_log_error(backendLog(), "IDeckLinkDiscovery could not install notifications (0x%08x)", (unsigned)status);
        notifications->Release(); created->Release();
        return;
      }
      discovery = created; callback = notifications; installed = true;
    });
#endif
  }
  bool isDiscovering() const { return installed.load(); }

  void arrived(IDeckLink *device) {
    if (!device) return;
    device->AddRef();
    dispatch_async(queue, ^{ insert(device); });
  }
  void removed(IDeckLink *device) {
    if (!device) return;
    device->AddRef();
    dispatch_async(queue, ^{ erase(device); device->Release(); });
  }
  void drain() { dispatch_sync(queue, ^{}); }

  // Returns an owned reference, or null when discovery has not seen the device.
  IDeckLink *copyDevice(NSString *identifier, DeviceCapabilities *capabilities) {
    std::lock_guard<std::mutex> guard(mutex);
    for (auto &entry : entries) {
      if (![entry.description.identifier isEqualToString:identifier]) continue;
      entry.device->AddRef();
      if (capabilities) *capabilities = entry.capabilities;
      return entry.device;
    }
    return nullptr;
  }

  // A running session, told directly when its device departs. Returns
  // whether the device is still listed, checked under the same lock, so a
  // removal processed before the attach is not missed.
  bool attachSession(NSString *identifier, CaptureCallback *capture, std::shared_ptr<SessionStats> stats) {
    capture->AddRef();
    std::lock_guard<std::mutex> guard(mutex);
    sessions.push_back({[identifier copy], capture});
    statsByDevice[std::string(identifier.UTF8String ?: "")] = std::move(stats);
    for (auto &entry : entries) if ([entry.description.identifier isEqualToString:identifier]) return true;
    return false;
  }
  // "Advertise HDR to cameras". On: each listed device's EDID advertises SDR,
  // PQ and HLG from its discovery until it departs or the setting goes off.
  // Off: Ultracam never writes the EDID, and lets go of one it wrote, which
  // restores the driver default. Either way that is one HDMI renegotiation per
  // device, at discovery or when the setting changes; a capture start never
  // writes the EDID.
  void setAdvertiseHDR(bool enabled) {
    advertisingHDR = enabled;
    dispatch_async(queue, ^{ applyAdvertisement(); });
  }
  // Bootstrap is synchronous so device arrival cannot publish an unconfigured
  // EDID. Overrides survive device removal/reconnect; the global value remains
  // the fallback only for devices without an explicit policy.
  void seedHDRAdvertisements(NSDictionary<NSString *, NSNumber *> *values) {
    dispatch_sync(queue, ^{
      for (NSString *identifier in values)
        hdrPolicies[std::string(identifier.UTF8String ?: "")] = values[identifier].boolValue;
      applyAdvertisement();
    });
  }
  HRESULT deviceAdvertiseHDR(NSString *identifier, bool *enabled, bool *available = nullptr) {
    __block HRESULT result = E_INVALIDARG;
    dispatch_sync(queue, ^{
      if (available) *available = false;
      std::lock_guard<std::mutex> guard(mutex);
      for (auto &entry : entries) if ([entry.description.identifier isEqualToString:identifier]) {
        if (available) *available = true;
        *enabled = effectiveAdvertisement(identifier);
        result = *enabled && !entry.edid ? entry.advertisementResult : S_OK;
        break;
      }
    });
    return result;
  }
  HRESULT setDeviceAdvertiseHDR(NSString *identifier, bool enabled) {
    __block HRESULT result = E_INVALIDARG;
    dispatch_sync(queue, ^{
      IDeckLink *device = nullptr;
      NSString *name = nil;
      {
        std::lock_guard<std::mutex> guard(mutex);
        for (auto &entry : entries) if ([entry.description.identifier isEqualToString:identifier]) {
          device = entry.device; name = entry.description.name; break;
        }
      }
      if (!device) return;
      const std::string key(identifier.UTF8String ?: "");
      auto previous = hdrPolicies.find(key);
      const std::optional<bool> old = previous == hdrPolicies.end() ? std::nullopt : std::optional<bool>(previous->second);
      hdrPolicies[key] = enabled;
      result = updateAdvertisement(device, identifier, name);
      if (result != S_OK && result != S_FALSE) {
        if (old) hdrPolicies[key] = *old; else hdrPolicies.erase(key);
      } else result = S_OK;
    });
    return result;
  }
  bool holdsAdvertisedEDID(NSString *identifier) {
    std::lock_guard<std::mutex> guard(mutex);
    for (auto &entry : entries)
      if ([entry.description.identifier isEqualToString:identifier]) return entry.edid != nullptr;
    return false;
  }
  void seedInputConnectors(NSDictionary<NSString *, NSNumber *> *values) {
    dispatch_sync(queue, ^{
      for (NSString *identifier in values) {
        const auto selected = BMDVideoConnection(values[identifier].unsignedIntValue);
        { std::lock_guard<std::mutex> guard(mutex); connectorPolicies[std::string(identifier.UTF8String ?: "")] = selected; }
        const HRESULT result = applyConnectorOnQueue(identifier, selected);
        std::lock_guard<std::mutex> guard(mutex);
        connectorErrors[std::string(identifier.UTF8String ?: "")] = result;
      }
    });
  }
  HRESULT deviceConnector(NSString *identifier, BMDVideoConnection *connection) {
    std::lock_guard<std::mutex> guard(mutex);
    for (auto &entry : entries) if ([entry.description.identifier isEqualToString:identifier]) {
      auto found = connectorPolicies.find(std::string(identifier.UTF8String ?: ""));
      *connection = found == connectorPolicies.end() ? defaultConnector(entry.capabilities.connections) : found->second;
      return (entry.capabilities.connections & *connection) ? S_OK : E_NOINTERFACE;
    }
    return E_INVALIDARG;
  }
  UCDeckLinkConnectorState *connectorState(NSString *identifier) {
    BMDVideoConnection connection = 0;
    const HRESULT result = deviceConnector(identifier, &connection);
    if (result == E_INVALIDARG) return nil;
    UCDeckLinkConnectorState *state = [UCDeckLinkConnectorState new]; state.connection = connection;
    std::lock_guard<std::mutex> guard(mutex);
    auto found = connectorErrors.find(std::string(identifier.UTF8String ?: ""));
    const HRESULT applied = result != S_OK ? result : found == connectorErrors.end() ? S_OK : found->second;
    if (applied != S_OK) state.applicationError = connectorSettingsError(applied);
    return state;
  }
  HRESULT setDeviceConnector(NSString *identifier, BMDVideoConnection connection) {
    __block HRESULT result = E_FAIL;
    dispatch_sync(queue, ^{ result = applyConnectorOnQueue(identifier, connection); });
    return result;
  }
  static BMDVideoConnection defaultConnector(BMDVideoConnection supported) {
    for (auto connection : {bmdVideoConnectionHDMI, bmdVideoConnectionSDI, bmdVideoConnectionOpticalSDI})
      if (supported & connection) return connection;
    return BMDVideoConnection(0);
  }
  HRESULT applyConnectorOnQueue(NSString *identifier, BMDVideoConnection connection) {
    if (connection != bmdVideoConnectionHDMI && connection != bmdVideoConnectionSDI && connection != bmdVideoConnectionOpticalSDI) return E_NOINTERFACE;
    IDeckLink *device = nullptr;
    {
      std::lock_guard<std::mutex> guard(mutex);
      for (auto &entry : entries) if ([entry.description.identifier isEqualToString:identifier]) {
        if (!(entry.capabilities.connections & connection)) return E_NOINTERFACE;
        device = entry.device;
      }
      if (!device) return E_INVALIDARG;
      auto stats = statsByDevice.find(std::string(identifier.UTF8String ?: ""));
      if (stats != statsByDevice.end() && stats->second->active) return E_ACCESSDENIED;
    }
    ComRef<IDeckLinkStatus> status;
    int64_t busy = 0;
    if (device->QueryInterface(IID_IDeckLinkStatus, reinterpret_cast<void **>(status.out())) == S_OK &&
        status->GetInt(bmdDeckLinkStatusBusy, &busy) == S_OK && (busy & bmdDeviceCaptureBusy)) return E_ACCESSDENIED;
    ComRef<IDeckLinkConfiguration> configuration;
    HRESULT result = device->QueryInterface(IID_IDeckLinkConfiguration, reinterpret_cast<void **>(configuration.out()));
    int64_t previous = 0, actual = 0;
    if (result == S_OK) result = configuration->GetInt(bmdDeckLinkConfigVideoInputConnection, &previous);
    const bool readPrevious = result == S_OK;
    if (result == S_OK && previous != connection) result = configuration->SetInt(bmdDeckLinkConfigVideoInputConnection, connection);
    if (result == S_OK) result = configuration->GetInt(bmdDeckLinkConfigVideoInputConnection, &actual);
    if (result == S_OK && actual != connection) result = E_FAIL;
    if (result != S_OK) {
      if (configuration && readPrevious && previous != connection) configuration->SetInt(bmdDeckLinkConfigVideoInputConnection, previous);
      return result;
    }
    ComRef<IDeckLinkInput> input;
    NSArray<UltracamMode *> *modes = nil;
    if (device->QueryInterface(IID_IDeckLinkInput, reinterpret_cast<void **>(input.out())) == S_OK)
      modes = supportedModes(input.value, connection);
    {
      std::lock_guard<std::mutex> guard(mutex);
      connectorPolicies[std::string(identifier.UTF8String ?: "")] = connection;
      connectorErrors[std::string(identifier.UTF8String ?: "")] = S_OK;
      for (auto &entry : entries) if (entry.device == device && modes) {
        UltracamDevice *updated = [UltracamDevice new];
        updated.identifier = entry.description.identifier; updated.name = entry.description.name;
        updated.videoInputConnections = entry.description.videoInputConnections; updated.modes = modes;
        entry.description = updated;
      }
    }
    applyAdvertisement();
    return S_OK;
  }
  void detachSession(CaptureCallback *capture) {
    CaptureCallback *released = nullptr;
    {
      std::lock_guard<std::mutex> guard(mutex);
      for (auto it = sessions.begin(); it != sessions.end(); ++it) {
        if (it->callback != capture) continue;
        released = it->callback; sessions.erase(it); break;
      }
    }
    if (released) released->Release();
  }

  NSArray<UltracamDevice *> *snapshot() {
    std::lock_guard<std::mutex> guard(mutex);
    NSMutableArray<UltracamDevice *> *result = [NSMutableArray arrayWithCapacity:entries.size()];
    for (auto &entry : entries) [result addObject:entry.description];
    return result;
  }

  id addObserver(void (^handler)(NSArray<UltracamDevice *> *)) {
    NSUUID *token = [NSUUID UUID];
    {
      std::lock_guard<std::mutex> guard(mutex);
      observerBlocks[token] = [handler copy];
    }
    startDiscovery();
    return token;
  }
  void removeObserver(id token) {
    if (![token isKindOfClass:[NSUUID class]]) return;
    std::lock_guard<std::mutex> guard(mutex);
    [observerBlocks removeObjectForKey:token];
  }

  UltracamDeviceDiagnostics *diagnostics(NSString *identifier) {
    std::lock_guard<std::mutex> guard(mutex);
    const DeviceEntry *found = nullptr;
    for (auto &entry : entries) if ([entry.description.identifier isEqualToString:identifier]) found = &entry;
    if (!found) return nil;
    UltracamDeviceDiagnostics *result = [UltracamDeviceDiagnostics new];
    result.identifier = found->description.identifier;
    result.name = found->description.name;
    result.driverVersion = installedDriverInfo().version;
    result.maximumHDMIAudioChannels = NSInteger(found->capabilities.maximumHDMIAudioChannels);
    result.capturedAudioChannels = 2;
    result.supportsFormatDetection = found->capabilities.formatDetection;
    result.supportsHDRMetadata = found->capabilities.hdrMetadata;
    result.supportsColorspaceMetadata = found->capabilities.colorspaceMetadata;
    result.supportsHDMITimecode = found->capabilities.hdmiTimecode;
    result.supportsHighFrameRateTimecode = found->capabilities.highFrameRateTimecode;
    result.temperatureCelsius = NSNotFound;
    result.hdmiDynamicRange = found->edid ? dynamicRangeList(kAdvertisedDynamicRange) : @"Driver default";
    auto stats = statsByDevice.find(std::string(identifier.UTF8String ?: ""));
    if (stats != statsByDevice.end() && stats->second) {
      SessionStats &values = *stats->second;
      const int present = values.signalPresent.load();
      result.signalPresent = present < 0 ? nil : @(present != 0);
      result.capturedAudioChannels = values.capturedAudioChannels.load();
      result.sessionActive = values.active.load();
      result.deviceDroppedFrames = values.deviceDrops.load();
      result.frameBacklog = values.backlog.load();
      result.maximumFrameBacklog = values.maxBacklog.load();
      int64_t temperature = values.temperature.load();
      if (temperature != INT64_MIN) result.temperatureCelsius = NSInteger(temperature);
      result.hostTimeMapped = values.hostOffsetValid.load();
      std::lock_guard<std::mutex> text(values.textMutex);
      result.signal = values.signal;
    }
    return result;
  }

 private:
  struct DeviceEntry {
    IDeckLink *device = nullptr;  // One owned reference.
    UltracamDevice *description = nil;
    DeviceCapabilities capabilities;
    // The HDR advertisement (see setAdvertiseHDR); one owned reference or null.
    IDeckLinkHDMIInputEDID *edid = nullptr;
    HRESULT advertisementResult = E_FAIL;
  };
  struct Session {
    NSString *identifier;
    CaptureCallback *callback;  // One owned reference.
  };

  // Registry queue only.
  void insert(IDeckLink *device) {
    ComRef<IDeckLink> owned; owned.value = device;
    ComRef<IDeckLinkInput> input;
    // Output-only devices, or an IID a pre-16 driver does not know.
    if (device->QueryInterface(IID_IDeckLinkInput, reinterpret_cast<void **>(input.out())) != S_OK || !input) return;
    NSUInteger ordinal = 0;
    {
      std::lock_guard<std::mutex> guard(mutex);
      for (auto &entry : entries) if (entry.device == device) return;
      ordinal = entries.size();
    }
    DeviceEntry entry;
    entry.capabilities = readCapabilities(device);
    UltracamDevice *description = [UltracamDevice new];
    description.identifier = deviceIdentifier(device, ordinal);
    CFStringRef name = nullptr; device->GetDisplayName(&name);
    description.name = name ? (__bridge NSString *)name : @"Blackmagic capture device";
    if (name) CFRelease(name);
    BMDVideoConnection selectedConnection = defaultConnector(entry.capabilities.connections);
    {
      std::lock_guard<std::mutex> guard(mutex);
      auto found = connectorPolicies.find(std::string(description.identifier.UTF8String ?: ""));
      if (found != connectorPolicies.end()) selectedConnection = found->second;
    }
    description.modes = supportedModes(input.value, selectedConnection);
    entry.description = description;
    description.videoInputConnections = entry.capabilities.connections;
    entry.device = owned.take();
    os_log(backendLog(), "Device arrived: %{public}@ (%{public}@)", description.name, description.identifier);
    {
      std::lock_guard<std::mutex> guard(mutex);
      entries.push_back(entry);
    }
    BMDVideoConnection selected = 0;
    if (deviceConnector(description.identifier, &selected) == S_OK) {
      bool explicitPolicy = false;
      { std::lock_guard<std::mutex> guard(mutex); explicitPolicy = connectorPolicies.count(std::string(description.identifier.UTF8String ?: "")); }
      if (explicitPolicy) {
        const HRESULT result = applyConnectorOnQueue(description.identifier, selected);
        std::lock_guard<std::mutex> guard(mutex);
        connectorErrors[std::string(description.identifier.UTF8String ?: "")] = result;
      }
    }
    // Before the device is published, so no capture can start first.
    if (effectiveAdvertisement(description.identifier)) updateAdvertisement(device, description.identifier, description.name);
    else os_log(backendLog(), "HDR advertisement is off: the HDMI EDID of %{public}@ (%{public}@) stays at the driver default",
      description.name, description.identifier);
    publish();
  }

  // Registry queue only.
  void applyAdvertisement() {
    struct Listed { IDeckLink *device; NSString *identifier; NSString *name; };
    std::vector<Listed> listed;
    {
      std::lock_guard<std::mutex> guard(mutex);
      for (auto &entry : entries) {
        entry.device->AddRef();
        listed.push_back({entry.device, entry.description.identifier, entry.description.name});
      }
    }
    for (auto &item : listed) {
      updateAdvertisement(item.device, item.identifier, item.name);
      item.device->Release();
    }
  }

  // Registry queue only: brings one listed device's EDID in line with the setting.
  bool effectiveAdvertisement(NSString *identifier) {
    auto found = hdrPolicies.find(std::string(identifier.UTF8String ?: ""));
    return found == hdrPolicies.end() ? advertisingHDR.load() : found->second;
  }
  HRESULT updateAdvertisement(IDeckLink *device, NSString *identifier, NSString *name) {
    bool held = false, capturing = false;
    IDeckLinkHDMIInputEDID *released = nullptr;
    bool enabled = effectiveAdvertisement(identifier);
    {
      std::lock_guard<std::mutex> guard(mutex);
      auto selected = connectorPolicies.find(std::string(identifier.UTF8String ?: ""));
      if (selected != connectorPolicies.end() && selected->second != bmdVideoConnectionHDMI) enabled = false;
      for (auto &entry : entries) {
        if (entry.device != device) continue;
        held = entry.edid != nullptr;
        if (!enabled) { released = entry.edid; entry.edid = nullptr; entry.advertisementResult = S_OK; }
        else if (held) entry.advertisementResult = S_OK;
      }
      for (auto &session : sessions) if ([session.identifier isEqualToString:identifier]) capturing = true;
    }
    if (!enabled) {
      if (!released) return S_OK;
      released->Release();
      os_log(backendLog(), "HDR advertisement turned off: released the HDMI EDID of %{public}@ (%{public}@); the driver default returns",
        name, identifier);
      return S_OK;
    }
    if (held) return S_OK;
    // Another app capturing: rewriting the EDID would renegotiate HDMI under it.
    // Ultracam's own capture is renegotiated: the user changed the setting.
    ComRef<IDeckLinkStatus> status;
    int64_t busy = 0;
    if (!capturing && device->QueryInterface(IID_IDeckLinkStatus, reinterpret_cast<void **>(status.out())) == S_OK &&
        status && status->GetInt(bmdDeckLinkStatusBusy, &busy) == S_OK && (busy & bmdDeviceCaptureBusy)) {
      os_log(backendLog(), "%{public}@ (%{public}@) is in use by another app: its HDMI EDID was left unchanged",
        name, identifier);
      std::lock_guard<std::mutex> guard(mutex);
      for (auto &entry : entries) if (entry.device == device) entry.advertisementResult = E_ACCESSDENIED;
      return E_ACCESSDENIED;
    }
    ComRef<IDeckLinkHDMIInputEDID> edid;
    HRESULT result = advertiseHDR(device, edid);
    if (result == S_OK)
      os_log(backendLog(), "HDMI EDID of %{public}@ (%{public}@) now advertises SDR, PQ and HLG; held while the device is listed",
        name, identifier);
    else if (result == S_FALSE)
      os_log(backendLog(), "HDMI EDID of %{public}@ (%{public}@) already advertises SDR, PQ and HLG; held, not rewritten",
        name, identifier);
    else
      os_log(backendLog(), "HDMI EDID of %{public}@ (%{public}@) left at the driver default (0x%08x)",
        name, identifier, (unsigned)result);
    std::lock_guard<std::mutex> guard(mutex);
    for (auto &entry : entries) {
      if (entry.device != device) continue;
      entry.advertisementResult = result;
      if (!entry.edid && edid) entry.edid = edid.take();
    }
    return result;
  }

  // Registry queue only.
  void erase(IDeckLink *device) {
    IDeckLink *owned = nullptr;
    IDeckLinkHDMIInputEDID *edid = nullptr;
    NSString *identifier = nil, *name = nil;
    std::vector<CaptureCallback *> affected;
    {
      std::lock_guard<std::mutex> guard(mutex);
      for (auto it = entries.begin(); it != entries.end(); ++it) {
        if (it->device != device) continue;
        owned = it->device; edid = it->edid; identifier = it->description.identifier; name = it->description.name;
        entries.erase(it); break;
      }
      if (!owned) return;
      for (auto &session : sessions) {
        if (![session.identifier isEqualToString:identifier]) continue;
        session.callback->AddRef(); affected.push_back(session.callback);
      }
    }
    os_log(backendLog(), "Device removed: %{public}@ (%{public}@)", name, identifier);
    // Not the driver thread: CaptureController hops to its own queue and stops.
    for (CaptureCallback *capture : affected) {
      capture->reportFatal(@"UltraStudio disconnected. Reconnect it to resume capture.");
      capture->Release();
    }
    if (edid) edid->Release();
    owned->Release();
    publish();
  }

  void publish() {
    NSArray<UltracamDevice *> *list = snapshot();
    NSArray *handlers = nil;
    {
      std::lock_guard<std::mutex> guard(mutex);
      handlers = observerBlocks.allValues;
    }
    for (void (^handler)(NSArray<UltracamDevice *> *) in handlers)
      dispatch_async(observerQueue, ^{ handler(list); });
  }

  dispatch_queue_t queue;
  dispatch_queue_t observerQueue;
  std::mutex mutex;
  std::vector<DeviceEntry> entries;
  std::vector<Session> sessions;
  std::map<std::string, std::shared_ptr<SessionStats>> statsByDevice;
  NSMutableDictionary<NSUUID *, id> *observerBlocks;
  std::once_flag discoveryOnce;
  std::atomic<bool> installed{false};
  // Off until the app applies its setting: tools never write the EDID.
  std::atomic<bool> advertisingHDR{false};
  std::map<std::string, bool> hdrPolicies; // discovery queue only
  std::map<std::string, BMDVideoConnection> connectorPolicies; // mutex
  std::map<std::string, HRESULT> connectorErrors; // mutex
  IDeckLinkDiscovery *discovery = nullptr;
  DiscoveryCallback *callback = nullptr;
};

HRESULT DiscoveryCallback::DeckLinkDeviceArrived(IDeckLink *device) { owner->arrived(device); return S_OK; }
HRESULT DiscoveryCallback::DeckLinkDeviceRemoved(IDeckLink *device) { owner->removed(device); return S_OK; }

// MARK: Device notifications

// bmdPreferencesChanged and bmdStatusChanged arrive on a private thread. The
// handler only hops to the backend's control queue.
class NotificationCallback final : public IDeckLinkNotificationCallback {
 public:
  std::atomic<bool> active{true};
  explicit NotificationCallback(void (^handler)(BMDNotifications, uint64_t)) : notify([handler copy]) {}
  HRESULT QueryInterface(REFIID iid, LPVOID *object) override {
    if (!object) return E_INVALIDARG;
    *object = nullptr;
    if (sameIID(iid, CFUUIDGetUUIDBytes(IUnknownUUID)) || sameIID(iid, IID_IDeckLinkNotificationCallback)) {
      *object = static_cast<IDeckLinkNotificationCallback *>(this); AddRef(); return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG remaining = --references; if (!remaining) delete this; return remaining; }
  HRESULT Notify(BMDNotifications topic, uint64_t param1, uint64_t) override {
    if (active.load()) notify(topic, param1);
    return S_OK;
  }
 private:
  std::atomic<ULONG> references{1};
  void (^notify)(BMDNotifications, uint64_t);
};

struct NotificationLease {
  ComRef<IDeckLinkNotification> notification;
  NotificationCallback *callback = nullptr;
  bool preferences = false, status = false;
  void subscribe(IDeckLink *device, void (^handler)(BMDNotifications, uint64_t)) {
    if (device->QueryInterface(IID_IDeckLinkNotification, reinterpret_cast<void **>(notification.out())) != S_OK ||
        !notification) return;
    callback = new NotificationCallback(handler);
    preferences = notification->Subscribe(bmdPreferencesChanged, callback) == S_OK;
    status = notification->Subscribe(bmdStatusChanged, callback) == S_OK;
  }
  ~NotificationLease() {
    if (callback) callback->active = false;
    if (notification && callback) {
      if (preferences) notification->Unsubscribe(bmdPreferencesChanged, callback);
      if (status) notification->Unsubscribe(bmdStatusChanged, callback);
    }
    if (callback) callback->Release();
  }
};

// IDeckLinkStatus before EnableVideoInput, after the connector is selected.
static void readStatusColorimetry(IDeckLinkStatus *status, BMDColorspace *colorspace, int64_t *eotf) {
  int64_t value = 0;
  if (status->GetInt(bmdDeckLinkStatusDetectedVideoInputColorspace, &value) == S_OK && colorspaceName(BMDColorspace(value)))
    *colorspace = BMDColorspace(value);
  if (status->GetInt(bmdDeckLinkStatusDetectedVideoInputDynamicRange, &value) == S_OK)
    *eotf = eotfFromDynamicRange(value);
}

static std::optional<DetectedInput> detectedStatusInput(IDeckLinkStatus *status, IDeckLinkInput *input) {
  int64_t flags = 0;
  if (status->GetInt(bmdDeckLinkStatusDetectedVideoInputFormatFlags, &flags) != S_OK) return std::nullopt;
  ComRef<IDeckLinkDisplayMode> mode;
  // SDK 16 returns the detected mode as an interface (ReadMe: IDeckLinkStatus::GetInterface).
  if (status->GetInterface(bmdDeckLinkStatusDetectedVideoInputMode, reinterpret_cast<void **>(mode.out())) != S_OK ||
      !mode) {
    if (mode) { mode->Release(); mode.value = nullptr; }
    int64_t value = 0;
    if (status->GetInt(bmdDeckLinkStatusDetectedVideoInputMode, &value) != S_OK || value == bmdModeUnknown ||
        input->GetDisplayMode(BMDDisplayMode(value), mode.out()) != S_OK || !mode) return std::nullopt;
  }
  DetectedInput result = describeInput(mode.value, BMDDetectedVideoInputFormatFlags(flags));
  readStatusColorimetry(status, &result.colorspace, &result.eotf);
  return result;
}

#if defined(ULTRACAM_BACKEND_TESTING)
#include "../Tests/BackendTestSupport.inc"
#endif


static const void *UltracamControlQueueKey = &UltracamControlQueueKey;

@implementation UCDeckLinkBackend {
  dispatch_queue_t _controlQueue;
  void (^_groupBegin)(void);
  void (^_groupEnd)(void);
  void (^_timecodeHandler)(NSString *);
  NSInteger _requestedWidth, _requestedHeight;
  CMTime _requestedDuration;
  void (^_audioFormatHandler)(NSInteger);
  void (^_cpuMemoryFrameHandler)(UCDeckLinkOwnedMemoryFrame *, CMTime, CMTime);
  // Session state below is owned by the control queue.
  IDeckLink *_device;
  IDeckLinkInput *_input;
  IDeckLinkStatus *_status;
  IDeckLinkStatistics *_statistics;
  CaptureCallback *_callback;
  std::unique_ptr<HDMILease> _connection;
  std::unique_ptr<NotificationLease> _notifications;
  std::shared_ptr<AutoModeMailbox> _autoMode;
  // One instance for the backend's life, so property reads never race a swap.
  std::shared_ptr<SessionStats> _stats;
  std::shared_ptr<std::atomic<bool>> _colorimetryPending;
  dispatch_source_t _pollTimer;
  DeviceRegistry *_registry;
  uint64_t _generation;
  DetectedInput _lastDetected;
  BOOL _hasDetected;
  HostOffsetFilter _hostOffset;
  NSString *_lastColorimetry;
#if defined(ULTRACAM_BACKEND_TESTING)
  BOOL _scheduledOffControlQueue;
#endif
}

- (void)setCallbackGroupHandlersWithBegin:(void (^)(void))begin end:(void (^)(void))end {
  [self onControlQueue:^{
    NSAssert(!self->_callback, @"Group handlers must be configured before capture starts");
    self->_groupBegin = [begin copy]; self->_groupEnd = [end copy];
  }];
}
- (void)setCallbackTimecodeHandler:(void (^)(NSString *))handler {
  [self onControlQueue:^{
    NSAssert(!self->_callback, @"Timecode handler must be configured before capture starts");
    self->_timecodeHandler = [handler copy];
  }];
}
- (void)setRequestedWidth:(NSInteger)width height:(NSInteger)height duration:(CMTime)duration {
  [self onControlQueue:^{ self->_requestedWidth = width; self->_requestedHeight = height; self->_requestedDuration = duration; }];
}
- (void)setAudioFormatHandler:(void (^)(NSInteger))handler {
  [self onControlQueue:^{ self->_audioFormatHandler = [handler copy]; }];
}
- (void)setCPUMemoryFrameHandler:(void (^)(UCDeckLinkOwnedMemoryFrame *, CMTime, CMTime))handler {
  [self onControlQueue:^{ self->_cpuMemoryFrameHandler = [handler copy]; }];
}
- (NSInteger)configuredAudioChannels {
  __block NSInteger channels = 0;
  [self onControlQueue:^{ if (self->_callback && self->_callback->audioEnabled) channels = self->_callback->audioChannels; }];
  return channels;
}

- (instancetype)init {
  if ((self = [super init])) {
    _controlQueue = dispatch_queue_create("org.ultracam.decklink.control", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_controlQueue, UltracamControlQueueKey, (__bridge void *)self, nullptr);
    _stats = std::make_shared<SessionStats>();
    _colorimetryPending = std::make_shared<std::atomic<bool>>(false);
    _registry = &DeviceRegistry::shared();
  }
  return self;
}

- (void)onControlQueue:(void (^)(void))action {
  if (dispatch_get_specific(UltracamControlQueueKey) == (__bridge void *)self) action();
  else dispatch_sync(_controlQueue, action);
}

+ (UltracamDriverInfo *)driverInfo {
  return installedDriverInfo();
}
+ (NSString *)sdkVersion {
  const uint32_t version = BLACKMAGIC_DECKLINK_API_VERSION;
  return [NSString stringWithFormat:@"%u.%u.%u", (version >> 24) & 255, (version >> 16) & 255, (version >> 8) & 255];
}
+ (void)seedInputConnectors:(NSDictionary<NSString *, NSNumber *> *)values { DeviceRegistry::shared().seedInputConnectors(values); }
+ (NSNumber *)inputConnectorForDeviceID:(NSString *)deviceID error:(NSError **)error {
  BMDVideoConnection connection = 0;
  const HRESULT result = DeviceRegistry::shared().deviceConnector(deviceID, &connection);
  if (result == S_OK) return @(connection);
  if (error) *error = connectorSettingsError(result); return nil;
}
+ (UCDeckLinkConnectorState *)inputConnectorStateForDeviceID:(NSString *)deviceID error:(NSError **)error {
  UCDeckLinkConnectorState *state = DeviceRegistry::shared().connectorState(deviceID);
  if (!state && error) *error = connectorSettingsError(E_INVALIDARG);
  return state;
}
+ (BOOL)setInputConnector:(uint32_t)connection deviceID:(NSString *)deviceID error:(NSError **)error {
  const HRESULT result = DeviceRegistry::shared().setDeviceConnector(deviceID, BMDVideoConnection(connection));
  if (result == S_OK) return YES;
  if (error) *error = connectorSettingsError(result); return NO;
}

+ (id)addDeviceListObserver:(void (^)(NSArray<UltracamDevice *> *))handler {
  return DeviceRegistry::shared().addObserver(handler);
}

+ (void)setAdvertisesHDRToCameras:(BOOL)enabled {
  DeviceRegistry::shared().setAdvertiseHDR(enabled);
}
+ (void)seedHDRAdvertisements:(NSDictionary<NSString *, NSNumber *> *)values {
  DeviceRegistry::shared().seedHDRAdvertisements(values);
}
+ (NSNumber *)hdrAdvertisementForDeviceID:(NSString *)deviceID error:(NSError **)error {
  bool enabled = false;
  const HRESULT result = DeviceRegistry::shared().deviceAdvertiseHDR(deviceID, &enabled);
  if (result == S_OK) return @(enabled);
  if (error) *error = hdrSettingsError(result);
  return nil;
}
+ (UltracamHDRAdvertisementState *)hdrAdvertisementStateForDeviceID:(NSString *)deviceID error:(NSError **)error {
  bool enabled = false, available = false;
  const HRESULT result = DeviceRegistry::shared().deviceAdvertiseHDR(deviceID, &enabled, &available);
  if (!available) { if (error) *error = hdrSettingsError(E_INVALIDARG); return nil; }
  UltracamHDRAdvertisementState *state = [UltracamHDRAdvertisementState new];
  state.enabled = enabled;
  state.applicationError = result == S_OK ? nil : hdrSettingsError(result);
  return state;
}
+ (BOOL)setHDRAdvertisement:(BOOL)enabled deviceID:(NSString *)deviceID error:(NSError **)error {
  const HRESULT result = DeviceRegistry::shared().setDeviceAdvertiseHDR(deviceID, enabled);
  if (result == S_OK) return YES;
  if (error) *error = hdrSettingsError(result);
  return NO;
}

+ (void)removeDeviceListObserver:(id)token {
  DeviceRegistry::shared().removeObserver(token);
}

+ (UltracamDeviceDiagnostics *)diagnosticsForDeviceID:(NSString *)deviceID {
  return DeviceRegistry::shared().diagnostics(deviceID);
}

- (uint64_t)deviceDroppedFrames {
  return _stats->deviceDrops.load(std::memory_order_relaxed);
}

- (uint32_t)availableFrameBacklog {
  return _stats->backlog.load(std::memory_order_relaxed);
}

- (uint32_t)maximumFrameBacklog {
  return _stats->maxBacklog.load(std::memory_order_relaxed);
}

+ (NSArray<UltracamDevice *> *)devicesWithError:(NSError **)error {
  UltracamDriverInfo *driver = installedDriverInfo();
  // A pre-16 driver enumerates devices but rejects SDK 16 interface IDs, which
  // would otherwise look like an empty device list.
  if (driver.installed && !driver.supported) { fail(error, driver.message); return nil; }
  ComRef<IDeckLinkIterator> iterator; iterator.value = CreateDeckLinkIteratorInstance();
  if (!iterator) { fail(error, @"Blackmagic Desktop Video is not available. Install Desktop Video 16 or later."); return nil; }
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
    const auto capabilities = readCapabilities(device.value);
    description.videoInputConnections = capabilities.connections;
    BMDVideoConnection selectedConnection = DeviceRegistry::defaultConnector(capabilities.connections);
    DeviceRegistry::shared().deviceConnector(identifier, &selectedConnection);
    description.modes = supportedModes(input.value, selectedConnection);
    [result addObject:description];
  }
  return result;
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
  ++_generation;
  UltracamDriverInfo *driver = installedDriverInfo();
  if (driver.installed && !driver.supported) return fail(error, driver.message);
  // Prefer the device discovery already holds; enumerate only when discovery
  // has not reported it (not installed yet, or its arrival is still queued).
  DeviceCapabilities capabilities;
  ComRef<IDeckLink> device;
  device.value = _registry->copyDevice(deviceID, &capabilities);
  const bool held = device.value != nullptr;
  if (!device) {
    ComRef<IDeckLinkIterator> iterator; iterator.value = CreateDeckLinkIteratorInstance();
    if (!iterator) return fail(error, @"Blackmagic Desktop Video is not available.");
    IDeckLink *raw = nullptr; NSUInteger index = 0;
    while (iterator->Next(&raw) == S_OK) {
      ComRef<IDeckLink> candidate; candidate.value = raw;
      if ([deviceIdentifier(candidate.value, index++) isEqualToString:deviceID]) { device.value = candidate.take(); break; }
    }
  }
  if (!device) return fail(error, @"UltraStudio is disconnected. Refresh the input list.");
  if (!held) capabilities = readCapabilities(device.value);
  ComRef<IDeckLinkInput> input;
  if (device->QueryInterface(IID_IDeckLinkInput, reinterpret_cast<void **>(input.out())) != S_OK || !input)
    return fail(error, @"The selected Blackmagic device has no capture input.");
  ComRef<IDeckLinkStatus> deviceStatus;
  if (device->QueryInterface(IID_IDeckLinkStatus, reinterpret_cast<void **>(deviceStatus.out())) != S_OK)
    deviceStatus.value = nullptr;
  // Another app capturing from the device: refuse before touching it. Selecting
  // the connector or rewriting the EDID would renegotiate HDMI under that app.
  // A status the driver cannot report is not a refusal; EnableVideoInput decides.
  int64_t busyState = 0;
  if (deviceStatus && deviceStatus->GetInt(bmdDeckLinkStatusBusy, &busyState) == S_OK &&
      (busyState & bmdDeviceCaptureBusy))
    return fail(error, @"UltraStudio is in use by another app. Close the other capture app, then restart.", E_ACCESSDENIED);
  BMDVideoInputFlags inputFlags = capabilities.formatDetection ? bmdVideoInputEnableFormatDetection : bmdVideoInputFlagDefault;
  if (autoFrameHandler && !capabilities.formatDetection)
    return fail(error, @"This Blackmagic device/driver does not support automatic HDMI format detection.");
  auto connection = std::make_unique<HDMILease>();
  // Every failure from here on restores the connector it changed, while
  // `input` is still held (this guard is destroyed before it).
  struct AbandonOnFailure {
    HDMILease *lease;
    ~AbandonOnFailure() { if (lease) lease->abandon(); }
  } abandonOnFailure{connection.get()};
  BMDVideoConnection selectedConnection = DeviceRegistry::defaultConnector(capabilities.connections);
  _registry->deviceConnector(deviceID, &selectedConnection);
  HRESULT connectionStatus = connection->select(device.value, selectedConnection);
  if (connectionStatus != S_OK) return fail(error, @"Cannot select the UltraStudio HDMI input. Close other capture apps, then restart.", connectionStatus);
  // The EDID is never written here: rewriting it hot-plugs HDMI and the camera
  // drops its signal for seconds. The registry advertises HDR at discovery
  // when the setting is on (DeviceRegistry::setAdvertiseHDR).
  os_log(backendLog(), "Capture start leaves the HDMI EDID unchanged: %{public}s",
    held && _registry->holdsAdvertisedEDID(deviceID) ? "SDR, PQ and HLG (advertised at discovery)" :
      "Ultracam advertises no HDR (driver default)");
  if (!capabilities.hdmiTimecode)
    os_log(backendLog(), "Device does not report HDMI timecode support; RP188 may be absent");
  os_log(backendLog(), "HDMI audio: device maximum %lld channels; capturing the supported 2/8/16-channel group at 32-bit",
    (long long)capabilities.maximumHDMIAudioChannels);

  BMDDisplayMode requestedMode = inputFast ? bmdMode4K2160p5994 : bmdMode4K2160p2997;
  std::optional<NativeFrameContract> selectedContract;
  if (_requestedWidth > 0) {
    ComRef<IDeckLinkDisplayModeIterator> modes;
    if (input->GetDisplayModeIterator(modes.out()) == S_OK) {
      IDeckLinkDisplayMode *raw = nullptr;
      while (modes->Next(&raw) == S_OK) {
        ComRef<IDeckLinkDisplayMode> mode; mode.value = raw;
        auto contract = nativeFrameContract(mode.value);
        if (contract && contract->width == _requestedWidth && contract->height == _requestedHeight &&
            CMTimeCompare(contract->duration, _requestedDuration) == 0) {
          selectedContract = contract; requestedMode = mode->GetDisplayMode(); break;
        }
      }
    }
    if (!selectedContract) return fail(error, @"The requested HDMI size and exact frame rate are not advertised by this device.");
  }
  bool supported = false;
  HRESULT status = S_OK;
  // Open the detected mode directly so a 29.97 camera does not pay a
  // Pause/Enable/Flush/Start cycle. Falls back when the status is unavailable
  // before the input is enabled.
  std::optional<DetectedInput> detected;
  if (autoFrameHandler && deviceStatus) detected = detectedStatusInput(deviceStatus.value, input.value);
  const bool openDetected = detected && detected->supported &&
    input->DoesSupportVideoMode(selectedConnection, detected->mode, detected->pixel,
      bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, nullptr, &supported) == S_OK && supported;
  if (openDetected) {
    requestedMode = detected->mode;
  } else {
    supported = false;
    status = input->DoesSupportVideoMode(selectedConnection, requestedMode,
      bmdFormat10BitYUV, bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, nullptr, &supported);
    if (autoFrameHandler && (status != S_OK || !supported)) {
      ComRef<IDeckLinkDisplayModeIterator> modes;
      if (input->GetDisplayModeIterator(modes.out()) == S_OK) {
        IDeckLinkDisplayMode *raw = nullptr;
        while (modes->Next(&raw) == S_OK) {
          ComRef<IDeckLinkDisplayMode> mode; mode.value = raw;
          auto contract = nativeFrameContract(mode.value);
          if (!contract) continue;
          status = input->DoesSupportVideoMode(selectedConnection, mode->GetDisplayMode(),
            bmdFormat10BitYUV, bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, nullptr, &supported);
          if (status == S_OK && supported) { requestedMode = mode->GetDisplayMode(); selectedContract = contract; break; }
        }
      }
    }
    if (status != S_OK || !supported)
      return fail(error, @"The device does not support the requested HDMI 10-bit YUV mode.", status);
  }
  auto callback = new CaptureCallback(requestedMode, inputFast ? 60000 : 30000, frameHandler, eventHandler,
    mediaHandler, rawAudioHandler);
  if (openDetected && detected->contract) callback->setActiveContract(*detected->contract);
  else if (selectedContract) callback->setActiveContract(*selectedContract);
  if (autoFrameHandler || selectedContract) callback->timeScale = 240000;
  callback->audioChannels = capabilities.maximumHDMIAudioChannels >= 16 ? 16 : capabilities.maximumHDMIAudioChannels >= 8 ? 8 : 2;
  callback->audioFormatHandler = [_audioFormatHandler copy];
  callback->cpuMemoryFrameHandler = [_cpuMemoryFrameHandler copy];
  callback->groupBegin = [_groupBegin copy];
  callback->groupEnd = [_groupEnd copy];
  callback->timecodeHandler = [_timecodeHandler copy];
  callback->connection = selectedConnection;
  callback->supportsHDRMetadata = capabilities.hdrMetadata;
  callback->supportsColorspaceMetadata = capabilities.colorspaceMetadata;
  callback->timecodes.highFrameRateSupported = capabilities.highFrameRateTimecode;
  _stats->reset();
  callback->stats = _stats;
  if (deviceStatus) {
    BMDColorspace colorspace = 0; int64_t eotf = kEOTFUnknown;
    readStatusColorimetry(deviceStatus.value, &colorspace, &eotf);
    callback->signalColorspace = colorspace; callback->signalEOTF = eotf;
  }
  if (autoFrameHandler) {
    [self configureAutoCallback:callback frameHandler:autoFrameHandler];
    // The driver's first notification for this same signal must not restart it.
    if (openDetected) callback->lastDetection = detectionSignature(detected->mode, detected->flags);
  }
  status = startInput(input.value, callback, requestedMode, inputFlags, rawAudioHandler != nil);
  if (status != S_OK) {
    if (_autoMode) { _autoMode->cancel(); _autoMode.reset(); }
    callback->Release();
    return fail(error, status == E_ACCESSDENIED ?
      @"UltraStudio is in use by another app. Close the other capture app, then restart." :
      [NSString stringWithFormat:@"UltraStudio could not start the HDMI 10-bit input (0x%08x). Check Desktop Video and HDMI settings.", (unsigned)status], status);
  }
  connection->started = true;
  abandonOnFailure.lease = nullptr;
  _input = input.take(); _callback = callback; _connection = std::move(connection);
  _device = device.take(); _status = deviceStatus.take();
  if (_device->QueryInterface(IID_IDeckLinkStatistics, reinterpret_cast<void **>(&_statistics)) != S_OK)
    _statistics = nullptr;
  _stats->active = true;
  // A device discovery held but has since removed: report it now.
  if (!_registry->attachSession(deviceID, callback, _stats) && held)
    callback->reportFatal(@"UltraStudio disconnected. Reconnect it to resume capture.");
  [self subscribeNotifications];
  // The reference clock is readable once the input is enabled (manual 2.5.4.17).
  [self pollSession:_generation];
  [self startPollTimer];
  if (openDetected) {
    os_log(backendLog(), "Opened the detected HDMI mode directly: %{public}@", detected->fullDescription());
    [self announceDetected:*detected];
  }
  return YES;
}

- (void)configureAutoCallback:(CaptureCallback *)callback
  frameHandler:(void (^)(CVPixelBufferRef, CMTime, CMTime, BOOL))frameHandler {
  // Frames stay enabled until a format notification says otherwise. Desktop Video
  // only notifies when the signal differs from the opened mode, so an input that
  // already matches it never gets a notification and would otherwise never be delivered.
  // A mismatched signal arrives flagged without an input source, or fails the
  // Active SDK descriptor validation in VideoInputFrameArrived.
  callback->framesEnabled = true;
  _autoMode = std::make_shared<AutoModeMailbox>();
  auto mailbox = _autoMode;
  callback->autoFrameHandler = [frameHandler copy];
  __weak UCDeckLinkBackend *weakSelf = self;
  dispatch_queue_t nativeQueue = _controlQueue;
  callback->modeHandler = ^(DetectedInput detected, bool keepFrames) {
    if (mailbox->push(detected, keepFrames ? nullptr : &callback->framesEnabled)) {
      // Never promote the weak backend on the driver callback thread. Releasing
      // its final reference there could run dealloc/StopStreams inside the
      // very callback StopStreams is waiting to finish.
      dispatch_async(nativeQueue, ^{
        UCDeckLinkBackend *owner = weakSelf;
        if (owner) [owner performDetection:mailbox];
        else mailbox->cancel();
      });
    }
  };
  // Coalesced: at most one colorimetry refresh is queued at a time.
  auto pending = _colorimetryPending;
  const uint64_t generation = _generation;
  callback->colorimetryHandler = ^{
    if (pending->exchange(true)) return;
    dispatch_async(nativeQueue, ^{
      pending->store(false);
      UCDeckLinkBackend *owner = weakSelf;
      [owner refreshColorimetry:generation];
    });
  };
}

- (void)scheduleDetection:(std::shared_ptr<AutoModeMailbox>)mailbox {
#if defined(ULTRACAM_BACKEND_TESTING)
  if (dispatch_get_specific(UltracamControlQueueKey) != (__bridge void *)self) _scheduledOffControlQueue = YES;
#endif
  __weak UCDeckLinkBackend *weakSelf = self;
  dispatch_async(_controlQueue, ^{
    UCDeckLinkBackend *owner = weakSelf;
    if (owner) [owner performDetection:mailbox];
    else mailbox->cancel();
  });
}

- (void)announceDetected:(const DetectedInput &)detected {
  _lastDetected = detected;
  _hasDetected = YES;
  _lastColorimetry = colorimetryText(detected.colorspace, detected.eotf);
  _stats->setSignal(detected.fullDescription());
  if (_callback && _callback->accepting)
    _callback->eventHandler([NSString stringWithFormat:@"Detected HDMI input: %@ — capturing 10-bit YUV 4:2:2.",
      detected.fullDescription()]);
}

// Control queue. Status first, then whatever the frames' metadata reported.
- (void)refreshColorimetry:(uint64_t)generation {
  if (generation != _generation || !_callback || !_callback->accepting) return;
  CaptureCallback *callback = _callback;
  BMDColorspace colorspace = BMDColorspace(callback->signalColorspace.load());
  int64_t eotf = callback->signalEOTF.load();
  if (_status) {
    readStatusColorimetry(_status, &colorspace, &eotf);
    callback->signalColorspace = colorspace; callback->signalEOTF = eotf;
  }
  if (uint32_t observed = callback->observedColorspace.load()) colorspace = BMDColorspace(observed);
  if (int64_t observed = callback->observedEOTF.load(); observed != kEOTFUnknown) eotf = observed;
  if (!_hasDetected || !callback->framesEnabled) return;
  if ([colorimetryText(colorspace, eotf) isEqualToString:_lastColorimetry]) return;
  DetectedInput updated = _lastDetected;
  updated.colorspace = colorspace; updated.eotf = eotf;
  os_log(backendLog(), "HDMI colorimetry changed without a mode change: %{public}@", updated.fullDescription());
  [self announceDetected:updated];
}

- (void)performDetection:(std::shared_ptr<AutoModeMailbox>)mailbox {
  if (_autoMode != mailbox || !_input || !_callback) return;
  auto detected = mailbox->snapshot();
  if (!detected) return;
  CaptureCallback *callback = _callback;
  if (!callback->accepting) { mailbox->cancel(); return; }
  DetectedInput current = *detected;
  if (_status) readStatusColorimetry(_status, &current.colorspace, &current.eotf);
  if (!current.supported) {
    if (mailbox->isCurrent(current.sequence))
      callback->eventHandler([NSString stringWithFormat:@"Unsupported HDMI input: %@. Requires a supported progressive HDMI mode, YUV 4:2:2, and at least 10-bit source precision.", current.fullDescription()]);
  } else {
    // The streams already run in this mode, and every mode is captured as
    // 10-bit YUV: only format flags changed (or a mode came back after an
    // unsupported signal), so frames are enabled again without a restart.
    const auto active = std::atomic_load(&callback->activeContract);
    bool supported = active && current.pixel == active->pixel && current.mode == callback->streamingMode.load();
    HRESULT status = S_OK;
    if (!supported) {
      status = _input->DoesSupportVideoMode(callback->connection, current.mode,
        current.pixel, bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, nullptr, &supported);
      if (status == S_OK && supported) status = reconfigureInput(_input, callback, current);
    }
    if (status != S_OK || !supported) {
      if (mailbox->cancelCurrent(current.sequence, callback->accepting))
        callback->reportFatal([NSString stringWithFormat:@"Cannot capture detected HDMI input: %@ (0x%08x).", current.fullDescription(), (unsigned)status]);
    } else if (mailbox->enableCurrent(current.sequence, callback->framesEnabled, &callback->accepting)) {
      callback->settleGatedFrames();
      if (current.colorspace) callback->signalColorspace = current.colorspace;
      callback->signalEOTF = current.eotf;
      [self announceDetected:current];
      [self pollSession:_generation];
    }
  }
  if (mailbox->finish(current.sequence)) [self scheduleDetection:mailbox];
}

- (void)subscribeNotifications {
  __weak UCDeckLinkBackend *weakSelf = self;
  dispatch_queue_t nativeQueue = _controlQueue;
  const uint64_t generation = _generation;
  _notifications = std::make_unique<NotificationLease>();
  _notifications->subscribe(_device, ^(BMDNotifications topic, uint64_t parameter) {
    // Private API thread: hop to the control queue, never touch the backend here.
    dispatch_async(nativeQueue, ^{
      UCDeckLinkBackend *owner = weakSelf;
      [owner handleNotification:topic parameter:parameter generation:generation];
    });
  });
}

// Control queue (manual 3.42: bmdPreferencesChanged has no parameters;
// bmdStatusChanged carries the BMDDeckLinkStatusID that changed).
- (void)handleNotification:(BMDNotifications)topic parameter:(uint64_t)parameter generation:(uint64_t)generation {
  if (generation != _generation || !_input || !_callback) return;
  if (topic == bmdPreferencesChanged) {
    HDMILease *lease = _connection.get();
    int64_t current = 0;
    if (!lease || !lease->configuration ||
        lease->configuration->GetInt(bmdDeckLinkConfigVideoInputConnection, &current) != S_OK ||
        current == lease->selected) return;
    os_log(backendLog(), "Desktop Video preferences moved the input to connection 0x%llx; reselecting HDMI",
      (unsigned long long)current);
    HRESULT result = lease->configuration->SetInt(bmdDeckLinkConfigVideoInputConnection, lease->selected);
    int64_t actual = 0;
    if (result == S_OK) result = lease->configuration->GetInt(bmdDeckLinkConfigVideoInputConnection, &actual);
    if (result == S_OK && actual == lease->selected) {
      // Restore the outside choice when this session ends.
      lease->previous = current; lease->changed = true;
      _callback->eventHandler(lease->selected == bmdVideoConnectionHDMI ? @"Desktop Video settings changed the UltraStudio input. Ultracam reselected HDMI for this session." : @"Desktop Video settings changed the capture input. Ultracam reselected the configured connector for this session.");
    } else _callback->reportFatal(@"Desktop Video did not confirm the configured capture connector after its preferences changed.");
    return;
  }
  if (topic != bmdStatusChanged) return;
  switch (BMDDeckLinkStatusID(parameter)) {
    case bmdDeckLinkStatusDetectedVideoInputColorspace:
    case bmdDeckLinkStatusDetectedVideoInputDynamicRange:
      [self refreshColorimetry:generation];
      break;
    case bmdDeckLinkStatusVideoInputSignalLocked: {
      bool locked = false;
      if (_status && _status->GetFlag(bmdDeckLinkStatusVideoInputSignalLocked, &locked) == S_OK)
        os_log(backendLog(), "HDMI signal %{public}s", locked ? "locked" : "unlocked");
      break;
    }
    default: break;
  }
}

- (void)startPollTimer {
  __weak UCDeckLinkBackend *weakSelf = self;
  const uint64_t generation = _generation;
  _pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _controlQueue);
  dispatch_source_set_timer(_pollTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
  dispatch_source_set_event_handler(_pollTimer, ^{
    UCDeckLinkBackend *owner = weakSelf;
    [owner pollSession:generation];
  });
  dispatch_resume(_pollTimer);
}

// Control queue, about once a second: never on the frame path.
- (void)pollSession:(uint64_t)generation {
  if (generation != _generation || !_input) return;
  HostClockSample sample;
  int64_t offset = 0;
  if (!sampleHostOffset(_input, &sample)) sample = HostClockSample();
  if (_hostOffset.offer(sample, &offset)) {
    _stats->hostOffsetMicros.store(offset, std::memory_order_relaxed);
    _stats->hostOffsetValid.store(true, std::memory_order_release);
  }
  uint32_t available = 0;
  if (_input->GetAvailableVideoFrameCount(&available) == S_OK) {
    _stats->backlog = available;
    if (available > _stats->maxBacklog.load()) _stats->maxBacklog = available;
  }
  int64_t temperature = 0;
  if (_statistics && _statistics->GetInt(bmdDeckLinkStatisticDeviceTemperature, &temperature) == S_OK)
    _stats->temperature = temperature;
}

- (void)stop { [self onControlQueue:^{ [self stopOnQueue]; }]; }

- (void)stopOnQueue {
  ++_generation;
  if (_pollTimer) { dispatch_source_cancel(_pollTimer); _pollTimer = nil; }
  if (_autoMode) { _autoMode->cancel(); _autoMode.reset(); }
  if (_callback) _registry->detachSession(_callback);
  // Unsubscribe before the device and its input are released.
  _notifications.reset();
  if (_input) {
    stopInput(_input, _callback);
    // Restore the connector while this successful session still holds its
    // input, never after release. The EDID is the registry's and stays.
    _connection.reset();
    _input->Release(); _input = nullptr;
  } else {
    if (_connection) _connection->started = false;
    _connection.reset();
  }
  if (_statistics) { _statistics->Release(); _statistics = nullptr; }
  if (_status) { _status->Release(); _status = nullptr; }
  if (_device) { _device->Release(); _device = nullptr; }
  if (_callback) { _callback->Release(); _callback = nullptr; }
  _stats->active = false;
  _hostOffset.reset();
  _hasDetected = NO;
  _lastColorimetry = nil;
}

#if defined(ULTRACAM_BACKEND_TESTING)
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

- (BOOL)runSDK16Checks:(NSError **)error {
  // A private registry and fake device: no real discovery, driver or hardware.
  dispatch_queue_t observers = dispatch_queue_create("org.ultracam.tests.sdk16", DISPATCH_QUEUE_SERIAL);
  BOOL result = NO;
  {
    FakeDeckLink device, fallback, busy, denied;
    DeviceRegistry registry(observers);
    _registry = &registry;
    result = [self runSDK16ChecksWithRegistry:&registry device:&device fallback:&fallback error:error] &&
      [self runClaimChecksWithRegistry:&registry busy:&busy denied:&denied error:error];
    [self stop];
    _registry = &DeviceRegistry::shared();
    registry.drain();
    if (result && (!device.balanced() || !fallback.balanced() || !busy.balanced() || !denied.balanced()))
      result = fail(error, @"An SDK 16 session leaked device, EDID, status or notification references.");
  }
  return result;
}

- (BOOL)runSDK16ChecksWithRegistry:(DeviceRegistry *)registry device:(FakeDeckLink *)device
  fallback:(FakeDeckLink *)fallback error:(NSError **)error {
  NSMutableArray<NSString *> *events = [NSMutableArray array];
  __block CVPixelBufferRef retained = nullptr;
  auto frameBlock = ^(CVPixelBufferRef buffer, CMTime, CMTime, BOOL valid) {
    if (!valid) return;
    if (retained) CVPixelBufferRelease(retained);
    retained = CVPixelBufferRetain(buffer);
  };
  auto eventBlock = ^(NSString *message) { @synchronized (events) { [events addObject:message]; } };
  auto lastEvent = ^NSString *{ @synchronized (events) { return events.lastObject; } };
  auto rawBlock = ^(NSData *, CMTime, NSUInteger, NSUInteger, NSUInteger) {};
  NSString *identifier = @"decklink:000000001234abcd";
  device->input.audioResult = S_OK;
  device->input.provideClock = true; device->input.clockOffsetMicros = 1000000;
  device->input.availableFrames = 3;
  device->configuration.connection = bmdVideoConnectionSDI;
  // "Advertise HDR to cameras" on: the EDID is written at discovery, before
  // the device is published, and never by a capture start.
  registry->setAdvertiseHDR(true);
  registry->arrived(device);
  registry->drain();
  if (device->edid.writes != 1 || device->edid.value != kAdvertisedDynamicRange || device->edid.references != 2 ||
      ![registry->diagnostics(@"decklink:000000001234abcd").hdmiDynamicRange isEqualToString:@"SDR · PQ · HLG"])
    return fail(error, @"Discovery did not advertise HDR in the HDMI EDID with the setting on.");

  __block BOOL started = NO;
  __block NSError *startError = nil;
  [self onControlQueue:^{
    started = [self startOnQueue:identifier inputFast:YES frameHandler:nil autoFrameHandler:frameBlock
      mediaHandler:nil rawAudioHandler:rawBlock eventHandler:eventBlock error:&startError];
  }];
  if (!started) return fail(error, [@"SDK 16 start failed: " stringByAppendingString:startError.localizedDescription ?: @"?"]);
  // The held device opened the detected 29.97 mode directly: no reconfiguration cycle.
  if (device->input.calls != std::vector<std::string>{"support", "enable", "callback", "start"} ||
      device->input.enabledMode != bmdMode4K2160p2997 || device->input.enabledAudioType != bmdAudioSampleType32bitInteger)
    return fail(error, @"Start did not open the detected 29.97 mode directly.");
  if (device->edid.writes != 1 || device->edid.value != kAdvertisedDynamicRange || device->edid.references != 2 ||
      device->configuration.connection != bmdVideoConnectionHDMI || device->notification.subscriptions.size() != 2)
    return fail(error, @"Start wrote the EDID or did not hold the HDMI and notification leases.");
  if (![lastEvent() hasPrefix:@"Detected HDMI input: "] || ![lastEvent() containsString:@"29.97"] ||
      ![lastEvent() containsString:@"Rec.709 · SDR"])
    return fail(error, @"The directly opened mode was not announced with its colorimetry.");
  if (!_stats->hostOffsetValid || std::llabs(_stats->hostOffsetMicros.load() - 1000000) > 2000 ||
      _stats->backlog != 3 || _stats->temperature != 47 || self.availableFrameBacklog != 3)
    return fail(error, @"Start did not sample the reference clock, backlog and temperature.");

  // The driver's first notification for the same signal must not restart it.
  auto flags = BMDDetectedVideoInputFormatFlags(device->status.formatFlags);
  IDeckLinkInputCallback *driverCallback = device->input.callback;
  driverCallback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &device->status.detectedMode, flags);
  [self onControlQueue:^{}];
  if (device->input.calls.size() != 4) return fail(error, @"A matching first notification restarted the input.");

  // Colorimetry-only change: reported, no Pause/Enable/Flush/Start.
  NSUInteger eventCount = events.count;
  device->status.detectedMode.flags = bmdDisplayModeColorspaceRec2020;
  device->status.colorspace = bmdColorspaceRec2020;
  driverCallback->VideoInputFormatChanged(bmdVideoInputColorspaceChanged, &device->status.detectedMode, flags);
  [self onControlQueue:^{}];
  if (device->input.calls.size() != 4 || !_callback->framesEnabled || events.count != eventCount + 1 ||
      ![lastEvent() containsString:@"Rec.2020 · SDR"])
    return fail(error, @"A colorimetry-only format change restarted capture or was not reported.");
  // bmdStatusChanged for the dynamic range (HLG through the widened EDID).
  device->status.dynamicRange = bmdDynamicRangeHDRStaticHLG;
  device->notification.post(bmdStatusChanged, bmdDeckLinkStatusDetectedVideoInputDynamicRange);
  [self onControlQueue:^{}];
  if (![lastEvent() containsString:@"Rec.2020 · HDR HLG"] || device->input.calls.size() != 4)
    return fail(error, @"A status notification did not update the reported dynamic range.");

  // A frame carries the detected colorimetry and the host capture time.
  bool destroyed = false;
  auto frame = new FakeFrame(&destroyed);
  frame->frameDuration = 2002; frame->hardwareTime = 9000000;
  driverCallback->VideoInputFrameArrived(frame, nullptr);
  frame->Release();
  NSNumber *host = retained ? CFBridgingRelease(CVBufferCopyAttachment(retained, CFSTR("UltracamCaptureHostTime"), nullptr)) : nil;
  if (!retained || std::abs(host.doubleValue - 10.0) > 0.002 ||
      ![attachmentString(retained, kCVImageBufferYCbCrMatrixKey) isEqualToString:(__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_2020] ||
      ![attachmentString(retained, kCVImageBufferTransferFunctionKey) isEqualToString:(__bridge NSString *)kCVImageBufferTransferFunction_ITU_R_2100_HLG])
    return fail(error, @"A captured frame lacked its host time or detected colorimetry.");
  CVPixelBufferRelease(retained); retained = nullptr;
  if (!destroyed) return fail(error, @"The captured fake frame leaked.");

  UltracamDeviceDiagnostics *diagnostics = registry->diagnostics(identifier);
  if (!diagnostics.sessionActive || diagnostics.temperatureCelsius != 47 || diagnostics.frameBacklog != 3 ||
      !diagnostics.hostTimeMapped || ![diagnostics.hdmiDynamicRange isEqualToString:@"SDR · PQ · HLG"] ||
      ![diagnostics.signal containsString:@"HDR HLG"] || diagnostics.maximumHDMIAudioChannels != 8)
    return fail(error, @"Device diagnostics did not reflect the live session.");

  // Desktop Video Setup moved the connector: reselect HDMI, restore their choice later.
  device->configuration.connection = bmdVideoConnectionSDI;
  device->notification.post(bmdPreferencesChanged, 0);
  [self onControlQueue:^{}];
  if (device->configuration.connection != bmdVideoConnectionHDMI || ![lastEvent() containsString:@"reselected HDMI"])
    return fail(error, @"A preferences change did not reselect the HDMI input.");

  // Unplugging the active device is a clear error, not a no-signal wait.
  registry->removed(device);
  registry->drain();
  if (![lastEvent() isEqualToString:@"Capture error: UltraStudio disconnected. Reconnect it to resume capture."] ||
      _callback->accepting)
    return fail(error, @"Removing the active device did not report the disconnection.");
  [self stop];
  if (device->input.calls.size() < 3 || device->input.calls[device->input.calls.size() - 3] != "stop" ||
      device->input.calls.back() != "disable" || device->input.callback ||
      device->configuration.connection != bmdVideoConnectionSDI ||
      device->edid.value != (bmdDynamicRangeSDR | bmdDynamicRangeHDRStaticPQ) || !device->notification.subscriptions.empty())
    return fail(error, @"Stop did not restore the connector and EDID or unsubscribe notifications.");
  if (registry->diagnostics(identifier)) return fail(error, @"A removed device still had diagnostics.");

  // Status unavailable before EnableVideoInput: today's 59.94 open, then detection.
  fallback->attributes.persistentID = 0x77;
  fallback->status.available = false;
  fallback->input.audioResult = S_OK;
  registry->arrived(fallback);
  registry->drain();
  eventCount = events.count;
  [self onControlQueue:^{
    started = [self startOnQueue:@"decklink:0000000000000077" inputFast:YES frameHandler:nil autoFrameHandler:frameBlock
      mediaHandler:nil rawAudioHandler:rawBlock eventHandler:eventBlock error:&startError];
  }];
  if (!started || fallback->input.calls != std::vector<std::string>{"support", "enable", "callback", "start"} ||
      fallback->input.enabledMode != bmdMode4K2160p5994 || events.count != eventCount)
    return fail(error, @"Unavailable detection status did not fall back to the 59.94 open.");
  [self stop];
  // Stop, then Start again: the advertisement written at discovery is still in
  // effect and nothing is written. Writing the EDID is an HDMI hot-plug: the
  // camera drops its signal for seconds, so a start that rewrote it showed a
  // frame, went blank, then came back.
  if (fallback->edid.writes != 1 || fallback->edid.value != kAdvertisedDynamicRange)
    return fail(error, @"Stopping a session restored the default EDID of a device that is still listed.");
  auto startFallback = ^BOOL {
    __block BOOL ok = NO;
    __block NSError *startFailure = nil;
    [self onControlQueue:^{
      ok = [self startOnQueue:@"decklink:0000000000000077" inputFast:YES frameHandler:nil autoFrameHandler:frameBlock
        mediaHandler:nil rawAudioHandler:rawBlock eventHandler:eventBlock error:&startFailure];
    }];
    return ok;
  };
  if (!startFallback() || fallback->edid.writes != 1 || fallback->edid.value != kAdvertisedDynamicRange ||
      ![registry->diagnostics(@"decklink:0000000000000077").hdmiDynamicRange isEqualToString:@"SDR · PQ · HLG"])
    return fail(error, @"A second start rewrote the HDMI EDID (an HDMI hot-plug at every start).");
  // Turned off while capturing: the advertisement is released (the driver
  // default returns) and nothing is written.
  registry->setAdvertiseHDR(false);
  registry->drain();
  if (fallback->edid.writes != 1 || fallback->edid.value != (bmdDynamicRangeSDR | bmdDynamicRangeHDRStaticPQ) ||
      fallback->edid.references != 1 ||
      ![registry->diagnostics(@"decklink:0000000000000077").hdmiDynamicRange isEqualToString:@"Driver default"])
    return fail(error, @"Turning HDR advertisement off did not release the EDID.");
  // Turned on again: written once, now, though Ultracam itself is capturing.
  registry->setAdvertiseHDR(true);
  registry->drain();
  registry->setAdvertiseHDR(true);
  registry->drain();
  if (fallback->edid.writes != 2 || fallback->edid.value != kAdvertisedDynamicRange || fallback->edid.references != 2)
    return fail(error, @"Turning HDR advertisement on did not write the EDID of a listed device exactly once.");
  [self stop];
  // Off: a start writes nothing.
  registry->setAdvertiseHDR(false);
  registry->drain();
  if (!startFallback() || fallback->edid.writes != 2 ||
      fallback->edid.value != (bmdDynamicRangeSDR | bmdDynamicRangeHDRStaticPQ))
    return fail(error, @"A start wrote the HDMI EDID with HDR advertisement off.");
  [self stop];
  registry->removed(fallback);
  registry->drain();
  if (fallback->edid.value != (bmdDynamicRangeSDR | bmdDynamicRangeHDRStaticPQ))
    return fail(error, @"Removing the device did not restore its default EDID.");

  // Off at discovery: the EDID is never touched, at arrival or at start.
  {
    FakeDeckLink unadvertised;
    unadvertised.attributes.persistentID = 0x88;
    unadvertised.input.audioResult = S_OK;
    registry->arrived(&unadvertised);
    registry->drain();
    __block BOOL offOk = NO;
    __block NSError *offError = nil;
    [self onControlQueue:^{
      offOk = [self startOnQueue:@"decklink:0000000000000088" inputFast:YES frameHandler:nil autoFrameHandler:frameBlock
        mediaHandler:nil rawAudioHandler:rawBlock eventHandler:eventBlock error:&offError];
    }];
    const BOOL offStarted = offOk;
    const bool untouched = unadvertised.edid.writes == 0 && unadvertised.edid.references == 1;
    [self stop];
    registry->removed(&unadvertised);
    registry->drain();
    if (!offStarted || !untouched || !unadvertised.balanced())
      return fail(error, @"With HDR advertisement off, discovery or a start touched the HDMI EDID.");
  }
  return YES;
}

// A device another app is capturing from is refused before its connector or
// EDID is touched; a claim the driver refuses later puts both back.
- (BOOL)runClaimChecksWithRegistry:(DeviceRegistry *)registry busy:(FakeDeckLink *)busy
  denied:(FakeDeckLink *)denied error:(NSError **)error {
  auto frameBlock = ^(CVPixelBufferRef, CMTime, CMTime, BOOL) {};
  auto eventBlock = ^(NSString *) {};
  __block BOOL started = NO;
  __block NSError *startError = nil;
  // Busy at discovery with the setting on: the EDID is left alone.
  registry->setAdvertiseHDR(true);
  registry->drain();
  busy->attributes.persistentID = 0x55;
  busy->status.busy = bmdDeviceCaptureBusy;
  busy->configuration.connection = bmdVideoConnectionSDI;
  registry->arrived(busy);
  registry->drain();
  [self onControlQueue:^{
    started = [self startOnQueue:@"decklink:0000000000000055" inputFast:YES frameHandler:nil autoFrameHandler:frameBlock
      mediaHandler:nil rawAudioHandler:nil eventHandler:eventBlock error:&startError];
  }];
  if (started || ![startError.localizedDescription containsString:@"in use by another app"] ||
      busy->configuration.writes != 0 || busy->configuration.connection != bmdVideoConnectionSDI ||
      busy->edid.writes != 0 || !busy->input.calls.empty())
    return fail(error, @"A busy device had its connector, EDID or input touched before the claim was refused.");
  registry->removed(busy);
  registry->drain();

  // Discovered with the setting on: advertised then; the refused claim leaves it.
  denied->attributes.persistentID = 0x66;
  denied->input.enableResult = E_ACCESSDENIED;
  denied->configuration.connection = bmdVideoConnectionSDI;
  registry->arrived(denied);
  registry->drain();
  startError = nil;
  [self onControlQueue:^{
    started = [self startOnQueue:@"decklink:0000000000000066" inputFast:YES frameHandler:nil autoFrameHandler:frameBlock
      mediaHandler:nil rawAudioHandler:nil eventHandler:eventBlock error:&startError];
  }];
  if (started || ![startError.localizedDescription containsString:@"in use by another app"] ||
      denied->edid.writes != 1 || denied->configuration.writes != 2 ||
      denied->configuration.connection != bmdVideoConnectionSDI ||
      denied->edid.value != kAdvertisedDynamicRange || denied->edid.references != 2)
    return fail(error, @"A refused claim left the connector on HDMI or touched the discovery EDID.");
  registry->removed(denied);
  registry->drain();
  if (denied->edid.value != (bmdDynamicRangeSDR | bmdDynamicRangeHDRStaticPQ))
    return fail(error, @"Removing a device did not restore its default EDID.");
  return YES;
}

- (BOOL)runAutoChecks:(NSError **)error {
  // Uses the production queue, callback adapter and reconfiguration method.
  // No real device is enumerated or opened by this fixture.
  FakeInput input;
  struct StopGuard {
    __unsafe_unretained UCDeckLinkBackend *owner;
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

  // Unsupported scan and source precision are reported accurately and
  // gated without destroying the detector, so a later valid source recovers.
  mode.width = 1920; mode.height = 1080; mode.mode = bmdModeHD1080p5994; mode.fieldDominance = bmdUpperFieldFirst;
  callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, flags);
  [self onControlQueue:^{}];
  callback->VideoInputFrameArrived(frame, nullptr);
  if (callback->framesEnabled || frames != 2 || ![lastEvent containsString:@"1920 × 1080"] || ![lastEvent containsString:@"59.94"])
    return fail(error, @"Unsupported HDMI detection fabricated expected input metadata.");
  mode.width = 3840; mode.height = 2160; mode.mode = bmdMode4K2160p5994; mode.fieldDominance = bmdProgressiveFrame;
  callback->VideoInputFormatChanged(bmdVideoInputColorspaceChanged, &mode,
    bmdDetectedVideoInputRGB444 | bmdDetectedVideoInput8BitDepth);
  [self onControlQueue:^{}];
  if (callback->framesEnabled || ![lastEvent containsString:@"8-bit"])
    return fail(error, @"Auto mode admitted an unimplemented 8-bit RGB source.");
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

// A format notification at the running mode (format flags only) keeps frames
// flowing without a restart. A real mode change restarts the streams, and
// the frames it gated or flushed are device drops, since the restarted stream
// clock cannot show them as a gap.
- (BOOL)runFormatChangeChecks:(NSError **)error {
  FakeInput input;
  struct StopGuard {
    __unsafe_unretained UCDeckLinkBackend *owner;
    ~StopGuard() { [owner stop]; }
  } stopGuard{self};
  FakeInput *inputPointer = &input;
  __block int frames = 0;
  __block NSString *lastEvent = nil;
  auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, ^(NSString *message) { lastEvent = message; });
  callback->AddRef(); // Test retains the callback beyond backend stop.
  ComRef<CaptureCallback> callbackReference; callbackReference.value = callback;
  [self onControlQueue:^{
    self->_input = inputPointer; inputPointer->AddRef(); self->_callback = callback;
    [self configureAutoCallback:callback frameHandler:^(CVPixelBufferRef, CMTime, CMTime, BOOL valid) {
      if (valid) ++frames;
    }];
    inputPointer->SetCallback(callback);
  }];
  bool destroyed = false;
  auto frame = new FakeFrame(&destroyed);
  ComRef<IDeckLinkVideoInputFrame> frameReference; frameReference.value = frame;
  FakeMode mode;
  const auto tenBit = bmdDetectedVideoInputYCbCr422 | bmdDetectedVideoInput10BitDepth;
  const auto twelveBit = bmdDetectedVideoInputYCbCr422 | bmdDetectedVideoInput12BitDepth;
  const std::vector<std::string> opened = {"callback"};

  // The opened mode's own notification, then 10-bit to 12-bit: frames never stop.
  callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, tenBit);
  callback->VideoInputFrameArrived(frame, nullptr);
  [self onControlQueue:^{}];
  callback->VideoInputFormatChanged(bmdVideoInputColorspaceChanged, &mode, twelveBit);
  if (!callback->framesEnabled) return fail(error, @"A format-flags change at the running mode gated frames.");
  callback->VideoInputFrameArrived(frame, nullptr);
  [self onControlQueue:^{}];
  if (input.calls != opened || !callback->framesEnabled || frames != 2 || ![lastEvent containsString:@"12-bit"] ||
      callback->stats->deviceDrops != 0)
    return fail(error, @"A format-flags change at the running mode restarted the input or lost frames.");

  // A real mode change: two frames arrive while it waits for the control
  // queue, and three more are still queued in the driver when it pauses.
  dispatch_semaphore_t hold = dispatch_semaphore_create(0);
  dispatch_async(_controlQueue, ^{ dispatch_semaphore_wait(hold, DISPATCH_TIME_FOREVER); });
  input.availableFrames = 3;
  mode.mode = bmdMode4K2160p2997;
  callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, tenBit);
  callback->VideoInputFrameArrived(frame, nullptr);
  callback->VideoInputFrameArrived(frame, nullptr);
  if (callback->framesEnabled || frames != 2) return fail(error, @"A mode change did not gate stale-mode frames.");
  dispatch_semaphore_signal(hold);
  [self onControlQueue:^{}];
  const std::vector<std::string> restarted = {"callback", "support", "pause", "enable", "flush", "start"};
  if (input.calls != restarted || !callback->framesEnabled || input.enabledMode != bmdMode4K2160p2997)
    return fail(error, @"A mode change did not restart the input in the new mode.");
  if (callback->stats->deviceDrops != 5)
    return fail(error, [NSString stringWithFormat:@"Frames gated and flushed by a restart were not device drops (%llu).",
      (unsigned long long)callback->stats->deviceDrops.load()]);
  frame->frameDuration = 2002;
  callback->VideoInputFrameArrived(frame, nullptr);
  if (frames != 3 || callback->stats->deviceDrops != 5) return fail(error, @"The restarted input did not resume cleanly.");

  // An unsupported source's frames are not losses; the same mode coming
  // back re-enables frames without a restart, and the gap shows in stream time.
  callback->VideoInputFormatChanged(bmdVideoInputColorspaceChanged, &mode,
    bmdDetectedVideoInputRGB444 | bmdDetectedVideoInput8BitDepth);
  [self onControlQueue:^{}];
  callback->VideoInputFrameArrived(frame, nullptr);
  if (callback->framesEnabled || frames != 3 || ![lastEvent containsString:@"8-bit"])
    return fail(error, @"An 8-bit source was not gated and reported.");
  dispatch_async(_controlQueue, ^{ dispatch_semaphore_wait(hold, DISPATCH_TIME_FOREVER); });
  callback->VideoInputFormatChanged(bmdVideoInputColorspaceChanged, &mode, tenBit);
  callback->VideoInputFrameArrived(frame, nullptr);
  dispatch_semaphore_signal(hold);
  [self onControlQueue:^{}];
  callback->VideoInputFrameArrived(frame, nullptr);
  if (input.calls != restarted || !callback->framesEnabled || frames != 4 || callback->stats->deviceDrops != 5)
    return fail(error, @"A supported source returning at the running mode restarted the input or double-counted its gap.");

  [self stop];
  frameReference.take()->Release(); callbackReference.take()->Release();
  if (!destroyed || input.references != 1) return fail(error, @"Format-change checks leaked native frame/input references.");
  return YES;
}
#endif

- (void)dealloc {
  // A synchronous cleanup must not retain self in a block during deallocation.
  __unsafe_unretained UCDeckLinkBackend *owner = self;
  if (dispatch_get_specific(UltracamControlQueueKey) == (__bridge void *)self) [self stopOnQueue];
  else dispatch_sync(_controlQueue, ^{ [owner stopOnQueue]; });
}
@end

#if defined(ULTRACAM_BACKEND_TESTING)
uint64_t UltracamV210MinimumRowBytes(uint64_t width) { return minimumV210RowBytes(width); }
BOOL UltracamRunOwnershipSyntheticChecks(NSError **error) {
  UCDeckLinkBackend *backend = [UCDeckLinkBackend new];
  return [backend runOwnershipChecks:error];
}

BOOL UltracamRunSDK16SyntheticChecks(NSError **error) {
  if (!runFrameFeatureChecks(error)) return NO;
  UCDeckLinkBackend *backend = [UCDeckLinkBackend new];
  return [backend runSDK16Checks:error];
}

BOOL UltracamRunAutoSyntheticChecks(NSError **error) {
  UCDeckLinkBackend *backend = [UCDeckLinkBackend new];
  if (![backend runAutoChecks:error]) return NO;
  UCDeckLinkBackend *formatChanges = [UCDeckLinkBackend new];
  return [formatChanges runFormatChangeChecks:error];
}
#endif

#if defined(ULTRACAM_BACKEND_TESTING)
BOOL UltracamRunCallbackGroupSyntheticChecks(NSError **error) {
  NSMutableArray<NSString *> *order = [NSMutableArray array];
  __block int depth = 0;
  __block bool valid = true;
  __block NSString *preframeTimecode = nil;
  auto mark = ^(NSString *value) { if (depth != 1) valid = false; [order addObject:value]; };
  auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000,
    ^(CVPixelBufferRef, CMTime, BOOL) {
      if (![preframeTimecode isEqualToString:@"01:02:03;08"]) valid = false;
      mark(@"frame");
    },
    ^(NSString *) { mark(@"event"); },
    ^(NSString *tc, CMTime, NSUInteger, NSUInteger, float, float, float, float, NSUInteger, BOOL) {
      if ((tc || preframeTimecode) && ![tc isEqualToString:preframeTimecode]) valid = false;
      mark(@"media");
    },
    ^(NSData *, CMTime, NSUInteger, NSUInteger, NSUInteger) { mark(@"audio"); });
  callback->groupBegin = ^{ ++depth; [order addObject:@"begin"]; };
  callback->groupEnd = ^{ [order addObject:@"end"]; --depth; };
  callback->timecodeHandler = ^(NSString *tc) { preframeTimecode = tc; };
  bool destroyed = false;
  auto frame = new FakeFrame(&destroyed);
  auto timecode = new FakeTimecode(); frame->timecode = timecode;
  callback->VideoInputFrameArrived(frame, nullptr);
  callback->VideoInputFrameArrived(nullptr, nullptr);
  frame->noSignal = true;
  callback->VideoInputFrameArrived(frame, nullptr);
  frame->timecode = nullptr; timecode->Release(); frame->Release();
  callback->Release();
  NSArray *expected = @[@"begin", @"frame", @"media", @"audio", @"end",
    @"begin", @"media", @"audio", @"end", @"begin", @"event", @"media", @"audio", @"end"];
  if (!valid || depth != 0 || !destroyed || ![order isEqualToArray:expected])
    return fail(error, @"Callback group did not enclose frame, media, audio and signal-loss paths.");
  return YES;
}

BOOL UltracamRunPerDeviceHDRSyntheticChecks(NSError **error) {
  dispatch_queue_t observers = dispatch_queue_create("org.ultracam.hdr-policy-checks", DISPATCH_QUEUE_SERIAL);
  FakeDeckLink first, second, inherited, unsupported, busy, failedWrite;
  first.attributes.persistentID = 0xa1; second.attributes.persistentID = 0xb2;
  inherited.attributes.persistentID = 0xc3; unsupported.attributes.persistentID = 0xd4;
  busy.attributes.persistentID = 0xe5; unsupported.hasEDID = false;
  failedWrite.attributes.persistentID = 0xf6; failedWrite.edid.writeResult = E_FAIL;
  busy.status.busy = bmdDeviceCaptureBusy;
  {
    DeviceRegistry registry(observers);
    registry.seedHDRAdvertisements(@{@"decklink:00000000000000a1": @YES, @"decklink:00000000000000b2": @NO,
      @"decklink:00000000000000d4": @YES, @"decklink:00000000000000e5": @YES,
      @"decklink:00000000000000f6": @YES});
    registry.arrived(&first); registry.arrived(&second); registry.arrived(&inherited);
    registry.arrived(&unsupported); registry.arrived(&busy); registry.drain();
    registry.arrived(&failedWrite); registry.drain();
    bool requested = false;
    if (registry.deviceAdvertiseHDR(@"decklink:00000000000000f6", &requested) != E_FAIL || !requested ||
        registry.deviceAdvertiseHDR(@"decklink:00000000000000e5", &requested) != E_ACCESSDENIED || !requested ||
        registry.deviceAdvertiseHDR(@"decklink:00000000000000d4", &requested) != E_NOINTERFACE || !requested)
      return fail(error, @"A failed seeded HDR policy was falsely acknowledged as applied at discovery.");
    failedWrite.edid.writeResult = S_OK;
    if (registry.setDeviceAdvertiseHDR(@"decklink:00000000000000f6", true) != S_OK ||
        registry.deviceAdvertiseHDR(@"decklink:00000000000000f6", &requested) != S_OK || !requested)
      return fail(error, @"Retrying the same seeded HDR value did not clear its application failure after a successful write.");
    if (registry.setDeviceAdvertiseHDR(@"decklink:00000000000000f6", false) != S_OK ||
        registry.setDeviceAdvertiseHDR(@"decklink:00000000000000e5", false) != S_OK ||
        registry.deviceAdvertiseHDR(@"decklink:00000000000000e5", &requested) != S_OK || requested)
      return fail(error, @"Turning off a failed seeded HDR policy did not remain actionable.");
    failedWrite.edid.writeResult = E_FAIL;
    if (first.edid.writes != 1 || second.edid.writes != 0 || inherited.edid.writes != 0)
      return fail(error, @"Seeded per-device HDR policy was not applied before discovery publication.");
    if (registry.setDeviceAdvertiseHDR(@"decklink:00000000000000a1", true) != S_OK || first.edid.writes != 1)
      return fail(error, @"Same-value HDR policy rewrote the EDID.");
    registry.setAdvertiseHDR(true); registry.drain();
    if (second.edid.writes != 0 || inherited.edid.writes != 1 || first.edid.writes != 1)
      return fail(error, @"Legacy HDR fallback overwrote a per-device policy or stopped applying to unmigrated devices.");
    if (registry.setDeviceAdvertiseHDR(@"decklink:00000000000000a1", false) != S_OK || first.edid.references != 1 || inherited.edid.references != 2)
      return fail(error, @"Turning one device off changed another device's held EDID.");
    if (registry.setDeviceAdvertiseHDR(@"decklink:missing", true) != E_INVALIDARG ||
        registry.setDeviceAdvertiseHDR(@"decklink:00000000000000d4", true) != E_NOINTERFACE ||
        registry.setDeviceAdvertiseHDR(@"decklink:00000000000000e5", true) != E_ACCESSDENIED)
      return fail(error, @"Unknown, unsupported or busy device HDR policy did not report the actual failure.");
    bool enabled = true;
    if (registry.deviceAdvertiseHDR(@"decklink:00000000000000a1", &enabled) != S_OK || enabled)
      return fail(error, @"Per-device policy query lost the committed value.");
    registry.setAdvertiseHDR(false); registry.drain();
    if (inherited.edid.references != 1 || second.edid.writes != 0)
      return fail(error, @"Unmigrated device did not follow the old global off fallback.");
    if (registry.setDeviceAdvertiseHDR(@"decklink:00000000000000f6", false) != S_OK ||
        registry.setDeviceAdvertiseHDR(@"decklink:00000000000000f6", true) != E_FAIL ||
        registry.deviceAdvertiseHDR(@"decklink:00000000000000f6", &enabled) != S_OK || enabled || failedWrite.edid.references != 1)
      return fail(error, @"Failed EDID write did not preserve the hardware error, roll back policy and release its lease.");
  }
  if (!first.balanced() || !second.balanced() || !inherited.balanced() || !unsupported.balanced() || !busy.balanced() || !failedWrite.balanced())
    return fail(error, @"Per-device HDR policy leaked native resources.");
  return YES;
}

BOOL UltracamRunFrameContractSyntheticChecks(NSError **error) {
  FakeMode mode;
  const auto flags = bmdDetectedVideoInputYCbCr422 | bmdDetectedVideoInput10BitDepth;
  mode.fieldDominance = bmdUpperFieldFirst;
  if (describeInput(&mode, flags).supported) return fail(error, @"Interlaced mode was declared progressive.");
  mode.fieldDominance = bmdProgressiveSegmentedFrame;
  if (describeInput(&mode, flags).supported) return fail(error, @"PsF mode was declared progressive.");
  mode.fieldDominance = bmdProgressiveFrame; mode.rateScale = 30000;
  auto described = describeInput(&mode, flags);
  if (!described.supported || CMTimeCompare(described.duration, CMTimeMake(1001, 30000)) != 0)
    return fail(error, @"SDK-reported exact cadence was replaced by a mode-ID assumption.");
  auto refused = [](auto configure) {
    __block int frames = 0, failures = 0;
    auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000,
      ^(CVPixelBufferRef, CMTime, BOOL) { ++frames; },
      ^(NSString *message) { if ([message hasPrefix:@"Capture error:"]) ++failures; });
    bool destroyed = false;
    auto frame = new FakeFrame(&destroyed); configure(frame);
    callback->VideoInputFrameArrived(frame, nullptr);
    frame->Release(); callback->Release();
    return frames == 0 && failures == 1 && destroyed;
  };
  if (!refused([](FakeFrame *frame) { frame->frameDuration = 2002; }))
    return fail(error, @"Frame cadence differed from active native declaration.");
  if (!refused([](FakeFrame *frame) { frame->rowBytes = 16; }))
    return fail(error, @"Short packed stride bypassed validation when SDK buffer length was absent.");
  if (!refused([](FakeFrame *frame) { frame->rowBytes = -1; }))
    return fail(error, @"Negative packed stride was admitted.");
  if (!refused([](FakeFrame *frame) { frame->rowBytes = LONG_MAX; }))
    return fail(error, @"Overflowing packed allocation extent was admitted.");
  if (!refused([](FakeFrame *frame) { frame->rowBytes = 10241; }))
    return fail(error, @"Misaligned packed stride was admitted.");
  if (!refused([](FakeFrame *frame) { frame->wrappedWidth = 1920; }))
    return fail(error, @"SDK wrapper dimensions differed from its native frame declaration.");
  return YES;
}
BOOL UltracamRunExpandedModeSyntheticChecks(NSError **error) {
  __block NSUInteger reportedChannels = 0, reportedBytes = 0;
  auto packet = new FakeRawAudioPacket({1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16});
  packet->channelCount = 8;
  reportRawAudio(packet, ^(NSData *data, CMTime, NSUInteger, NSUInteger channels, NSUInteger) {
    reportedChannels = channels; reportedBytes = data.length;
  }, 8);
  packet->Release();
  if (reportedChannels != 8 || reportedBytes != 64) return fail(error, @"Embedded multichannel PCM was truncated to stereo.");
  FakeMode mode; mode.width = 1280; mode.height = 720; mode.mode = bmdModeHD720p5994;
  auto flags = bmdDetectedVideoInputYCbCr422 | bmdDetectedVideoInput10BitDepth;
  auto detection = describeInput(&mode, flags);
  if (!detection.supported) return fail(error, @"Supported HDMI 720p mode was refused.");
  __block int frames = 0;
  auto callback = new CaptureCallback(mode.mode, 60000, ^(CVPixelBufferRef buffer, CMTime, BOOL) {
    if (CVPixelBufferGetWidth(buffer) == 1280) ++frames;
  }, ^(NSString *) {});
  callback->setActiveContract(*detection.contract);
  bool destroyed = false; auto frame = new FakeFrame(&destroyed);
  frame->width = 1280; frame->height = 720; frame->wrappedWidth = 1280; frame->wrappedHeight = 720; frame->rowBytes = 3456;
  callback->VideoInputFrameArrived(frame, nullptr);
  callback->Release(); frame->Release();
  if (frames != 1 || !destroyed) return fail(error, @"SDK-declared 720p frame was not admitted with owned storage.");
  mode.width = 1920; mode.height = 1080; mode.rateScale = 120000;
  if (!describeInput(&mode, flags).supported) return fail(error, @"Hardware-reported 119.88 fps was refused.");
  return YES;
}
BOOL UltracamRunPixelNegotiationSyntheticChecks(NSError **error) {
  FakeMode mode;
  struct Case { BMDDetectedVideoInputFormatFlags flags; BMDPixelFormat pixel; };
  const Case cases[] = {
    {bmdDetectedVideoInputYCbCr422 | bmdDetectedVideoInput8BitDepth, bmdFormat8BitYUV},
    {bmdDetectedVideoInputRGB444 | bmdDetectedVideoInput10BitDepth, bmdFormat10BitRGB},
    {bmdDetectedVideoInputRGB444 | bmdDetectedVideoInput12BitDepth, bmdFormat12BitRGBLE},
  };
  for (const auto &test : cases) {
    auto detected = describeInput(&mode, test.flags);
    if (!detected.supported || detected.pixel != test.pixel)
      return fail(error, @"Detected source precision was coerced to v210.");
    FakeInput input;
    auto callback = new CaptureCallback(mode.mode, 60000, nil, nil);
    const HRESULT status = reconfigureInput(&input, callback, detected);
    callback->Release();
    if (status != S_OK || input.enabledPixel != test.pixel)
      return fail(error, @"Native EnableVideoInput ignored the detected pixel format.");
  }
  __block CVPixelBufferRef held = nullptr;
  auto detected = describeInput(&mode, bmdDetectedVideoInputYCbCr422 | bmdDetectedVideoInput8BitDepth);
  auto callback = new CaptureCallback(mode.mode, 60000, ^(CVPixelBufferRef buffer, CMTime, BOOL) { held = CVPixelBufferRetain(buffer); }, ^(NSString *) {});
  callback->setActiveContract(*detected.contract);
  bool destroyed = false; auto frame = new FakeFrame(&destroyed); frame->pixel = bmdFormat8BitYUV; frame->rowBytes = 7680;
  callback->VideoInputFrameArrived(frame, nullptr); frame->Release(); callback->Release();
  if (!held || CVPixelBufferGetPixelFormatType(held) != bmdFormat8BitYUV || destroyed)
    return fail(error, @"8-bit native buffer precision or retained SDK lifetime was lost.");
  CVPixelBufferRelease(held);
  if (!destroyed) return fail(error, @"Retained 8-bit frame leaked its SDK lease.");
  return YES;
}
BOOL UltracamRunOwnedAllocatorSyntheticChecks(NSError **error) {
  auto provider = new OwnedCaptureAllocatorProvider();
  IDeckLinkVideoBufferAllocator *allocator = nullptr;
  if (provider->GetVideoBufferAllocator(256 * 16, 64, 16, 256, bmdFormat10BitRGB, &allocator) != S_OK)
    return fail(error, @"SDK allocator provider refused valid RGB packing.");
  IDeckLinkVideoBuffer *buffer = nullptr;
  if (allocator->AllocateVideoBuffer(&buffer) != S_OK) return fail(error, @"Owned page allocation failed.");
  allocator->Release(); provider->Release();
  void *pointer = nullptr; buffer->GetBytes(&pointer);
  uint64_t allocationSize = 0; buffer->GetSize(&allocationSize);
  if (!pointer || uintptr_t(pointer) % getpagesize() || allocationSize % getpagesize())
    return fail(error, @"Owned SDK allocation does not cover complete aligned pages.");
  // Synthetic driver writes into the provider allocation; production never
  // reads or copies pixels on the CPU.
  static_cast<uint8_t *>(pointer)[0] = 71;
  bool destroyed = false;
  auto frame = new FakeFrame(&destroyed);
  frame->width = 64; frame->height = 16; frame->rowBytes = 256; frame->pixel = bmdFormat10BitRGB; frame->ownedBuffer = buffer;
  auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, nil);
  callback->setActiveContract(NativeFrameContract{64, 16, CMTimeMake(1001, 60000), bmdFormat10BitRGB});
  __block UCDeckLinkOwnedMemoryFrame *held = nil;
  callback->cpuMemoryFrameHandler = ^(UCDeckLinkOwnedMemoryFrame *value, CMTime, CMTime) { held = value; };
  callback->VideoInputFrameArrived(frame, nullptr);
  frame->Release(); callback->accepting = false; callback->Release();
  if (!held || destroyed || static_cast<const uint8_t *>(held.pointer)[0] != 71)
    return fail(error, @"Owned RGB frame did not survive SDK stop/release with identical storage.");
  const uint64_t generation = held.generation;
  held = nil;
  if (!destroyed) return fail(error, @"GPU completion did not release the retained SDK frame.");
  auto next = new OwnedCaptureBuffer(4096);
  if (next->generation == generation) return fail(error, @"Allocation address reuse reused a stale generation.");
  next->Release();
  bool foreignDestroyed = false; auto foreign = new FakeFrame(&foreignDestroyed);
  auto unknown = new FakeVideoBuffer(4096);
  uint8_t foreignBytes[4096] = {}; unknown->foreignBytes = foreignBytes;
  if ([[UCDeckLinkOwnedMemoryFrame alloc] initWithFrame:foreign buffer:unknown])
    return fail(error, @"Foreign SDK pointer acquired fabricated allocation ownership.");
  unknown->Release(); foreign->Release();
  return foreignDestroyed;
}
UCDeckLinkOwnedMemoryFrame *UltracamCreateOwnedRGBFixture(void) {
  // Stable destructor sink: a fixture may outlive this function through GPU work.
  static bool destroyed;
  auto frame = new FakeFrame(&destroyed);
  frame->width = 64; frame->height = 16; frame->rowBytes = 256; frame->pixel = bmdFormat10BitRGB;
  frame->ownedBuffer = new OwnedCaptureBuffer(4096);
  UCDeckLinkOwnedMemoryFrame *owned = [[UCDeckLinkOwnedMemoryFrame alloc] initWithFrame:frame buffer:frame->ownedBuffer];
  frame->Release(); return owned;
}
UCDeckLinkOwnedMemoryFrame *UltracamCreateOwnedRGBColorFixture(uint32_t colorspace, int64_t eotf) {
  static bool destroyed;
  auto frame = new FakeFrame(&destroyed);
  frame->width = 1920; frame->height = 1080; frame->rowBytes = 7680; frame->pixel = bmdFormat10BitRGB;
  frame->ownedBuffer = new OwnedCaptureBuffer(uint32_t(frame->rowBytes * frame->height));
  frame->metadataAvailable = true; frame->metadataColorspace = colorspace; frame->metadataEOTF = eotf;
  frame->hardwareTime = 42000000;
  frame->hdrFlag = eotf > 0;
  auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, nil);
  callback->setActiveContract(NativeFrameContract{1920, 1080, CMTimeMake(1001, 60000), bmdFormat10BitRGB});
  callback->supportsColorspaceMetadata = true; callback->supportsHDRMetadata = true;
  callback->signalColorspace = bmdColorspaceRec709; callback->signalEOTF = kEOTFSDR;
  callback->stats->hostOffsetValid = true; callback->stats->hostOffsetMicros = 5000000;
  __block UCDeckLinkOwnedMemoryFrame *owned = nil;
  callback->cpuMemoryFrameHandler = ^(UCDeckLinkOwnedMemoryFrame *value, CMTime, CMTime) { owned = value; };
  callback->VideoInputFrameArrived(frame, nullptr);
  frame->Release(); callback->Release(); return owned;
}
BOOL UltracamRunOwnedColorSyntheticChecks(NSError **error) {
  UCDeckLinkOwnedMemoryFrame *sdr = UltracamCreateOwnedRGBColorFixture(bmdColorspaceRec709, kEOTFSDR);
  UCDeckLinkOwnedMemoryFrame *pq = UltracamCreateOwnedRGBColorFixture(bmdColorspaceRec2020, kEOTFPQ);
  UCDeckLinkOwnedMemoryFrame *hlg = UltracamCreateOwnedRGBColorFixture(bmdColorspaceRec2020, kEOTFHLG);
  if (![sdr.colorPrimaries isEqualToString:(__bridge NSString *)kCVImageBufferColorPrimaries_ITU_R_709_2] ||
      ![sdr.transferFunction isEqualToString:(__bridge NSString *)kCVImageBufferTransferFunction_ITU_R_709_2] ||
      ![pq.colorPrimaries isEqualToString:(__bridge NSString *)kCVImageBufferColorPrimaries_ITU_R_2020] ||
      ![pq.transferFunction isEqualToString:(__bridge NSString *)kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ] ||
      ![hlg.transferFunction isEqualToString:(__bridge NSString *)kCVImageBufferTransferFunction_ITU_R_2100_HLG] || sdr.fullRange)
    return fail(error, @"Raw RGB physical metadata differed from the SDK frame metadata.");
  UCDeckLinkOwnedMemoryFrame *unknown = UltracamCreateOwnedRGBFixture();
  if (unknown.colorPrimaries || unknown.transferFunction) return fail(error, @"Unknown raw metadata was silently replaced by Rec.709.");
  return YES;
}
BOOL UltracamRunElapsedGapSyntheticChecks(NSError **error) {
  auto skips = [](BMDTimeValue duration, BMDTimeValue gap) {
    auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, nil);
    callback->setActiveContract(NativeFrameContract{3840, 2160, CMTimeMake(duration, 60000)});
    bool destroyed = false; auto frame = new FakeFrame(&destroyed);
    frame->frameDuration = duration; frame->streamTime = 0;
    callback->VideoInputFrameArrived(frame, nullptr);
    frame->streamTime = gap; callback->VideoInputFrameArrived(frame, nullptr);
    const uint64_t drops = callback->stats->deviceDrops.load();
    frame->Release(); callback->Release(); return drops;
  };
  if (skips(2400, 720000) != 0) return fail(error, @"A 25 fps twelve-second gap was counted as missing frames instead of a discontinuity.");
  if (skips(500, 480000) != 959) return fail(error, @"A 120 fps eight-second gap was discarded by a frame-count cutoff.");
  if (skips(1001, 599 * 1001) != 598) return fail(error, @"59.94 fps behavior changed inside the ten-second gap bound.");
  if (skips(1001, 601 * 1001) != 0) return fail(error, @"59.94 fps gap beyond ten seconds was counted as device drops.");
  if (skips(1001, INT64_MAX) != 0) return fail(error, @"Timestamp gap arithmetic overflowed at Int64 maximum.");
  return YES;
}
BOOL UltracamRunConnectorSyntheticChecks(NSError **error) {
  dispatch_queue_t observers = dispatch_queue_create("org.ultracam.connector-checks", DISPATCH_QUEUE_SERIAL);
  FakeDeckLink first, second;
  first.attributes.persistentID = 0xa1; second.attributes.persistentID = 0xb2;
  first.attributes.videoInputConnections = bmdVideoConnectionHDMI | bmdVideoConnectionSDI | bmdVideoConnectionOpticalSDI;
  second.attributes.videoInputConnections = bmdVideoConnectionHDMI;
  DeviceRegistry registry(observers); registry.arrived(&first); registry.arrived(&second); registry.drain();
  if (registry.setDeviceConnector(@"decklink:00000000000000a1", bmdVideoConnectionOpticalSDI) != S_OK ||
      first.configuration.connection != bmdVideoConnectionOpticalSDI || second.configuration.connection != bmdVideoConnectionSDI)
    return fail(error, @"Per-device optical connector selection changed another device.");
  const int writes = first.configuration.writes;
  if (registry.setDeviceConnector(@"decklink:00000000000000a1", bmdVideoConnectionOpticalSDI) != S_OK || first.configuration.writes != writes)
    return fail(error, @"Same connector selection rewrote device configuration.");
  if (registry.setDeviceConnector(@"decklink:00000000000000b2", bmdVideoConnectionSDI) != E_NOINTERFACE ||
      registry.setDeviceConnector(@"decklink:missing", bmdVideoConnectionHDMI) != E_INVALIDARG)
    return fail(error, @"Unsupported or absent connector request was not refused.");
  {
    HDMILease lease;
    if (lease.select(&first, bmdVideoConnectionSDI) != S_OK) return fail(error, @"SDI lease selection failed.");
    lease.started = true;
  }
  if (first.configuration.connection != bmdVideoConnectionOpticalSDI)
    return fail(error, @"Capture lease did not restore the prior optical connector.");
  first.configuration.ignoreConnectionWrites = true;
  if (registry.setDeviceConnector(@"decklink:00000000000000a1", bmdVideoConnectionSDI) != E_FAIL)
    return fail(error, @"Connector write without hardware readback was acknowledged.");
  first.configuration.ignoreConnectionWrites = false;
  first.configuration.ignoreConnectionWrites = true;
  registry.seedInputConnectors(@{@"decklink:00000000000000a1": @(bmdVideoConnectionHDMI)});
  UCDeckLinkConnectorState *seeded = registry.connectorState(@"decklink:00000000000000a1");
  if (seeded.connection != bmdVideoConnectionHDMI || !seeded.applicationError)
    return fail(error, @"Failed bootstrapped connector write was falsely acknowledged.");
  first.configuration.ignoreConnectionWrites = false;
  if (registry.setDeviceConnector(@"decklink:00000000000000a1", bmdVideoConnectionHDMI) != S_OK ||
      registry.connectorState(@"decklink:00000000000000a1").applicationError)
    return fail(error, @"Retrying a failed saved connector did not clear its application error.");
  first.status.busy = bmdDeviceCaptureBusy;
  if (registry.setDeviceConnector(@"decklink:00000000000000a1", bmdVideoConnectionHDMI) != E_ACCESSDENIED)
    return fail(error, @"Connector changed while another application was capturing.");
  return YES;
}
BOOL UltracamRunNativeAuditSyntheticChecks(NSError **error) {
  FakeDeckLink device; device.configuration.ignoreConnectionWrites = true;
  HDMILease lease;
  if (lease.select(&device) == S_OK) return fail(error, @"Capture lease accepted a connector write without readback.");
  device.configuration.ignoreConnectionWrites = false;
  dispatch_queue_t observers = dispatch_queue_create("org.ultracam.audit-checks", DISPATCH_QUEUE_SERIAL);
  DeviceRegistry registry(observers); registry.arrived(&device); registry.drain();
  auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, nil);
  registry.attachSession(@"decklink:000000001234abcd", callback, callback->stats);
  callback->stats->setSignal(@"Detected 1920 × 1080 input");
  bool destroyed = false; auto frame = new FakeFrame(&destroyed);
  callback->VideoInputFrameArrived(frame, nullptr);
  if (![registry.diagnostics(@"decklink:000000001234abcd").signalPresent isEqual:@YES])
    return fail(error, @"Valid frame did not mark the signal present.");
  frame->noSignal = true; callback->VideoInputFrameArrived(frame, nullptr);
  if (![registry.diagnostics(@"decklink:000000001234abcd").signalPresent isEqual:@NO])
    return fail(error, @"Signal loss left stale detected-mode diagnostics.");
  frame->noSignal = false; callback->VideoInputFrameArrived(frame, nullptr);
  if (![registry.diagnostics(@"decklink:000000001234abcd").signalPresent isEqual:@YES])
    return fail(error, @"Signal recovery did not update diagnostics.");
  frame->Release(); registry.detachSession(callback); callback->Release();
  auto rgb = new CaptureCallback(bmdMode4K2160p5994, 60000, nil, nil);
  rgb->setActiveContract(NativeFrameContract{64, 16, CMTimeMake(1001, 60000), bmdFormat10BitRGB});
  rgb->stats->hostOffsetValid = true; rgb->stats->hostOffsetMicros = 5000000;
  __block UCDeckLinkOwnedMemoryFrame *owned = nil;
  rgb->cpuMemoryFrameHandler = ^(UCDeckLinkOwnedMemoryFrame *value, CMTime, CMTime) { owned = value; };
  bool rgbDestroyed = false; auto rgbFrame = new FakeFrame(&rgbDestroyed);
  rgbFrame->width = 64; rgbFrame->height = 16; rgbFrame->rowBytes = 256; rgbFrame->pixel = bmdFormat10BitRGB;
  rgbFrame->ownedBuffer = new OwnedCaptureBuffer(4096); rgbFrame->hardwareTime = 42000000;
  rgb->VideoInputFrameArrived(rgbFrame, nullptr); rgbFrame->Release(); rgb->Release();
  if (!owned.captureHostTimeSeconds || owned.captureHostTimeSeconds.doubleValue != 47.0)
    return fail(error, @"Owned RGB dropped the hardware-derived host completion timestamp.");
  return YES;
}
#endif
