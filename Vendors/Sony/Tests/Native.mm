#define ULTRACAM_SONY_SDK 1
#include "../Sources/SonyCameraControl.mm"
#include <cassert>

int main() {
  @autoreleasepool {
    UCSonyCameraControl *metadata = [UCSonyCameraControl new];
    assert(metadata.available);
    assert([metadata.sdkVersion isEqualToString:@"2.2.0"]);
    assert(sonyPreparedConnectionMatches(@"192.0.2.1", true, @"pin", @"user", @"secret", inet_addr("192.0.2.1"), true));
    assert(!sonyPreparedConnectionMatches(@"192.0.2.1", true, @"pin", @"user", @"secret", inet_addr("192.0.2.2"), true));
    assert(!sonyPreparedConnectionMatches(@"192.0.2.1", true, @"pin", @"user", @"secret", inet_addr("192.0.2.1"), false));
    assert(!sonyPreparedConnectionMatches(@"192.0.2.1", false, @"pin", @"user", @"secret", inet_addr("192.0.2.1"), false));
    using namespace SCRSDK;
    assert(sonyField(CrDeviceProperty_Movie_Recording_FrameRateSetting)->editable);
    assert(sonyField(CrDeviceProperty_Movie_HDMIOutputResolution)->editable);
    assert(sonyField(CrDeviceProperty_Movie_HDMIOutput4KSetting)->editable);
    assert(sonyField(CrDeviceProperty_Movie_HDMIOutputRawSetting)->editable);
    assert([sonyLabel(CrDeviceProperty_Movie_Recording_FrameRateSetting,
      CrRecordingFrameRateSettingMovie_29_97p) isEqualToString:@"29.97p"]);
    assert([sonyLabel(CrDeviceProperty_Movie_Recording_FrameRateSetting,
      CrRecordingFrameRateSettingMovie_59_94p) isEqualToString:@"59.94p"]);
    assert([sonyLabel(CrDeviceProperty_Movie_HDMIOutputResolution,
      CrHDMIResolution_1080p) isEqualToString:@"1080p"]);
    assert([sonyLabel(CrDeviceProperty_Movie_HDMIOutput4KSetting,
      CrHDMIOutput4KSettingMovie_59_94p_10bit) isEqualToString:@"59.94p · 10-bit"]);
    assert([sonyLabel(CrDeviceProperty_Movie_HDMIOutputRawSetting,
      CrHDMIOutputRawSettingMovie_23_98p) isEqualToString:@"23.98p"]);
    assert([sonyLabel(CrDeviceProperty_ExposureProgramMode,
      CrExposure_MemoryRecall) isEqualToString:@"Memory recall"]);
    uint32_t parsedAddress = 0;
    assert(sonyParseIPv4(@"192.168.1.160", parsedAddress) && parsedAddress == 0xA001A8C0);
    assert(sonyParseIPv4(@"169.254.1.1", parsedAddress));
    assert(!sonyParseIPv4(@"192.168.1.999", parsedAddress));
    assert(!sonyParseIPv4(@"127.0.0.1", parsedAddress));
    assert(!sonyParseIPv4(@"239.255.255.250", parsedAddress));
    assert(!sonyParseIPv4(@"camera.local", parsedAddress));
    uint8_t parsedMAC[6] = {}; NSString *normalizedMAC = nil;
    assert(sonyParseMAC(@"EC:5C:84:2B:E7:0A", parsedMAC, &normalizedMAC));
    assert([normalizedMAC isEqualToString:@"ec:5c:84:2b:e7:0a"] && parsedMAC[0] == 0xEC && parsedMAC[5] == 0x0A);
    assert(sonyParseMAC(@"ec-5c-84-2b-e7-0a", parsedMAC, nullptr));
    assert(!sonyParseMAC(@"ec:5c:84:2b:e7", parsedMAC, nullptr));
    assert(!sonyParseMAC(@"ec:5c:84:2b:e7:zz", parsedMAC, nullptr));
    assert(!sonyParseMAC(@"00:00:00:00:00:00", parsedMAC, nullptr));
    assert(!sonyParseMAC(@"ff:ff:ff:ff:ff:ff", parsedMAC, nullptr));
    // Discovery parsers run without opening sockets in the regular checks.
    using namespace SonyNetwork;
    auto ipv4 = [](const char *text) { in_addr value = {}; assert(inet_pton(AF_INET, text, &value) == 1); return value.s_addr; };
    Interface lan{ipv4("192.0.2.1"), ipv4("255.255.255.0")};
    const uint32_t peer = ipv4("192.0.2.20");
    const std::string ssdp = "HTTP/1.1 200 OK\r\nlocation: http://192.0.2.20:64321/dd.xml\r\nserver: UPnP/1.0 SonyImagingDevice/1.0\r\nX-AV-Server-Info: cn=\"Sony Corporation\"\r\n\r\n";
    Candidate candidate;
    assert(parseReply(ssdp, peer, lan, candidate));
    assert(candidate.address == peer && candidate.localAddress == lan.address);
    assert(!parseReply(ssdp, ipv4("192.0.3.20"), lan, candidate));
    assert(!parseReply(ssdp, ipv4("192.0.2.255"), lan, candidate));
    assert(!parseReply(ssdp, ipv4("192.0.2.21"), lan, candidate)); // LOCATION must match sender.
    assert(!parseReply(std::string(maximumDatagram + 1, 'x'), peer, lan, candidate));
    assert(!safeURL(@"http://camera.local/dd.xml", peer));
    assert(!safeURL(@"http://user:pass@192.0.2.20/dd.xml", peer));
    assert(!safeURL(@"http://192.0.2.20:70000/dd.xml", peer));
    assert(!safeURL(@"http://192.0.2.20/dd.xml?redirect=http://example.com", peer));
    assert(!safeURL(@"file:///etc/passwd", peer));
    assert(!safeURL(@"http://192.0.2.20/dd.xml\r\nInjected: true", peer));
    assert(safeURL(@"http://192.0.2.20:64321/DigitalImagingDesc.xml", peer));
    std::string body;
    assert(httpBody("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n<r/>", false, body) == BodyResult::complete && body == "<r/>");
    assert(httpBody("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n<r/>\r\n0\r\n\r\n", false, body) == BodyResult::complete && body == "<r/>");
    assert(httpBody("HTTP/1.1 302 Found\r\nLocation: http://192.0.2.21/dd.xml\r\nContent-Length: 0\r\n\r\n", true, body) == BodyResult::invalid);
    assert(httpBody("HTTP/1.1 200 OK\r\nContent-Length: 65537\r\n\r\n", false, body) == BodyResult::invalid);
    assert(httpBody("HTTP/1.1 200 OK\r\nContent-Length: 4\r\ncontent-length: 4\r\n\r\n<r/>", false, body) == BodyResult::invalid);
    assert(httpBody("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n<r", false, body) == BodyResult::incomplete);
    assert(httpBody("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n<r", true, body) == BodyResult::invalid);
    assert(httpBody("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFF\r\n", false, body) == BodyResult::invalid);
    assert(httpBody(std::string(maximumHeader + 1, 'x'), false, body) == BodyResult::invalid);
    assert(millisecondsLeft(Clock::now() - std::chrono::milliseconds(1)) == 0);
    assert(millisecondsLeft(Clock::now() + std::chrono::milliseconds(50)) <= 50);
    auto xmlData = [](NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; };
    NSDictionary *description = parseXML(xmlData(@"<root xmlns='urn:test'><device><friendlyName>ILME-FX3:A</friendlyName><manufacturer>Sony Corporation</manufacturer><serviceList><service><serviceType>urn:schemas-sony-com:service:DigitalImaging:1</serviceType><SCPDURL>/DigitalImagingDesc.xml</SCPDURL></service></serviceList></device></root>"));
    assert([description[@"friendlyname"] isEqualToString:@"ILME-FX3:A"]);
    assert([description[@"digitalimagingpath"] isEqualToString:@"/DigitalImagingDesc.xml"]);
    NSDictionary *detail = parseXML(xmlData(@"<s:root xmlns:s='urn:test'><s:X_ModelName>ILME-FX3</s:X_ModelName><s:X_MacAddress>AA:BB:CC:DD:EE:FF</s:X_MacAddress><s:X_SSH_Support>Enable</s:X_SSH_Support></s:root>"));
    assert([detail[@"x_modelname"] isEqualToString:@"ILME-FX3"] && [detail[@"x_ssh_support"] isEqualToString:@"Enable"]);
    assert(!parseXML(xmlData(@"<!DOCTYPE r [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><r>&x;</r>")));
    assert(!parseXML(xmlData(@"<!DOCTYPE r [<!ENTITY x 'expanded'>]><r>&x;</r>")));
    assert(!parseXML(xmlData(@"<r><unclosed></r>")));
    NSMutableString *deep = [NSMutableString new];
    for (int i = 0; i < 40; ++i) [deep appendString:@"<r>"];
    for (int i = 0; i < 40; ++i) [deep appendString:@"</r>"];
    assert(!parseXML(xmlData(deep)));
    NSMutableString *oversizedText = [NSMutableString stringWithString:@"<r>"];
    for (int i = 0; i < 1025; ++i) [oversizedText appendString:@"x"];
    [oversizedText appendString:@"</r>"];
    assert(!parseXML(xmlData(oversizedText)));
    std::map<std::string, NSDictionary *> previousCameras;
    previousCameras["aa:bb:cc:dd:ee:ff"] = @{@"address": @"192.0.2.20"};
    NSArray *deduplicated = sonyDeduplicateCandidates(@[
      @{@"mac": @"AA:BB:CC:DD:EE:FF", @"address": @"192.0.2.21"},
      @{@"mac": @"aa-bb-cc-dd-ee-ff", @"address": @"192.0.2.20"}], previousCameras);
    assert(deduplicated.count == 1 && [deduplicated[0][@"address"] isEqualToString:@"192.0.2.20"]);
    assert([sonyLabel(CrDeviceProperty_FNumber, 280) isEqualToString:@"ƒ/2.8"]);
    assert([sonyLabel(CrDeviceProperty_ShutterSpeed, (1 << 16) | 50) isEqualToString:@"1/50 s"]);
    assert([sonyLabel(CrDeviceProperty_ShutterAngle, 180000) isEqualToString:@"180°"]);
    assert([sonyLabel(CrDeviceProperty_IsoSensitivity, CrISO_AUTO) isEqualToString:@"Auto"]);
    assert([sonyLabel(CrDeviceProperty_IsoSensitivity, 12800) isEqualToString:@"12800"]);
    assert([sonyLabel(CrDeviceProperty_ExposureBiasCompensation, (uint16_t)-1700) isEqualToString:@"-1.70 EV"]);
    assert([sonyLabel(CrDeviceProperty_FocusMode, CrFocus_AF_C) isEqualToString:@"AF-C"]);
    assert([sonyLabel(CrDeviceProperty_GainBaseIsoSensitivity, CrGainBaseIsoSensitivity_High) isEqualToString:@"High"]);
    assert([sonyLabel(CrDeviceProperty_RecordingState, CrMovie_Recording_State_Recording) isEqualToString:@"Recording"]);
    uint32_t iso[] = {100, 800, 12800, CrISO_AUTO};
    auto choices = sonyDecodeChoices(CrDataType_UInt32Array, (uint8_t *)iso, sizeof(iso));
    assert(choices.size() == 4 && choices[2] == 12800);
    // SDK arrays may be unaligned. Values must be copied, not pointer-cast.
    uint8_t unaligned[sizeof(iso) + 1] = {}; memcpy(unaligned + 1, iso, sizeof(iso));
    assert(sonyDecodeChoices(CrDataType_UInt32Array, unaligned + 1, sizeof(iso)) == choices);
    uint16_t kelvin[] = {2500, 9900, 100};
    choices = sonyDecodeChoices(CrDataType_UInt16Range, (uint8_t *)kelvin, sizeof(kelvin));
    assert(choices.size() == 75 && choices.front() == 2500 && choices.back() == 9900);
    int16_t compensation[] = {-2000, 2000, 1000};
    choices = sonyDecodeChoices(CrDataType_Int16Range, (uint8_t *)compensation, sizeof(compensation));
    assert(choices.size() == 5 && (int64_t)choices.front() == -2000 && choices.back() == 2000);
    uint32_t giant[] = {0, UINT32_MAX, 1};
    assert(sonyDecodeChoices(CrDataType_UInt32Range, (uint8_t *)giant, sizeof(giant)).empty());
    uint32_t zeroStep[] = {100, 800, 0};
    assert(sonyDecodeChoices(CrDataType_UInt32Range, (uint8_t *)zeroStep, sizeof(zeroStep)).empty());
    assert(sonyDecodeChoices(CrDataType_UInt32Array, (uint8_t *)iso, sizeof(iso) - 1).empty());
    assert(sonyDecodeChoices(CrDataType_STR, (uint8_t *)iso, sizeof(iso)).empty());
    assert(sonyDecodeChoices(CrDataType_UInt32Array, nullptr, 4).empty());
    __block int events = 0;
    SonyCallback callback(^(NSString *, NSString *) { ++events; });
    // Continuous autofocus metadata must not wake the settings refresh path.
    // Unknown properties also remain outside the app's displayed setting set.
    uint32_t noise[] = {CrDeviceProperty_FocusPositionCurrentValue, CrDeviceProperty_FocusIndication, 0xDEADBEEF};
    callback.OnPropertyChangedCodes(3, noise);
    callback.OnPropertyChangedCodes(0, nullptr);
    callback.OnPropertyChangedCodes(1, nullptr);
    assert(events == 0 && callback.revision == 0 && !callback.dirty);
    uint32_t settings[] = {CrDeviceProperty_IsoSensitivity};
    callback.OnPropertyChangedCodes(1, settings);
    callback.OnPropertyChangedCodes(1, settings);
    assert(events == 1); // Coalesce invalidation; don't publish each camera event.
    callback.dirty = false;
    callback.OnPropertyChangedCodes(1, settings);
    assert(events == 2);
    // Low-frequency read-only values are visible camera state, so their
    // notifications need the same coalesced refresh as editable settings.
    uint32_t displayedReadouts[] = {CrDeviceProperty_IsoCurrentSensitivity,
      CrDeviceProperty_RecordingState, CrDeviceProperty_BatteryRemain};
    for (auto code : displayedReadouts) {
      callback.dirty = false;
      int before = events;
      uint64_t revision = callback.revision;
      callback.OnPropertyChangedCodes(1, &code);
      callback.OnPropertyChangedCodes(1, &code);
      assert(events == before + 1 && callback.revision == revision + 2 && callback.dirty);
    }
    callback.dirty = false;
    int beforeGeneric = events;
    uint64_t revisionBeforeGeneric = callback.revision;
    callback.OnPropertyChanged();
    callback.OnPropertyChanged();
    assert(events == beforeGeneric + 1 && callback.revision == revisionBeforeGeneric + 2 && callback.dirty);
    callback.OnError(0x1234);
    assert(callback.error == 0x1234);
    callback.OnDisconnected(0x5678);
    assert(callback.disconnected && !callback.connected && callback.error == 0x5678);
    // A disconnect event can make its owner drop the last session reference.
    // The callback must survive the rest of its own notification function.
    __block std::shared_ptr<SonyCallback> notificationOwner;
    __block std::weak_ptr<SonyCallback> notificationWeak;
    notificationOwner = std::make_shared<SonyCallback>(^(NSString *, NSString *) {
      notificationOwner.reset();
      assert(!notificationWeak.expired());
    });
    notificationWeak = notificationOwner;
    notificationOwner->afterDisconnect = ^{ assert(!notificationWeak.expired()); };
    notificationOwner->OnDisconnected(0);
    assert(notificationWeak.expired());
    assert([UCSonyCameraControl new].available);
    puts("Sony native checks passed: SSDP/HTTP/XML parsing, source/deadline bounds, MAC dedup, formatting, SDK values, callback filtering/coalescing and lifetime.");
  }
}
