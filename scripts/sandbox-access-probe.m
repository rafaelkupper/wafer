// Read the fixture using only a persisted app-scoped bookmark, in the smoke
// app's sandbox. The parent compares stdout byte-for-byte with the fixture.
#import <Foundation/Foundation.h>
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 22;
        NSString *identifier = @(argv[1]);
        if (![identifier hasPrefix:@"dev.wafer.app."] || ![identifier containsString:@"smoke"] ||
            ![NSHomeDirectory() containsString:identifier]) return 22;
        fprintf(stderr, "Sandbox home: %s\n", NSHomeDirectory().UTF8String);
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        for (NSDictionary *grant in [defaults arrayForKey:@"folderAccessGrants"]) {
            NSError *error = nil;
            BOOL stale = NO;
            NSURL *folder = [NSURL URLByResolvingBookmarkData:grant[@"bookmark"]
                options:NSURLBookmarkResolutionWithSecurityScope | NSURLBookmarkResolutionWithoutUI
                relativeToURL:nil bookmarkDataIsStale:&stale error:&error];
            if (![folder startAccessingSecurityScopedResource]) continue;
            NSData *data = [NSData dataWithContentsOfFile:@(argv[2]) options:0 error:&error];
            [folder stopAccessingSecurityScopedResource];
            if (data) {
                fwrite(data.bytes, 1, data.length, stdout);
                return 0;
            }
            fprintf(stderr, "%s\n", error.description.UTF8String);
        }
        return 22;
    }
}
