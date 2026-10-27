// Included in the native backend so existing command-line harnesses keep a
// complete bridge. Only the app target opts into Sony's locally installed SDK.
#import "SonyCameraControl.h"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>
#include <arpa/inet.h>
#if ULTRACAM_SONY_SDK
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wignored-qualifiers"
#pragma clang diagnostic ignored "-Wreorder-ctor"
#pragma clang diagnostic ignored "-Wunknown-pragmas"
#pragma clang diagnostic ignored "-Wunused-parameter"
#include "CameraRemote_SDK.h"
#include "IDeviceCallback.h"
#pragma clang diagnostic pop
#include "SonyNetworkDiscovery.inc"

namespace {
using namespace SCRSDK;
struct SonyField { uint32_t code; const char *key; const char *title; bool editable; };
static const SonyField sonyFields[] = {
  {CrDeviceProperty_IsoSensitivity, "iso", "ISO", true},
  {CrDeviceProperty_FNumber, "aperture", "Aperture", true},
  {CrDeviceProperty_ShutterSpeed, "shutter", "Shutter speed", true},
  {CrDeviceProperty_ShutterAngle, "shutterAngle", "Shutter angle", true},
  {CrDeviceProperty_ExposureBiasCompensation, "exposure", "Exposure compensation", true},
  {CrDeviceProperty_ExposureProgramMode, "exposureMode", "Exposure mode", true},
  {CrDeviceProperty_WhiteBalance, "whiteBalance", "White balance", true},
  {CrDeviceProperty_Colortemp, "temperature", "Color temperature", true},
  {CrDeviceProperty_FocusMode, "focusMode", "Focus mode", true},
  {CrDeviceProperty_FocusArea, "focusArea", "Focus area", true},
  {CrDeviceProperty_Movie_Recording_FrameRateSetting, "frameRate", "Movie recording frame rate", true},
  {CrDeviceProperty_SQRecordingFrameRateSetting, "sqFrameRate", "S&Q recording frame rate", true},
  {CrDeviceProperty_Movie_HDMIOutputResolution, "hdmiResolution", "HDMI output resolution", true},
  {CrDeviceProperty_Movie_HDMIOutput4KSetting, "hdmiOutput4K", "HDMI 4K output timing", true},
  {CrDeviceProperty_Movie_HDMIOutputRawSetting, "hdmiRawFrameRate", "HDMI RAW frame rate", true},
  {CrDeviceProperty_FaceEyeFrameDisplay, "faceEyeFrameDisplay", "Face/Eye frames in HDMI", true},
  {CrDeviceProperty_MonitoringOutputDisplayHDMI, "monitoringDisplayHDMI", "HDMI camera display", true},
  {CrDeviceProperty_SubjectRecognitionAF, "subjectRecognition", "Subject recognition AF", true},
  {CrDeviceProperty_SubjectRecognitionInAF, "recognitionInAF", "Subject recognition in AF", true},
  {CrDeviceProperty_RecognitionTarget, "recognitionTarget", "Recognition target", true},
  {CrDeviceProperty_RightLeftEyeSelect, "eyeSelection", "Eye selection", true},
  {CrDeviceProperty_AFTransitionSpeed, "afTransitionSpeed", "AF transition speed", true},
  {CrDeviceProperty_AFSubjShiftSens, "afSubjectShiftSensitivity", "AF subject shift sensitivity", true},
  {CrDeviceProperty_AFTrackingSensitivity, "afTrackingSensitivity", "AF tracking sensitivity (still)", true},
  {CrDeviceProperty_PriorityKeySettings, "priority", "Control priority", true},
  {CrDeviceProperty_GainBaseIsoSensitivity, "baseISO", "Base ISO level", true},
  {CrDeviceProperty_ExposureIndex, "exposureIndex", "Exposure index", true},
  {CrDeviceProperty_IsoCurrentSensitivity, "actualISO", "Current ISO", false},
  {CrDeviceProperty_BatteryRemain, "battery", "Battery", false},
  {CrDeviceProperty_FocusIndication, "focusStatus", "Focus status", false},
  {CrDeviceProperty_FocusPositionCurrentValue, "focusPosition", "Focus position", false},
  {CrDeviceProperty_RecordingState, "recording", "Camera recording state", false},
};
static const SonyField *sonyField(uint32_t code) {
  for (const auto &f : sonyFields) if (f.code == code) return &f;
  return nullptr;
}
static NSString *sonyString(const char *s) { return s ? [NSString stringWithUTF8String:s] ?: @"" : @""; }
static bool sonyParseIPv4(NSString *text, uint32_t &address) {
  NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  struct in_addr parsed = {};
  if (inet_pton(AF_INET, trimmed.UTF8String, &parsed) != 1) return false;
  uint32_t host = ntohl(parsed.s_addr);
  // Only a camera's unicast address is meaningful; retain link-local support.
  if ((host >> 24) == 0 || (host >> 24) == 127 || (host >> 24) >= 224) return false;
  address = parsed.s_addr; // SDK byte layout: 192.168.1.160 -> 0xA001A8C0.
  return true;
}
static bool sonyParseMAC(NSString *text, uint8_t (&bytes)[6], NSString **normalized) {
  NSString *compact = [[[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
    stringByReplacingOccurrencesOfString:@":" withString:@""] stringByReplacingOccurrencesOfString:@"-" withString:@""];
  if (compact.length != 12) return false;
  unsigned nonzero = 0;
  for (NSUInteger i = 0; i < 6; ++i) {
    unsigned value = 0;
    for (NSUInteger j = 0; j < 2; ++j) {
      unichar c = [compact characterAtIndex:i * 2 + j];
      unsigned nibble;
      if (c >= '0' && c <= '9') nibble = c - '0';
      else if (c >= 'a' && c <= 'f') nibble = c - 'a' + 10;
      else if (c >= 'A' && c <= 'F') nibble = c - 'A' + 10;
      else return false;
      value = value * 16 + nibble;
    }
    bytes[i] = (uint8_t)value; nonzero |= value;
  }
  if (!nonzero || (bytes[0] & 1)) return false;
  if (normalized) *normalized = [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x",
    bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]];
  return true;
}
static NSArray<NSDictionary *> *sonyDeduplicateCandidates(NSArray<NSDictionary *> *records,
  const std::map<std::string, NSDictionary *> &previousRecords) {
  NSMutableDictionary<NSString *, NSDictionary *> *unique = [NSMutableDictionary new];
  for (NSDictionary *record in records) {
    uint8_t bytes[6] = {}; NSString *identity = nil;
    if (!sonyParseMAC(record[@"mac"], bytes, &identity)) continue;
    NSDictionary *existing = unique[identity];
    auto prior = previousRecords.find(identity.UTF8String);
    NSString *preferredAddress = prior == previousRecords.end() ? nil : prior->second[@"address"];
    if (!existing || ([record[@"address"] isEqualToString:preferredAddress] &&
        ![existing[@"address"] isEqualToString:preferredAddress])) unique[identity] = record;
  }
  return unique.allValues;
}
static NSString *sonyError(const char *operation, CrError error) {
  return [NSString stringWithFormat:@"Sony %s failed (0x%08X). Check remote shooting, camera permissions and Wi-Fi, then retry.", operation, error];
}
static NSString *sonyLabel(uint32_t code, uint64_t v) {
  switch (code) {
    case CrDeviceProperty_SubjectRecognitionAF:
      switch (v) { case CrSubjectRecognitionAF_Off: return @"Off";
        case CrSubjectRecognitionAF_OnlyAF: return @"Recognized subjects only";
        case CrSubjectRecognitionAF_PriorityAF: return @"Subject priority"; } break;
    case CrDeviceProperty_SubjectRecognitionInAF:
      if (v == CrSubjectRecognitionInAF_Off) return @"Off";
      if (v == CrSubjectRecognitionInAF_On) return @"On";
      break;
    case CrDeviceProperty_RecognitionTarget:
      switch (v) { case CrRecognitionTarget_Auto: return @"Auto";
        case CrRecognitionTarget_Person: return @"Person";
        case CrRecognitionTarget_AnimalBird: return @"Animal/bird";
        case CrRecognitionTarget_Animal: return @"Animal"; case CrRecognitionTarget_Bird: return @"Bird";
        case CrRecognitionTarget_Insect: return @"Insect"; case CrRecognitionTarget_CarTrain: return @"Car/train";
        case CrRecognitionTarget_Plane: return @"Airplane"; } break;
    case CrDeviceProperty_RightLeftEyeSelect:
      switch (v) { case CrRightLeftEyeSelect_Auto: return @"Auto";
        case CrRightLeftEyeSelect_RightEye: return @"Right eye"; case CrRightLeftEyeSelect_LeftEye: return @"Left eye"; } break;
    case CrDeviceProperty_AFTrackingSensitivity:
      if (v == CrAFTrackingSensitivity_1) return @"1 (Locked on)";
      if (v == CrAFTrackingSensitivity_3) return @"3 (Standard)";
      if (v == CrAFTrackingSensitivity_5) return @"5 (Responsive)";
      break;
    case CrDeviceProperty_FNumber:
      if (v == CrFnumber_IrisClose) return @"Closed";
      if (v >= CrFnumber_Unknown || v == 0) return @"—";
      return [NSString stringWithFormat:@"ƒ/%.3g", v / 100.0];
    case CrDeviceProperty_IsoSensitivity: case CrDeviceProperty_IsoCurrentSensitivity:
      if ((v & 0xFFFFFF) == CrISO_AUTO) return @"Auto";
      return [NSString stringWithFormat:@"%llu%@", (unsigned long long)(v & 0xFFFFFF), (v & 0xF0000000) ? @" (extended)" : @""];
    case CrDeviceProperty_ShutterSpeed:
      if (v == CrShutterSpeed_Nothing) return @"—";
      if (v == CrShutterSpeed_Bulb) return @"Bulb";
      if (!(v & 0xFFFF)) return @"—";
      return (v >> 16) == 1 ? [NSString stringWithFormat:@"1/%llu s", (unsigned long long)(v & 0xFFFF)] :
        [NSString stringWithFormat:@"%.4g s", (double)(v >> 16) / (v & 0xFFFF)];
    case CrDeviceProperty_ShutterAngle: return v ? [NSString stringWithFormat:@"%.3g°", v / 1000.0] : @"Off";
    case CrDeviceProperty_ExposureBiasCompensation: return [NSString stringWithFormat:@"%+.2f EV", (int16_t)v / 1000.0];
    case CrDeviceProperty_Colortemp: return [NSString stringWithFormat:@"%llu K", (unsigned long long)v];
    case CrDeviceProperty_BatteryRemain: return v <= 100 ? [NSString stringWithFormat:@"%llu%%", (unsigned long long)v] : @"Unknown";
    case CrDeviceProperty_GainBaseIsoSensitivity:
      if (v == CrGainBaseIsoSensitivity_High) return @"High";
      if (v == CrGainBaseIsoSensitivity_Low) return @"Low";
      break;
    case CrDeviceProperty_ExposureIndex: return [NSString stringWithFormat:@"%llu EI", (unsigned long long)v];
    case CrDeviceProperty_RecordingState:
      switch (v) {
        case CrMovie_Recording_State_Not_Recording: return @"Standby";
        case CrMovie_Recording_State_Recording: return @"Recording";
        case CrMovie_Recording_State_Recording_Failed: return @"Recording failed";
        case CrMovie_Recording_State_IntervalRec_Waiting_Record: return @"Interval recording: waiting";
      } break;
    case CrDeviceProperty_FocusIndication:
      switch (v) {
        case CrFocusIndicator_Unlocked: return @"Unlocked";
        case CrFocusIndicator_Focused_AF_S: case CrFocusIndicator_Focused_AF_C: return @"Focused";
        case CrFocusIndicator_NotFocused_AF_S: case CrFocusIndicator_NotFocused_AF_C: return @"Not focused";
        case CrFocusIndicator_TrackingSubject_AF_C: return @"Tracking subject";
        case CrFocusIndicator_Unpause: return @"Active"; case CrFocusIndicator_Pause: return @"Paused";
      } break;
    case CrDeviceProperty_PriorityKeySettings:
      if (v == CrPriorityKey_PCRemote) return @"Remote control";
      if (v == CrPriorityKey_CameraPosition) return @"Camera controls";
      break;
    case CrDeviceProperty_FocusMode: {
      switch (v) {
        case CrFocus_MF: return @"MF"; case CrFocus_AF_S: return @"AF-S";
        case CrFocus_AF_C: return @"AF-C"; case CrFocus_AF_A: return @"AF-A";
        case CrFocus_AF_D: return @"AF-D"; case CrFocus_DMF: return @"DMF";
        case CrFocus_PF: return @"Preset focus";
      } break;
    }
    case CrDeviceProperty_WhiteBalance: {
      switch (v) {
        case CrWhiteBalance_AWB: return @"Auto"; case CrWhiteBalance_Daylight: return @"Daylight";
        case CrWhiteBalance_Shadow: return @"Shade"; case CrWhiteBalance_Cloudy: return @"Cloudy";
        case CrWhiteBalance_Tungsten: return @"Tungsten"; case CrWhiteBalance_Flush: return @"Flash";
        case CrWhiteBalance_ColorTemp: return @"Color temperature";
        case CrWhiteBalance_Custom_1: return @"Custom 1"; case CrWhiteBalance_Custom_2: return @"Custom 2";
        case CrWhiteBalance_Custom_3: return @"Custom 3"; case CrWhiteBalance_Custom: return @"Custom";
        case CrWhiteBalance_Underwater_Auto: return @"Underwater auto";
        case CrWhiteBalance_Fluorescent: return @"Fluorescent";
        case CrWhiteBalance_Fluorescent_WarmWhite: return @"Fluorescent warm white";
        case CrWhiteBalance_Fluorescent_CoolWhite: return @"Fluorescent cool white";
        case CrWhiteBalance_Fluorescent_DayWhite: return @"Fluorescent day white";
        case CrWhiteBalance_Fluorescent_Daylight: return @"Fluorescent daylight";
      } break;
    }
    case CrDeviceProperty_FocusArea: {
      switch (v) {
        case CrFocusArea_Wide: return @"Wide"; case CrFocusArea_Zone: return @"Zone";
        case CrFocusArea_Center: return @"Center";
        case CrFocusArea_Flexible_Spot_S: return @"Spot S"; case CrFocusArea_Flexible_Spot_M: return @"Spot M";
        case CrFocusArea_Flexible_Spot_L: return @"Spot L"; case CrFocusArea_Flexible_Spot: return @"Spot";
        case CrFocusArea_Expand_Flexible_Spot: return @"Expanded spot";
        case CrFocusArea_Tracking_Wide: return @"Tracking: wide"; case CrFocusArea_Tracking_Zone: return @"Tracking: zone";
        case CrFocusArea_Tracking_Center: return @"Tracking: center";
        case CrFocusArea_Tracking_Flexible_Spot_S: return @"Tracking: spot S";
        case CrFocusArea_Tracking_Flexible_Spot_M: return @"Tracking: spot M";
        case CrFocusArea_Tracking_Flexible_Spot_L: return @"Tracking: spot L";
        case CrFocusArea_Tracking_Expand_Flexible_Spot: return @"Tracking: expanded spot";
      } break;
    }
    case CrDeviceProperty_FaceEyeFrameDisplay:
      if (v == CrFaceEyeFrameDisplay_On) return @"On";
      if (v == CrFaceEyeFrameDisplay_Off) return @"Off";
      break;
    case CrDeviceProperty_MonitoringOutputDisplayHDMI:
      if (v == CrMonitoringOutputDisplayHDMI_On) return @"On";
      if (v == CrMonitoringOutputDisplayHDMI_Off) return @"Off";
      break;
    case CrDeviceProperty_ExposureProgramMode: {
      switch (v) {
        case CrExposure_M_Manual: case CrExposure_Movie_M: return @"Manual";
        case CrExposure_P_Auto: case CrExposure_Movie_P: return @"Program auto";
        case CrExposure_A_AperturePriority: case CrExposure_Movie_A: return @"Aperture priority";
        case CrExposure_S_ShutterSpeedPriority: case CrExposure_Movie_S: return @"Shutter priority";
        case CrExposure_Movie_F: case CrExposure_F_MovieOrSQMotion: return @"Flexible exposure";
        case CrExposure_MemoryRecall: return @"Memory recall";
      } break;
    }
    case CrDeviceProperty_Movie_Recording_FrameRateSetting:
      switch (v) {
        case CrRecordingFrameRateSettingMovie_120p: return @"120p";
        case CrRecordingFrameRateSettingMovie_100p: return @"100p";
        case CrRecordingFrameRateSettingMovie_60p: return @"60p";
        case CrRecordingFrameRateSettingMovie_50p: return @"50p";
        case CrRecordingFrameRateSettingMovie_30p: return @"30p";
        case CrRecordingFrameRateSettingMovie_25p: return @"25p";
        case CrRecordingFrameRateSettingMovie_24p: return @"24p";
        case CrRecordingFrameRateSettingMovie_23_98p: return @"23.98p";
        case CrRecordingFrameRateSettingMovie_29_97p: return @"29.97p";
        case CrRecordingFrameRateSettingMovie_59_94p: return @"59.94p";
        case CrRecordingFrameRateSettingMovie_24_00p: return @"24.00p";
        case CrRecordingFrameRateSettingMovie_119_88p: return @"119.88p";
      } break;
    case CrDeviceProperty_SQRecordingFrameRateSetting:
      switch (v) {
        case CrRecordingFrameRateSettingMovie_120p: return @"120p";
        case CrRecordingFrameRateSettingMovie_100p: return @"100p";
        case CrRecordingFrameRateSettingMovie_60p: return @"60p";
        case CrRecordingFrameRateSettingMovie_50p: return @"50p";
        case CrRecordingFrameRateSettingMovie_30p: return @"30p";
        case CrRecordingFrameRateSettingMovie_25p: return @"25p";
        case CrRecordingFrameRateSettingMovie_24p: return @"24p";
        case CrRecordingFrameRateSettingMovie_23_98p: return @"23.98p";
        case CrRecordingFrameRateSettingMovie_29_97p: return @"29.97p";
        case CrRecordingFrameRateSettingMovie_59_94p: return @"59.94p";
        case CrRecordingFrameRateSettingMovie_24_00p: return @"24.00p";
        case CrRecordingFrameRateSettingMovie_119_88p: return @"119.88p";
      } break;
    case CrDeviceProperty_Movie_HDMIOutputResolution:
      switch (v) {
        case CrHDMIResolution_4320p_2160p: return @"4320p/2160p";
        case CrHDMIResolution_2160p: return @"2160p";
        case CrHDMIResolution_2160p_1080p: return @"2160p/1080p";
        case CrHDMIResolution_1080p: return @"1080p";
        case CrHDMIResolution_720p: return @"720p";
        case CrHDMIResolution_480p: return @"480p";
        case CrHDMIResolution_576p: return @"576p";
        case CrHDMIResolution_1080i: return @"1080i";
        case CrHDMIResolution_480i: return @"480i";
        case CrHDMIResolution_576i: return @"576i";
        case CrHDMIResolution_Auto: return @"Auto";
      } break;
    case CrDeviceProperty_Movie_HDMIOutput4KSetting:
      switch (v) {
        case CrHDMIOutput4KSettingMovie_59_94p_10bit: return @"59.94p · 10-bit";
        case CrHDMIOutput4KSettingMovie_50_00p_10bit: return @"50.00p · 10-bit";
        case CrHDMIOutput4KSettingMovie_29_97p_10bit: return @"29.97p · 10-bit";
        case CrHDMIOutput4KSettingMovie_25_00p_10bit: return @"25.00p · 10-bit";
        case CrHDMIOutput4KSettingMovie_24_00p_10bit: return @"24.00p · 10-bit";
        case CrHDMIOutput4KSettingMovie_23_98p_10bit: return @"23.98p · 10-bit";
        case CrHDMIOutput4KSettingMovie_59_94p_8bit: return @"59.94p · 8-bit";
        case CrHDMIOutput4KSettingMovie_50_00p_8bit: return @"50.00p · 8-bit";
        case CrHDMIOutput4KSettingMovie_29_97p_8bit: return @"29.97p · 8-bit";
        case CrHDMIOutput4KSettingMovie_25_00p_8bit: return @"25.00p · 8-bit";
        case CrHDMIOutput4KSettingMovie_23_98p_8bit: return @"23.98p · 8-bit";
      } break;
    case CrDeviceProperty_Movie_HDMIOutputRawSetting:
      switch (v) {
        case CrHDMIOutputRawSettingMovie_59_94p: return @"59.94p";
        case CrHDMIOutputRawSettingMovie_50_00p: return @"50.00p";
        case CrHDMIOutputRawSettingMovie_29_97p: return @"29.97p";
        case CrHDMIOutputRawSettingMovie_25_00p: return @"25.00p";
        case CrHDMIOutputRawSettingMovie_24_00p: return @"24.00p";
        case CrHDMIOutputRawSettingMovie_23_98p: return @"23.98p";
      } break;
  }
  return [NSString stringWithFormat:@"%llu", (unsigned long long)v];
}
static size_t sonyWidth(CrDataType type) {
  switch (type & 0xFFF) { case 1: return 1; case 2: return 2; case 3: return 4; case 4: return 8; default: return 0; }
}
static std::vector<uint64_t> sonyDecodeChoices(CrDataType type, const uint8_t *bytes, size_t size) {
  std::vector<uint64_t> result;
  size_t width = sonyWidth(type);
  if (!width) return result;
  if (!bytes || size > 65536 || size % width) return result;
  for (size_t i = 0; i < size; i += width) {
    uint64_t value = 0; memcpy(&value, bytes + i, width);
    if ((type & CrDataType_SignBit) && width < 8 && (value & (1ULL << (width * 8 - 1)))) value |= (~0ULL << (width * 8));
    result.push_back(value);
  }
  if (type & CrDataType_RangeBit) {
    if (result.size() != 3 || !result[2]) return {};
    uint64_t low = result[0], high = result[1], step = result[2];
    if (type & CrDataType_SignBit) {
      if ((int64_t)high < (int64_t)low || (int64_t)step <= 0) return {};
    } else if (high < low) return {};
    uint64_t distance = high - low; // Unsigned subtraction also handles signed ranges crossing zero.
    if (distance / step > 1023) return {};
    result.clear();
    for (uint64_t offset = 0; offset <= distance; offset += step) {
      result.push_back(low + offset); if (distance - offset < step) break;
    }
  }
  return result;
}
static std::vector<uint64_t> sonyChoices(const CrDeviceProperty &p) {
  // Sony documents GetValues as the settable list. GetSetValues is reserved.
  return sonyDecodeChoices(p.GetValueType(), p.GetValues(), p.GetValueSize());
}
class SonyCallback final : public IDeviceCallback, public std::enable_shared_from_this<SonyCallback> {
public:
  std::mutex mutex;
  std::condition_variable condition;
  bool connected = false, disconnected = false;
  uint32_t error = 0;
  uint64_t revision = 0;
  std::atomic<bool> dirty{false};
  void (^event)(NSString *, NSString *);
  void (^afterDisconnect)() = nil;
  explicit SonyCallback(void (^handler)(NSString *, NSString *)) : event([handler copy]) {}
  void OnConnected(DeviceConnectionVersioin) override {
    std::lock_guard<std::mutex> lock(mutex); connected = true; condition.notify_all();
  }
  void OnDisconnected(CrInt32u e) override {
    // Signalling can wake the owner and release its session immediately. Keep
    // this callback alive through the remaining event/cleanup block accesses.
    auto keepAlive = weak_from_this().lock();
    { std::lock_guard<std::mutex> lock(mutex); disconnected = true; connected = false; error = e;
      condition.notify_all(); }
    event(@"disconnected", e ? sonyError("connection", e) : @"Disconnected");
    if (afterDisconnect) afterDisconnect();
  }
  void OnError(CrInt32u e) override {
    auto keepAlive = weak_from_this().lock();
    { std::lock_guard<std::mutex> lock(mutex); error = e; condition.notify_all(); }
    event(@"error", sonyError("operation", e));
  }
  void changed() {
    auto keepAlive = weak_from_this().lock();
    { std::lock_guard<std::mutex> lock(mutex); ++revision; condition.notify_all(); }
    if (!dirty.exchange(true)) event(@"changed", @"Settings changed on the camera. Updating…");
  }
  void OnPropertyChanged() override { changed(); }
  void OnPropertyChangedCodes(CrInt32u count, CrInt32u *codes) override {
    for (uint32_t i = 0; codes && i < count; ++i) {
      const auto *field = sonyField(codes[i]);
      // Ignore continuous AF telemetry; include exposure readouts, battery and
      // recording status so ordinary camera state stays current automatically.
      if (field && codes[i] != CrDeviceProperty_FocusIndication &&
          codes[i] != CrDeviceProperty_FocusPositionCurrentValue) { changed(); return; }
    }
  }
};
struct SonySession {
  CrDeviceHandle handle = 0;
  std::shared_ptr<SonyCallback> callback;
  std::shared_ptr<ICrEnumCameraObjectInfo> enumeration;
  std::shared_ptr<ICrCameraObjectInfo> directInfo;
  std::string cameraID;
};
struct SonyState {
  bool initialized = false;
  std::shared_ptr<ICrEnumCameraObjectInfo> enumeration;
  bool manualMode = false;
  std::map<std::string, std::shared_ptr<ICrCameraObjectInfo>> manualInfos;
  std::map<std::string, NSDictionary *> cameraRecords;
  std::map<std::string, SonySession> sessions;
};

static bool sonyCloseSession(SonySession &session) {
  if (!session.handle) return true;
  bool disconnected;
  { std::lock_guard<std::mutex> lock(session.callback->mutex); disconnected = session.callback->disconnected; }
  if (!disconnected) {
    SCRSDK::Disconnect(session.handle);
    std::unique_lock<std::mutex> lock(session.callback->mutex);
    session.callback->condition.wait_for(lock, std::chrono::seconds(3), [&] { return session.callback->disconnected; });
    disconnected = session.callback->disconnected;
  }
  // Sony forbids ReleaseDevice before OnDisconnected. A timeout is not an
  // acknowledgement: keep the callback and handle alive until it arrives.
  if (!disconnected) return false;
  SCRSDK::ReleaseDevice(session.handle);
  session.handle = 0;
  return true;
}

/// Dispatch queues may change OS threads; Sony requires Release on the exact
/// thread that called Init. One sleeping worker owns the process-global SDK.
class SonyRuntime {
  std::mutex mutex;
  std::condition_variable condition;
  std::deque<dispatch_block_t> tasks;
  bool initialized = false;
  size_t owners = 0;
  std::vector<std::unique_ptr<SonyState>> retired;
  void releaseIfIdle() {
    if (initialized && owners == 0 && retired.empty()) { SCRSDK::Release(); initialized = false; }
  }
  bool finish(SonyState &state) {
    bool complete = true;
    for (auto &entry : state.sessions) if (!sonyCloseSession(entry.second)) complete = false;
    if (!complete) return false;
    state.sessions.clear();
    state.enumeration.reset();
    state.manualInfos.clear();
    state.cameraRecords.clear();
    state.manualMode = false;
    if (state.initialized) { state.initialized = false; --owners; }
    return true;
  }
public:
  SonyRuntime() {
    std::thread([this] {
      for (;;) {
        dispatch_block_t task;
        {
          std::unique_lock<std::mutex> lock(mutex);
          condition.wait(lock, [&] { return !tasks.empty(); });
          task = tasks.front(); tasks.pop_front();
        }
        @autoreleasepool { task(); }
      }
    }).detach();
  }
  void enqueue(dispatch_block_t task) {
    { std::lock_guard<std::mutex> lock(mutex); tasks.push_back([task copy]); }
    condition.notify_one();
  }
  bool initialize(SonyState &state) {
    if (state.initialized) return true;
    if (!initialized) initialized = SCRSDK::Init(0);
    if (initialized) { state.initialized = true; ++owners; }
    return state.initialized;
  }
  bool shutdown(SonyState &state) {
    bool complete = finish(state);
    // A previously retired wrapper may still hold a handle while waiting for
    // Sony's asynchronous OnDisconnected acknowledgement. Do not claim SDK
    // shutdown until those handles have also been reaped.
    reap();
    releaseIfIdle();
    return complete && retired.empty();
  }
  void retire(SonyState *state) {
    std::unique_ptr<SonyState> owned(state);
    if (!finish(*owned)) retired.push_back(std::move(owned));
    releaseIfIdle();
  }
  void reap() {
    for (auto it = retired.begin(); it != retired.end();) {
      // A disconnect callback schedules this method. Do not repeat waits on
      // unrelated pending handles; only reap when every handle acknowledged.
      bool ready = true;
      for (auto &entry : (*it)->sessions) {
        std::lock_guard<std::mutex> lock(entry.second.callback->mutex);
        if (entry.second.handle && !entry.second.callback->disconnected) ready = false;
      }
      if (ready && finish(**it)) it = retired.erase(it); else ++it;
    }
    releaseIfIdle();
  }
};
static SonyRuntime &sonyRuntime() {
  // The executor itself lives until process exit; its thread sleeps without
  // polling. SDK sessions and Init/Release resources still have normal lifetimes.
  static SonyRuntime *runtime = new SonyRuntime();
  return *runtime;
}
}
#endif

