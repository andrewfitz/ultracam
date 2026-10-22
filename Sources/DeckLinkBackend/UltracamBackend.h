#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface UltracamMode : NSObject
@property(nonatomic, readonly) NSInteger width;
@property(nonatomic, readonly) NSInteger height;
@property(nonatomic, readonly) CMTime frameDuration;
@property(nonatomic, readonly, copy) NSString *name;
@end

@interface UltracamDevice : NSObject
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

// Read-only device facts and the live counters of the session that last used
// the device. Values are cached; reading never calls into the driver.
@interface UltracamDeviceDiagnostics : NSObject
@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly, copy) NSString *driverVersion;
// BMDDeckLinkMaximumHDMIAudioChannels; 0 when the driver does not report it.
@property(nonatomic, readonly) NSInteger maximumHDMIAudioChannels;
// Channels Ultracam enables (stereo, 32-bit integer, 48 kHz).
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
FOUNDATION_EXPORT NSString *const UltracamCaptureHostTimeAttachmentKey;

typedef void (^UltracamMediaStatsHandler)(NSString *_Nullable timecode, CMTime audioPacketTime,
  NSUInteger audioSampleFrames, NSUInteger audioChannels, float leftPeak, float rightPeak,
  float leftRMS, float rightRMS, NSUInteger audioBytes, BOOL audioPresent);

// Raw embedded audio packets are copied on the DeckLink callback thread before
// the SDK packet is released. Samples are interleaved signed 32-bit PCM when
// this handler is used (48 kHz, two channels, little-endian native bytes).
typedef void (^UltracamRawAudioHandler)(NSData *_Nullable samples, CMTime audioPacketTime,
  NSUInteger audioSampleFrames, NSUInteger audioChannels, NSUInteger bytesPerSample);

// Calls start/stop on one control queue. Frames execute on Blackmagic's
// callback thread; events may also use the native control queue or, for a
// device removal, the discovery queue. Handlers must return promptly: retain
// the CVPixelBuffer for asynchronous work. The pixel buffer owns the
// underlying DeckLink frame until its final release.
// Never call stop() synchronously from a handler (it waits for callbacks).
@interface UltracamBackend : NSObject
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
#endif

NS_ASSUME_NONNULL_END
