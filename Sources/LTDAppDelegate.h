// LTDAppDelegate.h — Live Transit Detroit (native macOS, codename:distro T1)
// AppKit only. Target: macOS 10.13. Memory: ARC (see README.md).
#import <AppKit/AppKit.h>

@interface LTDAppDelegate : NSObject <NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate>
@end