@implementation UCSonyCameraControl {
  dispatch_queue_t _sonyQueue;
#if ULTRACAM_SONY_SDK
  std::unique_ptr<SonyState> _sony;
#endif
}
- (instancetype)init {
  if ((self = [super init])) {
    _sonyQueue = dispatch_queue_create("org.ultracam.sony-control", DISPATCH_QUEUE_SERIAL);
#if ULTRACAM_SONY_SDK
    _sony = std::make_unique<SonyState>();
#endif
  }
  return self;
}
- (BOOL)available {
#if ULTRACAM_SONY_SDK
  return YES;
#else
  return NO;
#endif
}
- (void)enqueueSony:(dispatch_block_t)task {
#if ULTRACAM_SONY_SDK
  sonyRuntime().enqueue(task);
#else
  dispatch_async(_sonyQueue, task);
#endif
}
- (void)reply:(UCSonyReply)reply object:(id)object error:(NSString *)error {
  NSString *json = nil;
  if (object) {
    NSError *encodingError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&encodingError];
    if (data) json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    else error = encodingError.localizedDescription;
  }
  dispatch_async(dispatch_get_main_queue(), ^{ reply(json, error); });
}
#if ULTRACAM_SONY_SDK
- (BOOL)initializeSony:(UCSonyReply)reply {
  sonyRuntime().initialize(*_sony);
  if (!_sony->initialized) [self reply:reply object:nil error:@"Sony SDK initialization failed. Check that the SDK and CrAdapter libraries are embedded in the app."];
  return _sony->initialized;
}
- (NSString *)cameraIdentity:(const SCRSDK::ICrCameraObjectInfo *)info {
  return [sonyString(info->GetMACAddressChar()) lowercaseString];
}
- (BOOL)closeSession:(SonySession &)session {
  return sonyCloseSession(session);
}
- (void)purgeDisconnectedSessions {
  for (auto it = _sony->sessions.begin(); it != _sony->sessions.end();) {
    bool closed = !it->second.handle;
    {
      std::lock_guard<std::mutex> lock(it->second.callback->mutex);
      closed = closed || it->second.callback->disconnected;
    }
    if (closed && sonyCloseSession(it->second)) it = _sony->sessions.erase(it); else ++it;
  }
}
- (NSArray *)propertiesFor:(SonySession &)session error:(NSString **)error {
  using namespace SCRSDK;
  if (!session.handle) { *error = @"The Sony camera handle is no longer valid."; return nil; }
  {
    std::lock_guard<std::mutex> lock(session.callback->mutex);
    if (session.callback->disconnected) {
      *error = @"The Sony camera is disconnected.";
      return nil;
    }
  }
  // Re-arm invalidation before reading. An event arriving during the snapshot
  // must remain visible; clearing at the end could swallow a concurrent change.
  session.callback->dirty = false;
  CrDeviceProperty *properties = nullptr; CrInt32 count = 0;
  auto result = GetDeviceProperties(session.handle, &properties, &count);
  if (result) { if (properties) ReleaseDeviceProperties(session.handle, properties); *error = sonyError("refresh", result); return nil; }
  NSMutableArray *fields = [NSMutableArray array];
  for (const auto &field : sonyFields) {
    for (CrInt32 i = 0; properties && i < count; ++i) {
      const auto &p = properties[i];
      if (p.GetCode() != field.code || !p.IsGetEnableCurrentValue()) continue;
      NSMutableArray *choices = [NSMutableArray array];
      if (field.editable && p.IsSetEnableCurrentValue()) {
        for (auto value : sonyChoices(p)) [choices addObject:@{@"value": @(value), @"label": sonyLabel(field.code, value)}];
      }
      [fields addObject:@{@"id": sonyString(field.key), @"title": sonyString(field.title), @"code": @(field.code),
        @"value": @(p.GetCurrentValue()), @"label": sonyLabel(field.code, p.GetCurrentValue()),
        @"writable": @(field.editable && p.IsSetEnableCurrentValue() && choices.count > 0), @"choices": choices}];
      break;
    }
  }
  if (properties) ReleaseDeviceProperties(session.handle, properties);
  return fields;
}
- (NSDictionary *)prepareCandidateAddress:(NSString *)address macAddress:(NSString *)macAddress
  authentication:(BOOL)authentication model:(SCRSDK::CrCameraDeviceModelList)model
  modelName:(NSString *)modelName name:(NSString *)name error:(NSString **)error {
  uint32_t parsedAddress = 0; uint8_t parsedMAC[6] = {}; NSString *identity = nil;
  if (!sonyParseIPv4(address, parsedAddress) || !sonyParseMAC(macAddress, parsedMAC, &identity)) {
    *error = @"The camera's IPv4 or MAC address is invalid.";
    return nil;
  }
  // Rescanning an already connected camera should not open another SSH socket.
  // Its fingerprint was verified at connect; reconnect always verifies again.
  NSDictionary *previous = nil;
  auto prior = _sony->cameraRecords.find(identity.UTF8String);
  if (prior != _sony->cameraRecords.end()) previous = prior->second;
  BOOL reuseFingerprint = NO;
  if (previous && [previous[@"address"] isEqualToString:address] &&
      [previous[@"model"] isEqualToString:modelName] && [previous[@"authentication"] boolValue] == authentication) {
    for (const auto &entry : _sony->sessions) {
      if (entry.second.cameraID != identity.UTF8String) continue;
      std::lock_guard<std::mutex> lock(entry.second.callback->mutex);
      if (entry.second.callback->connected && [previous[@"fingerprint"] length]) reuseFingerprint = YES;
    }
  }
  SCRSDK::ICrCameraObjectInfo *info = nullptr;
  auto result = SCRSDK::CreateCameraObjectInfoEthernetConnection(&info, model, parsedAddress, parsedMAC,
    authentication ? SCRSDK::CrSSHsupport_ON : SCRSDK::CrSSHsupport_OFF);
  std::shared_ptr<SCRSDK::ICrCameraObjectInfo> owned(info,
    [](SCRSDK::ICrCameraObjectInfo *value) { if (value) value->Release(); });
  if (result || !info) { *error = sonyError("prepare camera", result ?: SCRSDK::CrError_Generic_Unknown); return nil; }
  NSString *fingerprint = reuseFingerprint ? previous[@"fingerprint"] : @"";
  NSString *fingerprintError = @"";
  if (authentication && !reuseFingerprint) {
    char buffer[128] = {}; CrInt32u length = 0;
    result = SCRSDK::GetFingerprint(info, buffer, &length);
    if (result) fingerprintError = sonyError("fingerprint", result);
    else if (length > 0 && length <= sizeof(buffer)) fingerprint = [[NSString alloc] initWithBytes:buffer length:length encoding:NSUTF8StringEncoding] ?: @"";
    if (!result && !fingerprint.length) fingerprintError = @"Sony returned an invalid camera fingerprint. Find cameras again before connecting.";
  }
  struct in_addr displayAddress = {}; displayAddress.s_addr = parsedAddress;
  char addressBuffer[INET_ADDRSTRLEN] = {};
  inet_ntop(AF_INET, &displayAddress, addressBuffer, sizeof(addressBuffer));
  NSDictionary *record = @{@"id": identity, @"model": modelName, @"name": name.length ? name : modelName,
    @"address": sonyString(addressBuffer), @"authentication": @(authentication),
    @"fingerprint": fingerprint, @"fingerprintError": fingerprintError};
  _sony->manualInfos[identity.UTF8String] = owned;
  _sony->cameraRecords[identity.UTF8String] = record;
  return record;
}
#endif
- (void)discover:(UCSonyReply)reply {
  [self enqueueSony:^{
#if ULTRACAM_SONY_SDK
    if (![self initializeSony:reply]) return;
    [self purgeDisconnectedSessions];
    for (const auto &entry : self->_sony->sessions) {
      if (entry.second.enumeration) {
        [self reply:reply object:nil error:@"Disconnect existing Sony cameras before switching discovery methods."];
        return;
      }
    }
    // Both automatic and advanced manual discovery now create factory objects.
    // Never combine SDK enumeration objects with these connected sessions.
    self->_sony->enumeration.reset();
    self->_sony->manualMode = true;
    NSString *networkError = nil;
    NSArray<NSDictionary *> *detected = SonyNetwork::discover(&networkError);
    if (networkError) { [self reply:reply object:nil error:networkError]; return; }
    NSMutableDictionary<NSString *, NSDictionary *> *unique = [NSMutableDictionary new];
    for (NSDictionary *camera in sonyDeduplicateCandidates(detected, self->_sony->cameraRecords)) {
      NSString *modelName = camera[@"model"];
      SCRSDK::CrCameraDeviceModelList model;
      if ([modelName isEqualToString:@"ILME-FX3"]) model = SCRSDK::CrCameraDeviceModel_ILME_FX3;
      else if ([modelName isEqualToString:@"ILME-FX3A"]) model = SCRSDK::CrCameraDeviceModel_ILME_FX3A;
      else if ([modelName isEqualToString:@"ILME-FX30"]) model = SCRSDK::CrCameraDeviceModel_ILME_FX30;
      else continue;
      NSString *error = nil;
      NSDictionary *record = [self prepareCandidateAddress:camera[@"address"] macAddress:camera[@"mac"]
        authentication:[camera[@"authentication"] boolValue] model:model modelName:modelName
        name:camera[@"name"] error:&error];
      if (record && !unique[record[@"id"]]) unique[record[@"id"]] = record;
    }
    NSArray *sorted = [unique.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
      NSComparisonResult byName = [a[@"name"] localizedStandardCompare:b[@"name"]];
      return byName == NSOrderedSame ? [a[@"id"] compare:b[@"id"]] : byName;
    }];
    [self reply:reply object:sorted error:nil];
#else
    [self reply:reply object:nil error:@"Sony control is unavailable in this build. Install the macOS Sony Camera Remote SDK and rebuild Ultracam."];
#endif
  }];
}
- (void)prepareCameraAtAddress:(NSString *)address macAddress:(NSString *)macAddress
               authentication:(BOOL)authentication completion:(UCSonyReply)reply {
  [self enqueueSony:^{
#if ULTRACAM_SONY_SDK
    uint32_t parsedAddress = 0;
    uint8_t parsedMAC[6] = {};
    NSString *identity = nil;
    if (!sonyParseIPv4(address, parsedAddress)) {
      [self reply:reply object:nil error:@"Enter the camera's IPv4 address from its network information screen."];
      return;
    }
    if (!sonyParseMAC(macAddress, parsedMAC, &identity)) {
      [self reply:reply object:nil error:@"Enter the camera's six-byte Wi-Fi MAC address from its network information screen."];
      return;
    }
    if (![self initializeSony:reply]) return;
    [self purgeDisconnectedSessions];
    for (const auto &entry : self->_sony->sessions) {
      if (entry.second.enumeration) {
        [self reply:reply object:nil error:@"Disconnect automatically discovered Sony cameras before adding a camera by IP. The SDK cannot mix these connection methods."];
        return;
      }
    }
    self->_sony->enumeration.reset();
    self->_sony->manualMode = true;
    NSString *error = nil;
    NSDictionary *record = [self prepareCandidateAddress:address macAddress:macAddress authentication:authentication
      model:SCRSDK::CrCameraDeviceModel_ILME_FX3 modelName:@"ILME-FX3" name:@"ILME-FX3" error:&error];
    if ([record[@"fingerprintError"] length]) error = record[@"fingerprintError"];
    [self reply:reply object:error ? nil : record error:error];
#else
    [self reply:reply object:nil error:@"Sony SDK is unavailable in this build."];
#endif
  }];
}
- (void)connectFeed:(NSString *)feedID camera:(NSString *)cameraID user:(NSString *)user password:(NSString *)password
       fingerprint:(NSString *)fingerprint completion:(UCSonyReply)reply {
  [self enqueueSony:^{
#if ULTRACAM_SONY_SDK
    if (![self initializeSony:reply]) return;
    auto &sessions = self->_sony->sessions;
    if (sessions.count(feedID.UTF8String)) { [self reply:reply object:nil error:@"Disconnect this feed before connecting another camera."]; return; }
    const SCRSDK::ICrCameraObjectInfo *info = nullptr;
    auto list = self->_sony->enumeration;
    std::shared_ptr<SCRSDK::ICrCameraObjectInfo> directInfo;
    if (self->_sony->manualMode) {
      auto found = self->_sony->manualInfos.find(cameraID.UTF8String);
      if (found != self->_sony->manualInfos.end()) { directInfo = found->second; info = directInfo.get(); }
    } else {
      for (CrInt32u i = 0; list && i < list->GetCount(); ++i) {
        auto candidate = list->GetCameraObjectInfo(i);
        if ([[self cameraIdentity:candidate] isEqualToString:cameraID]) { info = candidate; break; }
      }
    }
    if (!info) { [self reply:reply object:nil error:@"Camera is no longer in discovery. Scan again."]; return; }
    if (info->GetSSHsupport() == SCRSDK::CrSSHsupport_ON) {
      char buffer[128] = {}; CrInt32u length = 0;
      auto result = SCRSDK::GetFingerprint(const_cast<SCRSDK::ICrCameraObjectInfo *>(info), buffer, &length);
      if (result || !fingerprint.length || length > sizeof(buffer) ||
          ![fingerprint isEqualToString:[[NSString alloc] initWithBytes:buffer length:MIN(length, sizeof(buffer)) encoding:NSUTF8StringEncoding]]) {
        [self reply:reply object:nil error:@"Camera fingerprint changed or could not be verified. Scan again and verify the camera identity before connecting."]; return;
      }
    }
    __weak UCSonyCameraControl *weakSelf = self;
    auto callback = std::make_shared<SonyCallback>(^(NSString *kind, NSString *message) {
      dispatch_async(dispatch_get_main_queue(), ^{ UCSonyCameraControl *owner = weakSelf; if (owner.eventHandler) owner.eventHandler(feedID, kind, message); });
    });
    callback->afterDisconnect = ^{ sonyRuntime().enqueue(^{ sonyRuntime().reap(); }); };
    SonySession session; session.callback = callback; session.enumeration = list; session.directInfo = directInfo; session.cameraID = cameraID.UTF8String;
    auto error = SCRSDK::Connect(const_cast<SCRSDK::ICrCameraObjectInfo *>(info), callback.get(), &session.handle,
      SCRSDK::CrSdkControlMode_Remote, SCRSDK::CrReconnecting_OFF,
      user.UTF8String, password.UTF8String, fingerprint.UTF8String, (CrInt32u)[fingerprint lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    if (!error) {
      std::unique_lock<std::mutex> lock(callback->mutex);
      callback->condition.wait_for(lock, std::chrono::seconds(15), [&] { return callback->connected || callback->disconnected || callback->error; });
      if (!callback->connected) error = callback->error ?: SCRSDK::CrError_Connect_TimeOut;
    }
    if (error) {
      if (![self closeSession:session]) sessions.emplace(feedID.UTF8String, session);
      [self reply:reply object:nil error:sonyError("connect", error)]; return;
    }
    // The SDK enables its own image acquisition by default: explicitly stop it.
    error = SCRSDK::SetDeviceSetting(session.handle, SCRSDK::Setting_Key_EnableLiveView, SCRSDK::CrDeviceSetting_Disable);
    if (error) {
      if (![self closeSession:session]) sessions.emplace(feedID.UTF8String, session);
      [self reply:reply object:nil error:sonyError("disable live view", error)]; return;
    }
    sessions.emplace(feedID.UTF8String, session);
    NSString *readError = nil;
    NSArray *properties = [self propertiesFor:sessions.at(feedID.UTF8String) error:&readError];
    if (readError && [self closeSession:sessions.at(feedID.UTF8String)]) sessions.erase(feedID.UTF8String);
    [self reply:reply object:properties error:readError];
#else
    [self reply:reply object:nil error:@"Sony SDK is unavailable in this build."];
#endif
  }];
}
- (void)refreshFeed:(NSString *)feedID completion:(UCSonyReply)reply {
  [self enqueueSony:^{
#if ULTRACAM_SONY_SDK
    auto found = self->_sony->sessions.find(feedID.UTF8String);
    if (found == self->_sony->sessions.end()) { [self reply:reply object:nil error:@"Connect the Sony camera first."]; return; }
    NSString *error = nil; NSArray *properties = [self propertiesFor:found->second error:&error];
    [self reply:reply object:properties error:error];
#else
    [self reply:reply object:nil error:@"Sony SDK is unavailable in this build."];
#endif
  }];
}
- (void)setFeed:(NSString *)feedID code:(uint32_t)code value:(uint64_t)value completion:(UCSonyReply)reply {
  [self enqueueSony:^{
#if ULTRACAM_SONY_SDK
    using namespace SCRSDK;
    auto found = self->_sony->sessions.find(feedID.UTF8String);
    const auto *field = sonyField(code);
    if (found == self->_sony->sessions.end() || !field || !field->editable) { [self reply:reply object:nil error:@"This camera setting is unavailable."]; return; }
    auto &session = found->second;
    CrDeviceProperty *properties = nullptr; CrInt32 count = 0;
    CrInt32u requestedCode = code;
    auto error = GetSelectDeviceProperties(session.handle, 1, &requestedCode, &properties, &count);
    bool allowed = false; uint64_t revision;
    { std::lock_guard<std::mutex> lock(session.callback->mutex); revision = session.callback->revision; session.callback->error = 0; }
    if (!error && properties) for (CrInt32 i = 0; i < count; ++i) {
      auto &p = properties[i]; if (p.GetCode() != code || !p.IsSetEnableCurrentValue()) continue;
      for (auto choice : sonyChoices(p)) if (choice == value) allowed = true;
      if (allowed) {
        CrDeviceProperty request; request.SetCode(code); request.SetValueType(p.GetValueType()); request.SetCurrentValue(value);
        error = SetDeviceProperty(session.handle, &request);
      }
      break;
    }
    if (properties) ReleaseDeviceProperties(session.handle, properties);
    if (error || !allowed) { [self reply:reply object:nil error:error ? sonyError("set setting", error) : @"The camera no longer allows this value. Refresh its settings; check exposure mode and control priority."]; return; }
    // SetDeviceProperty only queues a command. Wait for notification, then read
    // the actual camera value; never display a requested value as confirmed.
    uint32_t callbackError = 0;
    bool callbackDisconnected = false;
    {
      std::unique_lock<std::mutex> lock(session.callback->mutex);
      session.callback->condition.wait_for(lock, std::chrono::seconds(3), [&] { return session.callback->revision != revision || session.callback->error || session.callback->disconnected; });
      callbackError = session.callback->error;
      callbackDisconnected = session.callback->disconnected;
    }
    if (callbackDisconnected || callbackError) {
      [self reply:reply object:nil error:callbackDisconnected ?
        @"The camera disconnected before confirming this setting." : sonyError("set setting", callbackError)];
      return;
    }
    NSString *readError = nil; NSArray *snapshot = [self propertiesFor:session error:&readError];
    BOOL confirmed = NO;
    for (NSDictionary *p in snapshot) if ([p[@"code"] unsignedIntValue] == code && [p[@"value"] unsignedLongLongValue] == value) confirmed = YES;
    [self reply:reply object:snapshot error:readError ?: (confirmed ? nil : @"The camera has not confirmed this value. Refresh to check it; its current mode or control priority may prevent the change.")];
#else
    [self reply:reply object:nil error:@"Sony SDK is unavailable in this build."];
#endif
  }];
}
- (void)disconnectFeed:(NSString *)feedID completion:(UCSonyReply)reply {
  [self enqueueSony:^{
#if ULTRACAM_SONY_SDK
    auto found = self->_sony->sessions.find(feedID.UTF8String);
    if (found != self->_sony->sessions.end()) {
      if (![self closeSession:found->second]) {
        [self reply:reply object:nil error:@"Sony has not acknowledged disconnection yet. The connection is retained safely; retry after the camera disconnects."];
        return;
      }
      self->_sony->sessions.erase(found);
    }
#endif
    [self reply:reply object:@[] error:nil];
  }];
}
- (void)shutdown:(UCSonyReply)reply {
  [self enqueueSony:^{
#if ULTRACAM_SONY_SDK
    if (!sonyRuntime().shutdown(*self->_sony)) {
      [self reply:reply object:nil error:@"Sony has not acknowledged every disconnect. SDK cleanup is pending; callbacks remain alive until acknowledgement."];
      return;
    }
#endif
    [self reply:reply object:@[] error:nil];
  }];
}
- (void)dealloc {
#if ULTRACAM_SONY_SDK
  // Never block the main thread or destroy a callback on a disconnect timeout.
  // Retiring on the dedicated SDK thread also meets Init/Release thread affinity.
  if (_sony->initialized || !_sony->sessions.empty()) {
    SonyState *state = _sony.release();
    sonyRuntime().enqueue(^{ sonyRuntime().retire(state); });
  }
#endif
}
@end
