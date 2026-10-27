#import "UltracamBackend.h"
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

// The DeckLink SDK 16 headers are in the repo (ThirdParty/DeckLinkSDK/include);
// every build adds them to the header search path. There is no SDK-less build.
#if !__has_include("DeckLinkAPI.h")
#error "DeckLinkAPI.h not found: add ThirdParty/DeckLinkSDK/include (or DECKLINK_SDK_DIR) to the header search path."
#endif
#include "DeckLinkAPI.h"
#include "DeckLinkAPIConfiguration.h"
#include "DeckLinkAPIVersion.h"
// Capture relies on SDK 16's IOSurface-backed input buffers (ThirdParty/DeckLinkSDK).
#if BLACKMAGIC_DECKLINK_API_VERSION < 0x10000000
#error "Ultracam requires DeckLink SDK 16.0 or later (ThirdParty/DeckLinkSDK)."
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

@interface UltracamDriverInfo ()
@property(nonatomic) BOOL installed;
@property(nonatomic) BOOL supported;
@property(nonatomic) int64_t versionValue;
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy, nullable) NSString *message;
@end
@implementation UltracamDriverInfo
@end

@interface UltracamDeviceDiagnostics ()
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

NSString *const UltracamCaptureHostTimeAttachmentKey = @"UltracamCaptureHostTime";

