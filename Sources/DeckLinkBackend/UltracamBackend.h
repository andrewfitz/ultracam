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

typedef void (^UltracamMediaStatsHandler)(NSString *_Nullable timecode, CMTime audioPacketTime,
  NSUInteger audioSampleFrames, NSUInteger audioChannels, float leftPeak, float rightPeak,
  float leftRMS, float rightRMS, NSUInteger audioBytes, BOOL audioPresent);

// Raw embedded audio packets are copied on the DeckLink callback thread before
// the SDK packet is released. Samples are interleaved signed 32-bit PCM when
// this handler is used (48 kHz, two channels, little-endian native bytes).
typedef void (^UltracamRawAudioHandler)(NSData *_Nullable samples, CMTime audioPacketTime,
  NSUInteger audioSampleFrames, NSUInteger audioChannels, NSUInteger bytesPerSample);

// Calls start/stop on one control queue. Frames execute on Blackmagic's
// callback thread; events may also use the native control queue. Handlers must
// return promptly: reject a frame while processing is
// busy, then retain the CVPixelBuffer for any accepted asynchronous work. The
// pixel buffer owns the underlying DeckLink frame until its final release.
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
@end

#if defined(ULTRACAM_BACKEND_TESTING)
// Synthetic SDK callbacks only; never opens hardware or saves video.
FOUNDATION_EXPORT BOOL UltracamRunSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunOwnershipSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunAutoSyntheticChecks(NSError *_Nullable *_Nullable error);
FOUNDATION_EXPORT BOOL UltracamRunRawAudioSyntheticChecks(NSError *_Nullable *_Nullable error);
#endif

NS_ASSUME_NONNULL_END
