#import <Foundation/Foundation.h>
#import "../../../Sources/DeviceAPI/DeviceAPI.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN
// A larger source-clock step begins a new epoch, rather than estimating drops.
// One elapsed-time policy applies at every SDK cadence (mirrored by core).
static const int64_t UCDeckLinkMaximumSourceGapSeconds = 10;

// Allocation evidence comes from our SDK allocator, never from an arbitrary
// driver's nominal byte count or a VM-region lookup. Retains frame+buffer access.
@interface UCDeckLinkOwnedMemoryFrame : NSObject
@property(nonatomic, readonly) const void *pointer;
@property(nonatomic, readonly) NSUInteger allocationLength;
@property(nonatomic, readonly) uint64_t generation;
@property(nonatomic, readonly) NSInteger width, height, rowBytes;
@property(nonatomic, readonly) uint32_t pixelFormat;
@property(nonatomic, readonly, nullable) NSString *colorPrimaries;
@property(nonatomic, readonly, nullable) NSString *transferFunction;
@property(nonatomic, readonly) BOOL fullRange;
@property(nonatomic, readonly, nullable) NSNumber *captureHostTimeSeconds;
@end

@interface UltracamMode : NSObject
@property(nonatomic, readonly) NSInteger width;
@property(nonatomic, readonly) NSInteger height;
@property(nonatomic, readonly) CMTime frameDuration;
@property(nonatomic, readonly, copy) NSString *name;
@end

@interface UltracamDevice : NSObject
@property(nonatomic, readonly) uint32_t videoInputConnections;
@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly, copy) NSArray<UltracamMode *> *modes;
@end

// The installed Desktop Video driver, read once with IDeckLinkAPIInformation.
// SDK 16 changed the interface IDs of IDeckLinkInput, IDeckLinkConfiguration,
// IDeckLinkProfileAttributes, IDeckLinkStatus, IDeckLinkVideoBuffer and
// IDeckLinkNotification, so an older driver lists no usable devices.
@interface UltracamDriverInfo : NSObject
@property(nonatomic, readonly) BOOL installed;
@property(nonatomic, readonly) BOOL supported;
// BMDDeckLinkAPIVersion: major << 24 | minor << 16 | sub << 8 | extra.
@property(nonatomic, readonly) int64_t versionValue;
@property(nonatomic, readonly, copy) NSString *version;
// A user-facing explanation when the driver is missing or older than 16.0.
@property(nonatomic, readonly, copy, nullable) NSString *message;
@end

// One atomic policy/application snapshot. A desired enabled value is not an
// acknowledgement when discovery could not acquire/write its EDID lease.
@interface UltracamHDRAdvertisementState : NSObject
@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, readonly, nullable) NSError *applicationError;
@end
@interface UCDeckLinkConnectorState : NSObject
@property(nonatomic, readonly) uint32_t connection;
@property(nonatomic, readonly, nullable) NSError *applicationError;
@end

// Read-only device facts and the live counters of the session that last used
// the device. Values are cached; reading never calls into the driver.
@interface UltracamDeviceDiagnostics : NSObject
@property(nonatomic, readonly, nullable) NSNumber *signalPresent;
@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly, copy) NSString *driverVersion;
// BMDDeckLinkMaximumHDMIAudioChannels; 0 when the driver does not report it.
@property(nonatomic, readonly) NSInteger maximumHDMIAudioChannels;
// Channels Ultracam enabled (negotiated 2/8/16-channel, 32-bit integer, 48 kHz).
@property(nonatomic, readonly) NSInteger capturedAudioChannels;
@property(nonatomic, readonly) BOOL supportsFormatDetection;
@property(nonatomic, readonly) BOOL supportsHDRMetadata;
@property(nonatomic, readonly) BOOL supportsColorspaceMetadata;
@property(nonatomic, readonly) BOOL supportsHDMITimecode;
@property(nonatomic, readonly) BOOL supportsHighFrameRateTimecode;
@property(nonatomic, readonly) BOOL sessionActive;
// Frames lost on the device side: gaps in the per-frame stream time, plus
// valid frames discarded or flushed while the input restarted for a new
// HDMI mode (the restarted stream clock cannot show those as a gap).
@property(nonatomic, readonly) uint64_t deviceDroppedFrames;
// GetAvailableVideoFrameCount, polled about once a second.
@property(nonatomic, readonly) uint32_t frameBacklog;
@property(nonatomic, readonly) uint32_t maximumFrameBacklog;
// IDeckLinkStatistics device temperature in °C, or NSNotFound.
@property(nonatomic, readonly) NSInteger temperatureCelsius;
// YES once the hardware reference clock is mapped onto the host clock.
@property(nonatomic, readonly) BOOL hostTimeMapped;
@property(nonatomic, readonly, copy, nullable) NSString *signal;
@property(nonatomic, readonly, copy) NSString *hdmiDynamicRange;
@end

