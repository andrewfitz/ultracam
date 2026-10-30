#import <AppKit/AppKit.h>
#import "../Sources/SonyCameraControl.h"

/// Optional read-only hardware check, kept separate from automated tests.
@interface SonyHardwareSmoke : NSObject
@property UCSonyCameraControl *backend;
@property NSArray<NSDictionary *> *cameras;
@property NSUInteger index;
@property BOOL readSettings;
@property BOOL failed;
@property BOOL done;
@property NSString *address;
@property NSString *macAddress;
@property NSUInteger expectedCameras;
@property BOOL rescan;
- (void)start;
@end

@implementation SonyHardwareSmoke
- (void)finish {
  [self.backend shutdown:^(NSString *json, NSString *error) {
    (void)json;
    if (error) { fprintf(stderr, "Cleanup: %s\n", error.UTF8String); self.failed = YES; }
    else puts("SDK shutdown completed.");
    self.done = YES;
  }];
}
- (void)connectNext {
  if (self.index >= self.cameras.count) { [self finish]; return; }
  NSDictionary *camera = self.cameras[self.index++];
  if ([camera[@"authentication"] boolValue]) {
    printf("%s: camera access credentials required; connection skipped.\n", [camera[@"model"] UTF8String]);
    [self connectNext]; return;
  }
  NSString *feed = [NSString stringWithFormat:@"hardware-test-%lu", (unsigned long)self.index];
  [self.backend connectFeed:feed camera:camera[@"id"] address:camera[@"address"] authentication:[camera[@"authentication"] boolValue] user:@"" password:@"" fingerprint:camera[@"fingerprint"]
    completion:^(NSString *json, NSString *error) {
      if (error) { fprintf(stderr, "Connect %s: %s\n", [camera[@"id"] UTF8String], error.UTF8String); self.failed = YES; [self connectNext]; return; }
      NSArray *properties = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
      printf("Connected %s (%s); %lu supported settings/readouts:\n", [camera[@"model"] UTF8String], [camera[@"id"] UTF8String], (unsigned long)properties.count);
      for (NSDictionary *property in properties) {
        printf("  %s: %s [%s, %lu choices]\n", [property[@"title"] UTF8String], [property[@"label"] UTF8String],
          [property[@"writable"] boolValue] ? "editable" : "read-only", (unsigned long)[property[@"choices"] count]);
      }
      [self.backend refreshFeed:feed completion:^(NSString *refreshed, NSString *readError) {
        if (readError) { fprintf(stderr, "Refresh: %s\n", readError.UTF8String); self.failed = YES; }
        else printf("Manual refresh succeeded (%lu bytes).\n", (unsigned long)[refreshed lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        [self connectNext]; // Keep camera one connected while opening camera two.
      }];
    }];
}
- (void)start {
  self.backend = [UCSonyCameraControl new];
  self.backend.eventHandler = ^(NSString *feed, NSString *kind, NSString *message) {
    if (![kind isEqualToString:@"changed"]) printf("Event %s: %s (%s)\n", feed.UTF8String, kind.UTF8String, message.UTF8String);
  };
  if (self.address.length) {
    printf("Checking FX3 directly at %s; no credentials or setting changes.\n", self.address.UTF8String);
    [self.backend prepareCameraAtAddress:self.address macAddress:self.macAddress authentication:YES completion:^(NSString *json, NSString *error) {
      if (error) { fprintf(stderr, "Direct camera: %s\n", error.UTF8String); self.failed = YES; [self finish]; return; }
      NSDictionary *camera = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
      self.cameras = @[camera];
      printf("Direct identity verified: %s | %s | %s | fingerprint bytes: %lu\n", [camera[@"model"] UTF8String],
        [camera[@"address"] UTF8String], [camera[@"id"] UTF8String], (unsigned long)[camera[@"fingerprint"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
      if (self.readSettings) [self connectNext]; else [self finish];
    }];
    return;
  }
  puts("Starting Sony network discovery; no exposure/focus/recording settings will be changed.");
  [self.backend discover:^(NSString *json, NSString *error) {
    if (error) { fprintf(stderr, "Discovery: %s\n", error.UTF8String); self.failed = YES; [self finish]; return; }
    self.cameras = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    printf("Network cameras discovered: %lu\n", (unsigned long)self.cameras.count);
    if (self.cameras.count < self.expectedCameras) {
      fprintf(stderr, "Expected at least %lu cameras.\n", (unsigned long)self.expectedCameras);
      self.failed = YES;
    }
    for (NSDictionary *camera in self.cameras) {
      printf("%s | %s | %s | authentication: %s | fingerprint bytes: %lu\n", [(camera[@"name"] ?: camera[@"model"]) UTF8String],
        [camera[@"address"] UTF8String], [camera[@"id"] UTF8String], [camera[@"authentication"] boolValue] ? "required" : "not required",
        (unsigned long)[camera[@"fingerprint"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
      if ([camera[@"fingerprintError"] length]) {
        fprintf(stderr, "Identity check: %s\n", [camera[@"fingerprintError"] UTF8String]); self.failed = YES;
      }
    }
    if (self.rescan) {
      self.rescan = NO;
      [self.backend discover:^(NSString *nextJSON, NSString *nextError) {
        NSArray *next = nextJSON ? [NSJSONSerialization JSONObjectWithData:[nextJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        NSSet *before = [NSSet setWithArray:[self.cameras valueForKey:@"id"]];
        NSSet *after = [NSSet setWithArray:[next valueForKey:@"id"] ?: @[]];
        if (nextError || ![before isEqualToSet:after]) {
          fprintf(stderr, "Rescan changed camera identities or failed: %s\n", nextError.UTF8String ?: "camera list changed"); self.failed = YES;
        } else puts("Rescan verified the same stable camera identities.");
        if (self.readSettings) [self connectNext]; else [self finish];
      }];
      return;
    }
    if (self.readSettings) [self connectNext]; else [self finish];
  }];
}
@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    setbuf(stdout, nullptr);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
    SonyHardwareSmoke *smoke = [SonyHardwareSmoke new];
    for (int i = 1; i < argc; ++i) {
      if (strcmp(argv[i], "--read-settings") == 0) smoke.readSettings = YES;
      else if (strcmp(argv[i], "--rescan") == 0) smoke.rescan = YES;
      else if (strcmp(argv[i], "--expect-cameras") == 0 && i + 1 < argc) smoke.expectedCameras = (NSUInteger)strtoul(argv[++i], nullptr, 10);
      else if (strcmp(argv[i], "--direct") == 0 && i + 2 < argc) {
        smoke.address = [NSString stringWithUTF8String:argv[++i]];
        smoke.macAddress = [NSString stringWithUTF8String:argv[++i]];
      }
    }
    [smoke start];
    while (!smoke.done) [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
    return smoke.failed ? 1 : 0;
  }
}
