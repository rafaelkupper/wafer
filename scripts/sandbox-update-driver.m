// A smoke-only executable. It uses the embedded Sparkle from a sandboxed smoke
// bundle, replacing user choices with install, then quit when installation is ready.
#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

static void evidence(NSString *message) {
    fprintf(stderr, "%s\n", message.UTF8String);
    fflush(stderr);
}

@interface SmokeDriver : SPUStandardUserDriver <SPUUpdaterDelegate, NSApplicationDelegate>
@property(strong) SPUUpdater *updater;
@end
@implementation SmokeDriver
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
    if (![identifier hasPrefix:@"dev.wafer.app."] || ![identifier containsString:@"smoke"] ||
        ![NSHomeDirectory() containsString:identifier]) {
        evidence(@"FAIL: expected a private sandbox container");
        exit(30);
    }
    evidence([@"Sandbox home: " stringByAppendingString:NSHomeDirectory()]);
    self.updater = [[SPUUpdater alloc] initWithHostBundle:NSBundle.mainBundle
        applicationBundle:NSBundle.mainBundle userDriver:self delegate:self];
    NSError *error = nil;
    if (![self.updater startUpdater:&error]) {
        evidence(error.description);
        exit(31);
    }
    [self.updater checkForUpdates];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        evidence(@"FAIL: update timed out");
        exit(32);
    });
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation {
    evidence(@"Checking local feed");
}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    evidence([@"Feed fetched, update found: " stringByAppendingString:item.versionString]);
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation {
    evidence(@"Downloading signed archive");
}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate { evidence(@"Extracting archive"); }
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {
    evidence(@"Archive validated; installer ready; deferring install until quit");
    reply(SPUUserUpdateChoiceDismiss);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        evidence(@"Quitting smoke host for installation");
        [NSApp terminate:nil];
    });
}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    evidence(error.description); exit(33);
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    evidence(error.description); exit(34);
}
- (void)dismissUpdateInstallation {}
- (BOOL)updaterShouldRelaunchApplication:(SPUUpdater *)updater { return NO; }
@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        SmokeDriver *driver = [[SmokeDriver alloc] initWithHostBundle:NSBundle.mainBundle delegate:nil];
        NSApp.delegate = driver;
        [NSApp run];
    }
    return 0;
}