// Each captured CVPixelBuffer carries this attachment when the frame's
// hardware reference timestamp could be mapped to the host clock: a CFNumber
// (Float64) in CMClockGetHostTimeClock seconds, taken when the device finished
// receiving the frame. Absent when the mapping is unavailable.


typedef void (^UltracamMediaStatsHandler)(NSString *_Nullable timecode, CMTime audioPacketTime,
  NSUInteger audioSampleFrames, NSUInteger audioChannels, float leftPeak, float rightPeak,
  float leftRMS, float rightRMS, NSUInteger audioBytes, BOOL audioPresent);

// Raw embedded audio packets are copied on the DeckLink callback thread before
// the SDK packet is released. Samples are interleaved signed 32-bit PCM when
// this handler is used (48 kHz, negotiated channels, little-endian native bytes).
// Within one callback the video frame goes first: the frame handler has
// returned (or the frame was gated or refused) before the callback's media
// statistics and raw audio are reported. Audio is reported on every path,
// including a callback without a video frame or with an invalid one.
typedef void (^UltracamRawAudioHandler)(NSData *_Nullable samples, CMTime audioPacketTime,
  NSUInteger audioSampleFrames, NSUInteger audioChannels, NSUInteger bytesPerSample);

// Calls start/stop on one control queue. Frames execute on Blackmagic's
// callback thread; events may also use the native control queue or, for a
// device removal, the discovery queue. Handlers must return promptly: retain
// the CVPixelBuffer for asynchronous work. The pixel buffer owns the
// underlying DeckLink frame until its final release.
// Never call stop() synchronously from a handler (it waits for callbacks).
NS_SWIFT_NAME(DeckLinkBackend)
@interface UCDeckLinkBackend : NSObject
- (void)setCPUMemoryFrameHandler:(void (^)(UCDeckLinkOwnedMemoryFrame *, CMTime, CMTime))handler;
+ (NSString *)sdkVersion;
+ (void)seedInputConnectors:(NSDictionary<NSString *, NSNumber *> *)values;
+ (nullable NSNumber *)inputConnectorForDeviceID:(NSString *)deviceID error:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(inputConnector(deviceID:));
+ (nullable UCDeckLinkConnectorState *)inputConnectorStateForDeviceID:(NSString *)deviceID error:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(inputConnectorState(deviceID:));
+ (BOOL)setInputConnector:(uint32_t)connection deviceID:(NSString *)deviceID error:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(setInputConnector(_:deviceID:));
- (void)setRequestedWidth:(NSInteger)width height:(NSInteger)height duration:(CMTime)duration
  NS_SWIFT_NAME(setRequestedFormat(width:height:duration:));
@property(nonatomic, readonly) NSInteger configuredAudioChannels;
- (void)setAudioFormatHandler:(void (^)(NSInteger channels))handler;
// Configure before start. The paired hooks enclose the complete SDK callback,
// including frame-less/audio-only and refused-video paths. They execute on the
// same SDK thread, with end guaranteed by RAII. Legacy callers need no hooks.
- (void)setCallbackGroupHandlersWithBegin:(void (^)(void))begin
                                     end:(void (^)(void))end
  NS_SWIFT_NAME(setCallbackGroupHandlers(begin:end:));
