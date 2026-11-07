// main.m — Live Transit Detroit (native macOS, codename:distro T1)
// Programmatic AppKit bootstrap: no XIB, no storyboard, no WebView.
#import <AppKit/AppKit.h>
#import "LTDAppDelegate.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        LTDAppDelegate *delegate = [[LTDAppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        return NSApplicationMain(argc, argv);
    }
}
