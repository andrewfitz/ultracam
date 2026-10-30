#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^UCSonyReply)(NSString * _Nullable json, NSString * _Nullable error);

/// All SDK calls run on one dedicated worker thread. Replies/events arrive on main.
@interface UCSonyCameraControl : NSObject
@property(nonatomic, copy, nullable) void (^eventHandler)(NSString *feedID, NSString *kind, NSString *message);
@property(nonatomic, readonly) BOOL available;
/// SDK build-time version constant; never initializes the SDK or contacts cameras.
@property(nonatomic, readonly, nullable) NSString *sdkVersion;
- (void)discover:(UCSonyReply)reply;
- (void)prepareCameraAtAddress:(NSString *)address macAddress:(NSString *)macAddress
               authentication:(BOOL)authentication completion:(UCSonyReply)reply
  NS_SWIFT_NAME(prepareCamera(address:macAddress:authentication:completion:));
- (void)connectFeed:(NSString *)feedID camera:(NSString *)cameraID
           address:(NSString *)address authentication:(BOOL)authentication
              user:(NSString *)user password:(NSString *)password
       fingerprint:(NSString *)fingerprint completion:(UCSonyReply)reply;
- (void)refreshFeed:(NSString *)feedID completion:(UCSonyReply)reply;
- (void)setFeed:(NSString *)feedID code:(uint32_t)code value:(uint64_t)value completion:(UCSonyReply)reply;
- (void)disconnectFeed:(NSString *)feedID completion:(UCSonyReply)reply;
/// Gracefully release every camera and the SDK; reports pending disconnects.
- (void)shutdown:(UCSonyReply)reply;
@end
NS_ASSUME_NONNULL_END