// Called inside the group after native timecode decoding and before its frame
// handoff. Nil is explicit; the adapter must never borrow the previous frame.
- (void)setCallbackTimecodeHandler:(void (^)(NSString *_Nullable timecode))handler
  NS_SWIFT_NAME(setCallbackTimecodeHandler(_:));
+ (nullable NSArray<UltracamDevice *> *)devicesWithError:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(devices());
- (BOOL)startWithDeviceID:(NSString *)deviceID
               inputFast:(BOOL)inputFast
            frameHandler:(void (^)(CVPixelBufferRef pixelBuffer, CMTime presentationTime, BOOL signalValid))frameHandler
             mediaHandler:(UltracamMediaStatsHandler _Nullable)mediaHandler
            eventHandler:(void (^)(NSString *message))eventHandler
                   error:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(start(deviceID:inputFast:frameHandler:mediaHandler:eventHandler:));
- (BOOL)startWithDeviceID:(NSString *)deviceID
               inputFast:(BOOL)inputFast
            frameHandler:(void (^)(CVPixelBufferRef pixelBuffer, CMTime presentationTime, BOOL signalValid))frameHandler
       rawAudioHandler:(UltracamRawAudioHandler)rawAudioHandler
            eventHandler:(void (^)(NSString *message))eventHandler
                   error:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(start(deviceID:inputFast:frameHandler:rawAudioHandler:eventHandler:));
- (BOOL)startWithDeviceID:(NSString *)deviceID
               inputFast:(BOOL)inputFast
               frameHandler:(void (^)(CVPixelBufferRef pixelBuffer, CMTime presentationTime, BOOL signalValid))frameHandler
             mediaHandler:(UltracamMediaStatsHandler _Nullable)mediaHandler
          rawAudioHandler:(UltracamRawAudioHandler _Nullable)rawAudioHandler
            eventHandler:(void (^)(NSString *message))eventHandler
                   error:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(start(deviceID:inputFast:frameHandler:mediaHandler:rawAudioHandler:eventHandler:));
- (BOOL)startWithDeviceID:(NSString *)deviceID
               inputFast:(BOOL)inputFast
            frameHandler:(void (^)(CVPixelBufferRef pixelBuffer, CMTime presentationTime, BOOL signalValid))frameHandler
            eventHandler:(void (^)(NSString *message))eventHandler
                   error:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(start(deviceID:inputFast:frameHandler:eventHandler:));
// Automatically follows supported HDMI source modes. actualDuration comes
// from the source frame's stream time, never a user-selected expected rate.
- (BOOL)startAutoWithDeviceID:(NSString *)deviceID
                frameHandler:(void (^)(CVPixelBufferRef pixelBuffer, CMTime presentationTime, CMTime actualDuration, BOOL signalValid))frameHandler
                 mediaHandler:(UltracamMediaStatsHandler _Nullable)mediaHandler
                eventHandler:(void (^)(NSString *message))eventHandler
                       error:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(startAuto(deviceID:frameHandler:mediaHandler:eventHandler:));
- (BOOL)startAutoWithDeviceID:(NSString *)deviceID
                frameHandler:(void (^)(CVPixelBufferRef pixelBuffer, CMTime presentationTime, CMTime actualDuration, BOOL signalValid))frameHandler
           rawAudioHandler:(UltracamRawAudioHandler)rawAudioHandler
                eventHandler:(void (^)(NSString *message))eventHandler
                       error:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(startAuto(deviceID:frameHandler:rawAudioHandler:eventHandler:));
- (BOOL)startAutoWithDeviceID:(NSString *)deviceID
                frameHandler:(void (^)(CVPixelBufferRef pixelBuffer, CMTime presentationTime, CMTime actualDuration, BOOL signalValid))frameHandler
              mediaHandler:(UltracamMediaStatsHandler _Nullable)mediaHandler
           rawAudioHandler:(UltracamRawAudioHandler _Nullable)rawAudioHandler
                eventHandler:(void (^)(NSString *message))eventHandler
                       error:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(startAuto(deviceID:frameHandler:mediaHandler:rawAudioHandler:eventHandler:));