static os_log_t backendLog() {
  static os_log_t log = os_log_create("org.ultracam.app", "decklink");
  return log;
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
  ~HDMILease() {
    if (started) restoreConnector();
  }
  // A start that failed after select: put back the connector now, while the
  // caller still holds the device's input, so a failed claim leaves the other
  // app's HDMI setup as it found it.
  void abandon() { restoreConnector(); }
  void restoreConnector() {
    int64_t current = 0;
    if (changed && configuration && configuration->GetInt(bmdDeckLinkConfigVideoInputConnection, &current) == S_OK && current == bmdVideoConnectionHDMI)
      configuration->SetInt(bmdDeckLinkConfigVideoInputConnection, previous);
    changed = false;
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
  std::atomic<uint64_t> deviceDrops{0};
  std::atomic<uint32_t> backlog{0}, maxBacklog{0};
  std::atomic<int64_t> hostOffsetMicros{0};
  std::atomic<bool> hostOffsetValid{false};
  std::atomic<int64_t> temperature{INT64_MIN};
  std::atomic<bool> active{false};
  std::mutex textMutex;
  NSString *signal = nil;
  void reset() {
    deviceDrops = 0; backlog = 0; maxBacklog = 0; hostOffsetValid = false; temperature = INT64_MIN;
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

  NSString *read(IDeckLinkVideoInputFrame *frame, bool highFrameRate) {
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
    if (highFrameRate && !hfr) {
      observe(hours, minutes, seconds, frames);
      // Before the cadence is known a label above 29 cannot be a pair
      // counter's; show it as is, without deciding anything. Below 30, the
      // previously latched cadence (pairs if none) decides.
      const bool pairs = cadence == Cadence::pairs ||
        (cadence == Cadence::unknown && frames < 30 && previousCadence != Cadence::fullRate);
      if (pairs) frameLabel = frames * 2u + ((flags & bmdTimecodeFieldMark) ? 1u : 0u);
    }
    if (hours > 23 || minutes > 59 || seconds > 59 || frameLabel > (highFrameRate ? 59u : 29u)) return nil;
    const bool dropFrame = flags & bmdTimecodeIsDropFrame;
    const uint32_t key = (uint32_t(hours) << 19) | (uint32_t(minutes) << 13) | (uint32_t(seconds) << 7) |
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

// Audio packets from EnableAudioInput(48 kHz, 32-bit, 2 channels) are
// interleaved little-endian signed PCM. Capture always requests 32-bit integer
// samples, so the meters read the full source precision and starting a
// recording never needs an audio-format restart. DeckLink does not expose a
// byte count on IDeckLinkAudioInputPacket, so the count is derived from the
// sample-frame count and the configured stream format. Keep this helper
// bounded: a bad driver packet must never make the callback walk an
// untrusted allocation.
static void reportMedia(NSString *timecodeString, IDeckLinkAudioInputPacket *audio,
  UltracamMediaStatsHandler handler) {
  if (!handler) return;
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
  // The mode the streams last started in cleanly; bmdModeUnknown while a
  // reconfiguration is incomplete. The pixel format is always 10-bit YUV, so
  // a detection in this mode needs no restart.
  std::atomic<BMDDisplayMode> streamingMode;
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
  void (^frameHandler)(CVPixelBufferRef, CMTime, BOOL);
  UltracamMediaStatsHandler mediaHandler;
  UltracamRawAudioHandler rawAudioHandler;
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
          const bool keepFrames = detection.supported && detection.mode == streamingMode.load() && framesEnabled.load();
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
        reportFatal(@"Input changed from the selected 4K 10-bit YUV mode. Check the FX3 HDMI output and selected frame rate, then restart.");
      }
    }
    return S_OK;
  }
  HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame *frame, IDeckLinkAudioInputPacket *audioPacket) override {
    @autoreleasepool {
      if (!accepting) return S_OK;
      BMDTimeValue timestamp = 0, duration = 0;
      HRESULT timeStatus = frame ? frame->GetStreamTime(&timestamp, &duration, timeScale) : E_FAIL;
      const bool timeValid = timeStatus == S_OK && timestamp >= 0 && supportedFrameDuration(duration, timeScale);
      // Above 30 fps: 1001/60000 stream durations, or the opened mode before time is valid.
      const bool highFrameRate = timeValid ? duration * 30 < timeScale :
        requestedMode.load() == bmdMode4K2160p5994;
      if (resetTimecodeCadence.load(std::memory_order_relaxed) && resetTimecodeCadence.exchange(false)) timecodes.reset();
      // Read before the frame is delivered: a signal loss there starts the cadence over.
      NSString *timecode = mediaHandler ? timecodes.read(frame, highFrameRate) : nil;
      // The callback's video frame is wrapped and handed off first, so the
      // frame consumers (recording admission, the capture queue) never wait
      // behind the audio work. Then the callback's audio, whatever path the
      // frame took, or with no frame at all: Desktop Video can deliver an
      // audio packet while the video input is absent (for example during a
      // source reconnect), and the media path owns its own clock, so it never
      // acquires an artificial audio hole for want of a video object.
      if (frame) deliverVideo(frame, timeValid, timestamp, duration);
      if (mediaHandler) reportMedia(timecode, audioPacket, mediaHandler);
      reportRawAudio(audioPacket, rawAudioHandler);
    }
    return S_OK;
  }

  // Frame thread, from VideoInputFrameArrived only: validates the callback's
  // frame, wraps its native buffer and hands it to the frame handler (or
  // counts it as gated). Input faults are reported here; the caller reports
  // the callback's audio afterwards on every path.
  void deliverVideo(IDeckLinkVideoInputFrame *frame, bool timeValid, BMDTimeValue timestamp, BMDTimeValue duration) {
    bool valid = !(frame->GetFlags() & bmdFrameHasNoInputSource);
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
    if (frame->GetWidth() != 3840 || frame->GetHeight() != 2160 || frame->GetPixelFormat() != bmdFormat10BitYUV) {
      reportFatal([NSString stringWithFormat:@"Unsupported capture frame: %ld × %ld, pixel format 0x%08x. Requires 3840 × 2160 10-bit YUV 4:2:2.",
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
      if (frame->QueryInterface(IID_IDeckLinkVideoBuffer, reinterpret_cast<void **>(videoBuffer.out())) == S_OK &&
          videoBuffer && videoBuffer->GetSize(&size) == S_OK &&
          (rowBytes < 10240 || size < uint64_t(rowBytes) * uint64_t(frame->GetHeight()))) {
        reportFatal([NSString stringWithFormat:@"Desktop Video supplied a %llu-byte frame buffer; 3840 × 2160 v210 needs %llu bytes.",
          (unsigned long long)size, (unsigned long long)(uint64_t(std::max(rowBytes, 10240L)) * 2160)]); return;
      }
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
    if (CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_422YpCbCr10) {
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
  // restarts begin a new run; a gap of 600 frames or more is a discontinuity.
  void trackStreamTime(bool valid, BMDTimeValue timestamp, BMDTimeValue duration, bool signalReturned) {
    if (signalReturned || (resetStreamClock.load(std::memory_order_relaxed) && resetStreamClock.exchange(false)))
      lastStreamTime = -1;
    if (!valid) return;
    if (lastStreamTime >= 0 && timestamp >= lastStreamTime + 2 * duration) {
      BMDTimeValue missing = (timestamp - lastStreamTime) / duration - 1;
      if (missing > 0 && missing < 600) stats->deviceDrops.fetch_add(uint64_t(missing), std::memory_order_relaxed);
    }
    lastStreamTime = timestamp;
  }

  // HDR and colorspace metadata from the frame (manual 2.4.12.1), gated on the
  // device attributes, then the detected signal.
  void attachColorimetry(CVPixelBufferRef buffer, IDeckLinkVideoInputFrame *frame) {
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
    if (!loggedSDKColorimetry) {
      loggedSDKColorimetry = true;
      CFTypeRef existing = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nullptr);
      os_log(backendLog(), "First frame: the SDK %{public}s a transfer-function attachment; signal is %{public}@",
        existing ? "set" : "did not set", colorimetryText(colorspace, eotf));
      if (existing) CFRelease(existing);
    }
    applyColorimetry(buffer, colorspace, colorspaceFromFrame, eotf, eotfFromFrame);
  }

  // The frame's hardware reference timestamp marks when the device finished
  // receiving it (InputLoopThrough subtracts the duration for the start).
  void attachHostTime(CVPixelBufferRef buffer, IDeckLinkVideoInputFrame *frame) {
    if (!stats->hostOffsetValid.load(std::memory_order_acquire)) return;
    BMDTimeValue referenceTime = 0, referenceDuration = 0;
    if (frame->GetHardwareReferenceTimestamp(kReferenceTimeScale, &referenceTime, &referenceDuration) != S_OK ||
        referenceTime <= 0) return;
    Float64 host = Float64(referenceTime + stats->hostOffsetMicros.load(std::memory_order_relaxed)) /
      Float64(kReferenceTimeScale);
    if (!(host > 0)) return;
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &host);
    if (!number) return;
    CVBufferSetAttachment(buffer, (__bridge CFStringRef)UltracamCaptureHostTimeAttachmentKey, number,
      kCVAttachmentMode_ShouldPropagate);
    CFRelease(number);
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
    // Embedded audio is optional unless raw audio was requested. Always
    // 32-bit integer stereo: meters read the full source precision, and a
    // recording that later wants raw samples never forces a restart.
    HRESULT audioStatus = input->EnableAudioInput(bmdAudioSampleRate48kHz, bmdAudioSampleType32bitInteger, 2);
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
  if (status == S_OK) status = input->EnableVideoInput(mode.mode, bmdFormat10BitYUV, bmdVideoInputEnableFormatDetection);
  if (!callback->accepting) return E_FAIL;
  if (status == S_OK) status = input->FlushStreams();
  if (!callback->accepting) return E_FAIL;
  if (status == S_OK) {
    callback->gatedFrames.fetch_add(queued, std::memory_order_relaxed);
    callback->restartedWhileGated = true;
    callback->requestedMode = mode.mode;
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

// Process-wide: every per-feed UltracamBackend shares one discovery. Devices
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
  bool holdsAdvertisedEDID(NSString *identifier) {
    std::lock_guard<std::mutex> guard(mutex);
    for (auto &entry : entries)
      if ([entry.description.identifier isEqualToString:identifier]) return entry.edid != nullptr;
    return false;
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
    description.modes = supportedModes(input.value);
    entry.description = description;
    entry.device = owned.take();
    os_log(backendLog(), "Device arrived: %{public}@ (%{public}@)", description.name, description.identifier);
    {
      std::lock_guard<std::mutex> guard(mutex);
      entries.push_back(entry);
    }
    // Before the device is published, so no capture can start first.
    if (advertisingHDR) updateAdvertisement(device, description.identifier, description.name);
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
  void updateAdvertisement(IDeckLink *device, NSString *identifier, NSString *name) {
    bool held = false, capturing = false;
    IDeckLinkHDMIInputEDID *released = nullptr;
    const bool enabled = advertisingHDR;
    {
      std::lock_guard<std::mutex> guard(mutex);
      for (auto &entry : entries) {
        if (entry.device != device) continue;
        held = entry.edid != nullptr;
        if (!enabled) { released = entry.edid; entry.edid = nullptr; }
      }
      for (auto &session : sessions) if ([session.identifier isEqualToString:identifier]) capturing = true;
    }
    if (!enabled) {
      if (!released) return;
      released->Release();
      os_log(backendLog(), "HDR advertisement turned off: released the HDMI EDID of %{public}@ (%{public}@); the driver default returns",
        name, identifier);
      return;
    }
    if (held) return;
    // Another app capturing: rewriting the EDID would renegotiate HDMI under it.
    // Ultracam's own capture is renegotiated: the user changed the setting.
    ComRef<IDeckLinkStatus> status;
    int64_t busy = 0;
    if (!capturing && device->QueryInterface(IID_IDeckLinkStatus, reinterpret_cast<void **>(status.out())) == S_OK &&
        status && status->GetInt(bmdDeckLinkStatusBusy, &busy) == S_OK && (busy & bmdDeviceCaptureBusy)) {
      os_log(backendLog(), "%{public}@ (%{public}@) is in use by another app: its HDMI EDID was left unchanged",
        name, identifier);
      return;
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
    if (!edid) return;
    std::lock_guard<std::mutex> guard(mutex);
    for (auto &entry : entries) {
      if (entry.device != device || entry.edid) continue;
      entry.edid = edid.take();
    }
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
#include "BackendTestSupport.inc"
#endif


static const void *UltracamControlQueueKey = &UltracamControlQueueKey;

@implementation UltracamBackend {
  dispatch_queue_t _controlQueue;
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

+ (id)addDeviceListObserver:(void (^)(NSArray<UltracamDevice *> *))handler {
  return DeviceRegistry::shared().addObserver(handler);
}

+ (void)setAdvertisesHDRToCameras:(BOOL)enabled {
  DeviceRegistry::shared().setAdvertiseHDR(enabled);
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
    description.modes = supportedModes(input.value);
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
  HRESULT connectionStatus = connection->select(device.value);
  if (connectionStatus != S_OK) return fail(error, @"Cannot select the UltraStudio HDMI input. Close other capture apps, then restart.", connectionStatus);
  // The EDID is never written here: rewriting it hot-plugs HDMI and the camera
  // drops its signal for seconds. The registry advertises HDR at discovery
  // when the setting is on (DeviceRegistry::setAdvertiseHDR).
  os_log(backendLog(), "Capture start leaves the HDMI EDID unchanged: %{public}s",
    held && _registry->holdsAdvertisedEDID(deviceID) ? "SDR, PQ and HLG (advertised at discovery)" :
      "Ultracam advertises no HDR (driver default)");
  if (!capabilities.hdmiTimecode)
    os_log(backendLog(), "Device does not report HDMI timecode support; RP188 may be absent");
  os_log(backendLog(), "HDMI audio: device maximum %lld channels; capturing 2 at 32-bit",
    (long long)capabilities.maximumHDMIAudioChannels);

  BMDDisplayMode requestedMode = inputFast ? bmdMode4K2160p5994 : bmdMode4K2160p2997;
  bool supported = false;
  HRESULT status = S_OK;
  // Open the detected mode directly so a 29.97 camera does not pay a
  // Pause/Enable/Flush/Start cycle. Falls back when the status is unavailable
  // before the input is enabled.
  std::optional<DetectedInput> detected;
  if (autoFrameHandler && deviceStatus) detected = detectedStatusInput(deviceStatus.value, input.value);
  const bool openDetected = detected && detected->supported &&
    input->DoesSupportVideoMode(bmdVideoConnectionHDMI, detected->mode, bmdFormat10BitYUV,
      bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, nullptr, &supported) == S_OK && supported;
  if (openDetected) {
    requestedMode = detected->mode;
  } else {
    supported = false;
    status = input->DoesSupportVideoMode(bmdVideoConnectionHDMI, requestedMode,
      bmdFormat10BitYUV, bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, nullptr, &supported);
    if (autoFrameHandler && (status != S_OK || !supported)) {
      requestedMode = bmdMode4K2160p2997;
      status = input->DoesSupportVideoMode(bmdVideoConnectionHDMI, requestedMode,
        bmdFormat10BitYUV, bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, nullptr, &supported);
    }
    if (status != S_OK || !supported)
      return fail(error, @"UltraStudio does not support 3840 × 2160 10-bit 4:2:2 at the selected frame rate.", status);
  }
  auto callback = new CaptureCallback(requestedMode, inputFast ? 60000 : 30000, frameHandler, eventHandler,
    mediaHandler, rawAudioHandler);
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
      [NSString stringWithFormat:@"UltraStudio could not start the 4K 10-bit input (0x%08x). Check Desktop Video and HDMI settings.", (unsigned)status], status);
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
  // 3840 × 2160 10-bit check in VideoInputFrameArrived.
  callback->framesEnabled = true;
  _autoMode = std::make_shared<AutoModeMailbox>();
  auto mailbox = _autoMode;
  callback->autoFrameHandler = [frameHandler copy];
  __weak UltracamBackend *weakSelf = self;
  dispatch_queue_t nativeQueue = _controlQueue;
  callback->modeHandler = ^(DetectedInput detected, bool keepFrames) {
    if (mailbox->push(detected, keepFrames ? nullptr : &callback->framesEnabled)) {
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
  // Coalesced: at most one colorimetry refresh is queued at a time.
  auto pending = _colorimetryPending;
  const uint64_t generation = _generation;
  callback->colorimetryHandler = ^{
    if (pending->exchange(true)) return;
    dispatch_async(nativeQueue, ^{
      pending->store(false);
      UltracamBackend *owner = weakSelf;
      [owner refreshColorimetry:generation];
    });
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
      callback->eventHandler([NSString stringWithFormat:@"Unsupported HDMI input: %@. Requires 4K YUV 4:2:2 at 29.97 or 59.94 fps with at least 10-bit source precision.", current.fullDescription()]);
  } else {
    // The streams already run in this mode, and every mode is captured as
    // 10-bit YUV: only format flags changed (or a mode came back after an
    // unsupported signal), so frames are enabled again without a restart.
    bool supported = current.mode == callback->streamingMode.load();
    HRESULT status = S_OK;
    if (!supported) {
      status = _input->DoesSupportVideoMode(bmdVideoConnectionHDMI, current.mode,
        bmdFormat10BitYUV, bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, nullptr, &supported);
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
  __weak UltracamBackend *weakSelf = self;
  dispatch_queue_t nativeQueue = _controlQueue;
  const uint64_t generation = _generation;
  _notifications = std::make_unique<NotificationLease>();
  _notifications->subscribe(_device, ^(BMDNotifications topic, uint64_t parameter) {
    // Private API thread: hop to the control queue, never touch the backend here.
    dispatch_async(nativeQueue, ^{
      UltracamBackend *owner = weakSelf;
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
        current == bmdVideoConnectionHDMI) return;
    os_log(backendLog(), "Desktop Video preferences moved the input to connection 0x%llx; reselecting HDMI",
      (unsigned long long)current);
    if (lease->configuration->SetInt(bmdDeckLinkConfigVideoInputConnection, bmdVideoConnectionHDMI) == S_OK) {
      // Restore the outside choice when this session ends.
      lease->previous = current; lease->changed = true;
      _callback->eventHandler(@"Desktop Video settings changed the UltraStudio input. Ultracam reselected HDMI for this session.");
    }
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
  __weak UltracamBackend *weakSelf = self;
  const uint64_t generation = _generation;
  _pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _controlQueue);
  dispatch_source_set_timer(_pollTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
  dispatch_source_set_event_handler(_pollTimer, ^{
    UltracamBackend *owner = weakSelf;
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

// A format notification at the running mode (format flags only) keeps frames
// flowing without a restart. A real mode change restarts the streams, and
// the frames it gated or flushed are device drops, since the restarted stream
// clock cannot show them as a gap.
- (BOOL)runFormatChangeChecks:(NSError **)error {
  FakeInput input;
  struct StopGuard {
    __unsafe_unretained UltracamBackend *owner;
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
    bmdDetectedVideoInputYCbCr422 | bmdDetectedVideoInput8BitDepth);
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
  __unsafe_unretained UltracamBackend *owner = self;
  if (dispatch_get_specific(UltracamControlQueueKey) == (__bridge void *)self) [self stopOnQueue];
  else dispatch_sync(_controlQueue, ^{ [owner stopOnQueue]; });
}
@end

#if defined(ULTRACAM_BACKEND_TESTING)
BOOL UltracamRunOwnershipSyntheticChecks(NSError **error) {
  UltracamBackend *backend = [UltracamBackend new];
  return [backend runOwnershipChecks:error];
}

BOOL UltracamRunSDK16SyntheticChecks(NSError **error) {
  if (!runFrameFeatureChecks(error)) return NO;
  UltracamBackend *backend = [UltracamBackend new];
  return [backend runSDK16Checks:error];
}

BOOL UltracamRunAutoSyntheticChecks(NSError **error) {
  UltracamBackend *backend = [UltracamBackend new];
  if (![backend runAutoChecks:error]) return NO;
  UltracamBackend *formatChanges = [UltracamBackend new];
  return [formatChanges runFormatChangeChecks:error];
}
#endif

#include "SonyCameraControl.inc"