- (BOOL)startAutoWithDeviceID:(NSString *)deviceID
                frameHandler:(void (^)(CVPixelBufferRef pixelBuffer, CMTime presentationTime, CMTime actualDuration, BOOL signalValid))frameHandler
                eventHandler:(void (^)(NSString *message))eventHandler
                       error:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(startAuto(deviceID:frameHandler:eventHandler:));
- (void)stop;

+ (UltracamDriverInfo *)driverInfo;
// "Advertise HDR to cameras": on, each discovered device's HDMI EDID advertises
// SDR, PQ and HLG (written at discovery, or now for listed devices) and keeps
// doing so while the device is listed; off, Ultracam never writes the EDID and
// releases one it wrote. Capture starts never write it. Off until called.
+ (void)setAdvertisesHDRToCameras:(BOOL)enabled NS_SWIFT_NAME(setAdvertisesHDR(_:));
// Per-device policy overrides the legacy global fallback. Seed saved policies
// synchronously before discovery. Applying to an absent device reports error;
// capture start never changes or retries these policies.
+ (void)seedHDRAdvertisements:(NSDictionary<NSString *, NSNumber *> *)values;
+ (nullable NSNumber *)hdrAdvertisementForDeviceID:(NSString *)deviceID
                                           error:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(hdrAdvertisement(deviceID:));
+ (nullable UltracamHDRAdvertisementState *)hdrAdvertisementStateForDeviceID:(NSString *)deviceID
                                                                    error:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(hdrAdvertisementState(deviceID:));
+ (BOOL)setHDRAdvertisement:(BOOL)enabled deviceID:(NSString *)deviceID
                     error:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(setHDRAdvertisement(_:deviceID:));
// Hot-plug discovery (IDeckLinkDiscovery). Installs device notifications on
// first use. The handler runs on the main queue with the complete device list
// after every arrival or removal, and once soon after registering.
+ (id)addDeviceListObserver:(void (NS_SWIFT_UI_ACTOR ^)(NSArray<UltracamDevice *> *devices))handler
  NS_SWIFT_NAME(addDeviceListObserver(_:));
+ (void)removeDeviceListObserver:(id)token;
+ (nullable UltracamDeviceDiagnostics *)diagnosticsForDeviceID:(NSString *)deviceID
  NS_SWIFT_NAME(diagnostics(deviceID:));

// Live session counters; safe to read from any thread. deviceDroppedFrames
// is as described on UltracamDeviceDiagnostics.
@property(nonatomic, readonly) uint64_t deviceDroppedFrames;
@property(nonatomic, readonly) uint32_t availableFrameBacklog;
@property(nonatomic, readonly) uint32_t maximumFrameBacklog;
@end

#if defined(ULTRACAM_BACKEND_TESTING)
// Synthetic SDK callbacks only; never opens hardware or saves video.
FOUNDATION_EXPORT BOOL UltracamRunSDK16SyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunDiscoverySyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunOwnershipSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunAutoSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunRawAudioSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunCallbackOrderSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunCallbackGroupSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunPerDeviceHDRSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunFrameContractSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunExpandedModeSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunPixelNegotiationSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunOwnedAllocatorSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT UCDeckLinkOwnedMemoryFrame *UltracamCreateOwnedRGBFixture(void);
FOUNDATION_EXPORT UCDeckLinkOwnedMemoryFrame *UltracamCreateOwnedRGBColorFixture(uint32_t colorspace, int64_t eotf);
FOUNDATION_EXPORT BOOL UltracamRunOwnedColorSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunElapsedGapSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunConnectorSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunNativeAuditSyntheticChecks(NSError *_Nullable *_Nullable error);
// Zero denotes invalid/overflowing width; parity checked against Shared's table.
FOUNDATION_EXPORT uint64_t UltracamV210MinimumRowBytes(uint64_t width);
#endif

NS_ASSUME_NONNULL_END
