// LTDAppDelegate.m — Live Transit Detroit (native macOS, codename:distro T1)
// Window 1100x700: status line on top, map left (~70%), vehicle table right.
// Refresh: 60 s timer. The feeds republish on a ~5-min cron, and
// conditional GET (LTDFeedClient) makes an unchanged poll a 304 with no
// parse and no redraw — do NOT poll faster than 60 s.
// Redraw rule: new data is diffed by vehicle diffKey + isSamePositionAs:;
// the map is told to redraw ONLY when the set or a position changed.
//
// ONE NETWORK (scope ruling 2026-11-07): this delegate fetches BOTH
// vehicle feed files (vehicles.json and smart-display.json) plus the
// alerts file, and MERGES the two vehicle payloads into ONE array —
// one map, one table, one total count, one "Live Transit Detroit feed"
// status line. There is no layer, no toggle, no section, and no
// per-source wording anywhere in the presentation. The two per-file
// arrays below are data plumbing so each file's refresh can land
// independently; they are never shown separately.
//
// SDS-10 conformance (v0.1.0-rc3): the app is nib-less, so the main
// menu is constructed in code by -installMainMenu (the program's
// programmatic pattern: APDMainController -installMainMenu,
// DistroAppDelegate buildMenu) and the SDS-8 welcome sheet is
// presented at launch by -presentWelcomeSheet. Both the welcome
// sheet and the About panel display the version read at runtime
// from the bundle's own Info.plist (CFBundleVersion) via
// -bundleVersionString — never a hardcoded string. The bundled
// startup-sound.wav (byte-identical to the SDS-10 master) plays
// once when the welcome sheet presents.
//
// Uplift (v0.1.0-rc4, SH-3 Coding under the standing delegation
// authority of 2026-11-13; conformance listing files/06 rows
// 23/5/6/8/12/21): the vehicle-table columns are non-editable by
// construction (-addColumn: sets editable = NO); the status line
// renders the feed stamp as Detroit local time in plain language
// via NSDateFormatter (America/Detroit) with singular/plural
// correctness; the welcome sheet carries LTDWelcomeMarkView — one
// view drawing the bundle AppIcon composition (SDS-3 trimmed tile
// + bus glyph, measured from the shipped AppIcon.icns) with the
// SDS-8 signal-arc pulse (static under Reduce Motion) — plus one
// line of verified-state copy. Patterns adopted piece by piece
// from the unshipped local redesign line (commit 05e7406): the
// ISO-8601 stamp parser, the plural helper, the Reduce Motion
// check, and the welcome animation timer.
#import "LTDAppDelegate.h"
#import "LTDMapView.h"
#import "LTDVehicle.h"
#import "LTDFeedClient.h"
#import <math.h>

// LTDWelcomeMarkView — the SDS-8 welcome mark (uplift T3, listing
// rows 8 + 12). ONE view draws the bundle AppIcon composition —
// the SDS-3 trimmed construction (white rounded tile, bounding box
// (92,92)–(931,931) at the 1024 master scale, corner radius 185,
// #d8d8d8 hairline) carrying the ink bus glyph — per SDS-10
// 10.1.2's one-view pattern (the DistroLogoView pattern). Glyph
// geometry is measured from the shipped AppIcon.icns 1024 px
// rendition of v0.1.0-rc3: body (287,262) 449×449 r≈70, windshield
// (347,322) 330×120 r30, headlights at (397,610) and (627,610)
// r34, grille (472,566) 80×92, wheels (347,711) and (587,711)
// 89×44. The SDS-8 signal-arc pulse radiates from the tile's top
// corner into the transparent margin: two quarter arcs whose alpha
// pulses while animated; phase < 0 draws them static at full
// strength (Reduce Motion). Flipped coordinates match the icon
// master's (y down).
@interface LTDWelcomeMarkView : NSView
@property (nonatomic, assign) double phase;
@end

@implementation LTDWelcomeMarkView

- (BOOL)isFlipped {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGFloat s = fmin(NSWidth(self.bounds), NSHeight(self.bounds)) / 1024.0;
    CGFloat ox = (NSWidth(self.bounds) - 1024.0 * s) / 2.0;
    CGFloat oy = (NSHeight(self.bounds) - 1024.0 * s) / 2.0;
    NSColor *ink = [NSColor colorWithCalibratedWhite:0.067 alpha:1.0];
    NSColor *paper = [NSColor colorWithCalibratedWhite:1.0 alpha:1.0];

    // Tile (SDS-3 trimmed construction of record).
    NSRect tile = NSMakeRect(ox + 92.0 * s, oy + 92.0 * s,
                             840.0 * s, 840.0 * s);
    NSBezierPath *tilePath =
        [NSBezierPath bezierPathWithRoundedRect:tile
                                        xRadius:185.0 * s
                                        yRadius:185.0 * s];
    [paper setFill];
    [tilePath fill];
    [[NSColor colorWithCalibratedWhite:0.847 alpha:1.0] setStroke];
    tilePath.lineWidth = 3.0 * s;
    [tilePath stroke];

    // Bus glyph, ink masses.
    [ink setFill];
    [[NSBezierPath bezierPathWithRoundedRect:
        NSMakeRect(ox + 287.0 * s, oy + 262.0 * s, 449.0 * s, 449.0 * s)
                                     xRadius:70.0 * s yRadius:70.0 * s] fill];
    NSRectFill(NSMakeRect(ox + 347.0 * s, oy + 711.0 * s, 89.0 * s, 44.0 * s));
    NSRectFill(NSMakeRect(ox + 587.0 * s, oy + 711.0 * s, 89.0 * s, 44.0 * s));

    // Paper cutouts: windshield, headlights, grille.
    [paper setFill];
    [[NSBezierPath bezierPathWithRoundedRect:
        NSMakeRect(ox + 347.0 * s, oy + 322.0 * s, 330.0 * s, 120.0 * s)
                                     xRadius:30.0 * s yRadius:30.0 * s] fill];
    [[NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(ox + 363.0 * s, oy + 576.0 * s, 68.0 * s, 68.0 * s)] fill];
    [[NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(ox + 593.0 * s, oy + 576.0 * s, 68.0 * s, 68.0 * s)] fill];
    NSRectFill(NSMakeRect(ox + 472.0 * s, oy + 566.0 * s, 80.0 * s, 92.0 * s));

    // Signal arcs (SDS-8 pulse): quarter arcs NE of the tile's top
    // corner (932, 92) — in flipped coordinates NE is +x, −y, so the
    // arc is swept parametrically to keep the quadrant exact.
    double pulse  = self.phase < 0 ? 1.0 : 0.55 + 0.45 * sin(self.phase);
    double pulse2 = self.phase < 0 ? 1.0 : 0.55 + 0.45 * sin(self.phase - 1.2);
    const double radii[2] = {55.0, 85.0};
    const double alphas[2] = {pulse, pulse2};
    for (int i = 0; i < 2; i++) {
        NSBezierPath *arc = [NSBezierPath bezierPath];
        for (int step = 0; step <= 24; step++) {
            double t = (M_PI / 2.0) * (step / 24.0);
            NSPoint pt = NSMakePoint(ox + (932.0 + radii[i] * cos(t)) * s,
                                     oy + (92.0 - radii[i] * sin(t)) * s);
            if (step == 0) [arc moveToPoint:pt];
            else           [arc lineToPoint:pt];
        }
        arc.lineWidth = 26.0 * s;
        arc.lineCapStyle = NSRoundLineCapStyle;
        [[ink colorWithAlphaComponent:0.35 + 0.65 * alphas[i]] setStroke];
        [arc stroke];
    }
}

@end

@interface LTDAppDelegate ()
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) LTDMapView *mapView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTimer *refreshTimer;
// The MERGED vehicle list — the only list any view ever sees.
@property (nonatomic, copy) NSArray<LTDVehicle *> *vehicles;
// Per-file plumbing (never presented separately): the latest parsed
// payload of each vehicle feed file, merged by -mergedVehicles.
@property (nonatomic, copy) NSArray<LTDVehicle *> *vehiclesFileVehicles;
@property (nonatomic, copy) NSArray<LTDVehicle *> *displayFileVehicles;
@property (nonatomic, copy, nullable) NSString *vehiclesFileStamp;
@property (nonatomic, copy, nullable) NSString *displayFileStamp;
@property (nonatomic, copy, nullable) NSString *feedGeneratedAt;
@property (nonatomic, assign) NSUInteger alertCount;
@property (nonatomic, assign) BOOL showingCachedData;
@property (nonatomic, strong) NSWindow *welcomeSheet;
@property (nonatomic, strong) NSSound *startupSound;
@property (nonatomic, strong) LTDWelcomeMarkView *welcomeMark;
@property (nonatomic, strong) NSTimer *welcomeTimer;
@property (nonatomic, assign) double welcomePhase;
@end

@implementation LTDAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.vehicles = [NSArray array];
    self.vehiclesFileVehicles = [NSArray array];
    self.displayFileVehicles = [NSArray array];
    [self installMainMenu];
    [self buildWindow];
    [self presentWelcomeSheet];

    // 1) Instant cold launch: paint the last good MERGED set from the
    // per-file disk caches (both vehicle files together restore the
    // one network list — restoring only one would show a partial map).
    BOOL restoredAny = NO;
    NSData *cachedVehicles = [LTDFeedClient cachedVehiclesData];
    if (cachedVehicles.length > 0) {
        NSArray<LTDVehicle *> *parsed =
            [LTDVehicle vehiclesFromFeedData:cachedVehicles error:nil];
        if (parsed != nil) {
            self.vehiclesFileVehicles = parsed;
            self.vehiclesFileStamp = [LTDVehicle generatedAtFromFeedData:cachedVehicles];
            restoredAny = YES;
        }
    }
    NSData *cachedDisplay = [LTDFeedClient cachedSmartDisplayData];
    if (cachedDisplay.length > 0) {
        NSArray<LTDVehicle *> *parsed =
            [LTDVehicle vehiclesFromFeedData:cachedDisplay error:nil];
        if (parsed != nil) {
            self.displayFileVehicles = parsed;
            self.displayFileStamp = [LTDVehicle generatedAtFromFeedData:cachedDisplay];
            restoredAny = YES;
        }
    }
    NSData *cachedAlerts = [LTDFeedClient cachedAlertsData];
    if (cachedAlerts.length > 0) {
        self.alertCount = [self alertCountFromFeedData:cachedAlerts];
        restoredAny = restoredAny || self.alertCount > 0;
    }
    if (restoredAny) {
        self.showingCachedData = YES;
        [self refreshFeedStamp];
        [self installVehicles:[self mergedVehicles] forceRedraw:YES];
    }

    // 2) Then fetch live; 60 s timer thereafter.
    [self refreshFeeds:nil];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
                                                           target:self
                                                         selector:@selector(refreshFeeds:)
                                                         userInfo:nil
                                                          repeats:YES];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.welcomeTimer invalidate];
    self.welcomeTimer = nil;
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    [self.startupSound stop];
    self.startupSound = nil;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

#pragma mark - Main menu bar (SDS-10 10.4, code-constructed)

// The shipped build string, read from the bundle's own Info.plist at
// runtime (SDS-10 10.2.2). CI stamps CFBundleVersion with the release
// tag at packaging, so the welcome sheet and the About panel show the
// shipped build (e.g. v0.1.0-rc3) — never a hardcoded string.
- (NSString *)bundleVersionString {
    NSString *version =
        [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
    return version.length > 0 ? version : @"—";
}

- (NSMenuItem *)menuItemWithTitle:(NSString *)title
                           action:(SEL)action
                    keyEquivalent:(NSString *)keyEquivalent
                           target:(id)target {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:action
                                           keyEquivalent:keyEquivalent];
    item.target = target;
    return item;
}

// Every item below is wired: app-menu items target NSApp (standard
// actions) or this controller (About, Refresh); File/Window items use
// the standard first-responder actions; Help items open real pages
// via NSWorkspace. There is no Edit menu: the app has no editable
// text field anywhere (the status line is a label and the vehicle
// table is read-only), so Edit items would be permanently dead —
// the Distro precedent (DistroAppDelegate buildMenu).
- (void)installMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];

    // App menu.
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Live Transit Detroit"];
    [appMenu addItem:[self menuItemWithTitle:@"About Live Transit Detroit"
                                      action:@selector(showAboutPanel:)
                               keyEquivalent:@""
                                      target:self]];
    [appMenu addItem:[self menuItemWithTitle:@"Refresh Now"
                                      action:@selector(refreshFromMenu:)
                               keyEquivalent:@"r"
                                      target:self]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[self menuItemWithTitle:@"Hide Live Transit Detroit"
                                      action:@selector(hide:)
                               keyEquivalent:@"h"
                                      target:NSApp]];
    NSMenuItem *hideOthers = [self menuItemWithTitle:@"Hide Others"
                                              action:@selector(hideOtherApplications:)
                                       keyEquivalent:@"h"
                                              target:NSApp];
    hideOthers.keyEquivalentModifierMask =
        NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [appMenu addItem:hideOthers];
    [appMenu addItem:[self menuItemWithTitle:@"Show All"
                                      action:@selector(unhideAllApplications:)
                               keyEquivalent:@""
                                      target:NSApp]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[self menuItemWithTitle:@"Quit Live Transit Detroit"
                                      action:@selector(terminate:)
                               keyEquivalent:@"q"
                                      target:NSApp]];
    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"Live Transit Detroit"
                                                     action:nil
                                              keyEquivalent:@""];
    appItem.submenu = appMenu;
    [mainMenu addItem:appItem];

    // File menu.
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItem:[self menuItemWithTitle:@"Close Window"
                                       action:@selector(performClose:)
                                keyEquivalent:@"w"
                                       target:nil]];
    NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"File"
                                                      action:nil
                                               keyEquivalent:@""];
    fileItem.submenu = fileMenu;
    [mainMenu addItem:fileItem];

    // Window menu (registered as the app's windows menu).
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItem:[self menuItemWithTitle:@"Minimize"
                                         action:@selector(performMiniaturize:)
                                  keyEquivalent:@"m"
                                         target:nil]];
    [windowMenu addItem:[self menuItemWithTitle:@"Zoom"
                                         action:@selector(performZoom:)
                                  keyEquivalent:@""
                                         target:nil]];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItem:[self menuItemWithTitle:@"Bring All to Front"
                                         action:@selector(arrangeInFront:)
                                  keyEquivalent:@""
                                         target:NSApp]];
    NSMenuItem *windowItem = [[NSMenuItem alloc] initWithTitle:@"Window"
                                                        action:nil
                                                 keyEquivalent:@""];
    windowItem.submenu = windowMenu;
    [mainMenu addItem:windowItem];
    NSApp.windowsMenu = windowMenu;

    // Help menu (registered as the app's help menu).
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    [helpMenu addItem:[self menuItemWithTitle:@"Live Transit Detroit Help"
                                       action:@selector(openHelp:)
                                keyEquivalent:@""
                                       target:self]];
    [helpMenu addItem:[self menuItemWithTitle:@"Detroit Automation Academy Website"
                                       action:@selector(openAcademyWebsite:)
                                keyEquivalent:@""
                                       target:self]];
    NSMenuItem *helpItem = [[NSMenuItem alloc] initWithTitle:@"Help"
                                                      action:nil
                                               keyEquivalent:@""];
    helpItem.submenu = helpMenu;
    [mainMenu addItem:helpItem];
    NSApp.helpMenu = helpMenu;

    [NSApp setMainMenu:mainMenu];
}

- (void)showAboutPanel:(id)sender {
    (void)sender;
    NSAlert *about = [[NSAlert alloc] init];
    about.messageText = @"Live Transit Detroit";
    about.informativeText = [NSString stringWithFormat:
        @"Version %@\nDetroit Automation Academy\n\n"
        @"Live regional transit for the District of Detroit — one "
        @"network on one map, native on High Sierra.",
        [self bundleVersionString]];
    [about addButtonWithTitle:@"OK"];
    [about runModal];
}

- (void)refreshFromMenu:(id)sender {
    (void)sender;
    [self refreshFeeds:nil];
}

- (void)openHelp:(id)sender {
    (void)sender;
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL URLWithString:@"https://detroitautomationacademy.com/live-transit-detroit/"]];
}

- (void)openAcademyWebsite:(id)sender {
    (void)sender;
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL URLWithString:@"https://detroitautomationacademy.com/"]];
}

#pragma mark - SDS-8 welcome sheet (SDS-10 10.2 version line + 10.3 sound)

- (NSTextField *)welcomeLabelWithText:(NSString *)text
                                 font:(NSFont *)font
                                frame:(NSRect)frame {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.stringValue = text;
    label.font = font;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    label.alignment = NSTextAlignmentCenter;
    return label;
}

- (BOOL)reduceMotionEnabled {
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    if ([ws respondsToSelector:@selector(accessibilityDisplayShouldReduceMotion)]) {
        return ws.accessibilityDisplayShouldReduceMotion;
    }
    return NO;
}

- (void)presentWelcomeSheet {
    NSWindow *sheet = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 440, 340)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    sheet.title = @"Welcome";
    NSView *content = sheet.contentView;

    // The mark (SDS-8 + SDS-10 10.1.2, uplift T3): one view drawing
    // the bundle AppIcon composition with the signal-arc pulse —
    // animated unless Reduce Motion is on, static then.
    BOOL reduceMotion = [self reduceMotionEnabled];
    self.welcomeMark = [[LTDWelcomeMarkView alloc]
        initWithFrame:NSMakeRect(176, 232, 88, 88)];
    self.welcomeMark.phase = reduceMotion ? -1.0 : 0.0;
    [content addSubview:self.welcomeMark];

    [content addSubview:[self welcomeLabelWithText:@"Live Transit Detroit"
                                              font:[NSFont boldSystemFontOfSize:20.0]
                                             frame:NSMakeRect(20, 198, 400, 28)]];
    [content addSubview:[self welcomeLabelWithText:@"Detroit Automation Academy"
                                              font:[NSFont systemFontOfSize:12.0]
                                             frame:NSMakeRect(20, 176, 400, 18)]];
    // The version line (SDS-10 10.2.1): the shipped build string,
    // read from this bundle's Info.plist at runtime.
    [content addSubview:[self welcomeLabelWithText:
        [NSString stringWithFormat:@"Version %@", [self bundleVersionString]]
                                              font:[NSFont systemFontOfSize:12.0]
                                             frame:NSMakeRect(20, 154, 400, 18)]];
    // Verified-state copy (SDS-8): the catalog state of this build
    // and its rig state, stated as fact — the release candidate has
    // not had its High Sierra rig pass (listing rows 13 + 24).
    [content addSubview:[self welcomeLabelWithText:
        @"Release candidate — High Sierra verification pending"
                                              font:[NSFont systemFontOfSize:12.0]
                                             frame:NSMakeRect(20, 132, 400, 18)]];
    [content addSubview:[self welcomeLabelWithText:
        @"Live regional transit for the District of Detroit — the whole "
        @"network on one map, updated from the Live Transit Detroit feed."
                                              font:[NSFont systemFontOfSize:12.0]
                                             frame:NSMakeRect(40, 76, 360, 44)]];

    NSButton *continueButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(170, 24, 100, 32)];
    continueButton.title = @"Continue";
    continueButton.bezelStyle = NSBezelStyleRounded;
    continueButton.target = self;
    continueButton.action = @selector(dismissWelcomeSheet:);
    continueButton.keyEquivalent = @"\r";
    [content addSubview:continueButton];

    self.welcomeSheet = sheet;

    if (!reduceMotion) {
        self.welcomePhase = 0.0;
        self.welcomeTimer = [NSTimer scheduledTimerWithTimeInterval:0.06
                                                               target:self
                                                             selector:@selector(tickWelcomeAnimation:)
                                                             userInfo:nil
                                                              repeats:YES];
    }

    // Startup sound (SDS-10 10.3): the bundled asset, byte-identical
    // to the library master, plays once as the sheet presents; a
    // missing asset is a silent welcome, never an error.
    NSString *soundPath = [[NSBundle mainBundle] pathForResource:@"startup-sound"
                                                          ofType:@"wav"];
    if (soundPath != nil) {
        self.startupSound = [[NSSound alloc] initWithContentsOfFile:soundPath
                                                        byReference:YES];
        [self.startupSound play];
    }

    [self.window beginSheet:sheet completionHandler:nil];
}

- (void)tickWelcomeAnimation:(NSTimer *)timer {
    (void)timer;
    self.welcomePhase += 0.18;
    self.welcomeMark.phase = self.welcomePhase;
    [self.welcomeMark setNeedsDisplay:YES];
}

- (void)dismissWelcomeSheet:(id)sender {
    (void)sender;
    [self.welcomeTimer invalidate];
    self.welcomeTimer = nil;
    if (self.welcomeSheet != nil) {
        [self.window endSheet:self.welcomeSheet];
        self.welcomeSheet = nil;
    }
}

#pragma mark - Window / layout (programmatic, no XIB)

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 1100, 700);
    self.window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.window.title = @"Live Transit Detroit";
    self.window.minSize = NSMakeSize(700, 450);
    [self.window center];

    NSView *content = self.window.contentView;
    CGFloat width = NSWidth(frame);
    CGFloat height = NSHeight(frame);
    const CGFloat statusH = 24.0;
    const CGFloat bodyH = height - statusH;
    const CGFloat mapW = floor(width * 0.70);

    // Status line (top; flipped layout is manual — content view is not
    // flipped, so top = height - statusH).
    self.statusLabel = [[NSTextField alloc]
        initWithFrame:NSMakeRect(8, height - statusH, width - 16, statusH - 4)];
    self.statusLabel.bezeled = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.editable = NO;
    self.statusLabel.font = [NSFont systemFontOfSize:12.0];
    self.statusLabel.stringValue = @"Live Transit Detroit — loading…";
    self.statusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:self.statusLabel];

    // Map (left ~70%).
    self.mapView = [[LTDMapView alloc] initWithFrame:NSMakeRect(0, 0, mapW, bodyH)];
    self.mapView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:self.mapView];

    // Vehicle table (right ~30%).
    NSScrollView *scroll = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(mapW, 0, width - mapW, bodyH)];
    scroll.hasVerticalScroller = YES;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.borderType = NSBezelBorder;

    self.tableView = [[NSTableView alloc] initWithFrame:scroll.bounds];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.usesAlternatingRowBackgroundColors = YES;
    [self addColumn:@"route" title:@"Route" width:52];
    [self addColumn:@"destination" title:@"Destination" width:150];
    [self addColumn:@"speed" title:@"mph" width:40];
    scroll.documentView = self.tableView;
    [content addSubview:scroll];

    [self.window makeKeyAndOrderFront:nil];
}

- (void)addColumn:(NSString *)identifier title:(NSString *)title width:(CGFloat)width {
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
    column.title = title;
    column.width = width;
    // Read-only live data (uplift T1, listing row 23): NSTableColumn
    // is editable by default construction, which put an edit
    // affordance on the live table even though no setObjectValue
    // path exists. Non-editable by construction, all three columns
    // (this helper is the single construction path).
    column.editable = NO;
    [self.tableView addTableColumn:column];
}

#pragma mark - Fetch + merge + keyed diff

// Every refresh fetches ALL THREE feed files: both vehicle files and
// the alerts file. Each lands independently; a 304 or an error on one
// file leaves that file's last good payload in place and never blocks
// the others.
- (void)refreshFeeds:(NSTimer *)timer {
    (void)timer;
    [[LTDFeedClient sharedClient] fetchVehiclesWithCompletion:
        ^(NSData *data, BOOL notModified, NSError *error) {
        [self handleVehicleFeedData:data notModified:notModified
                              error:error displayFile:NO];
    }];
    [[LTDFeedClient sharedClient] fetchSmartDisplayWithCompletion:
        ^(NSData *data, BOOL notModified, NSError *error) {
        [self handleVehicleFeedData:data notModified:notModified
                              error:error displayFile:YES];
    }];
    [[LTDFeedClient sharedClient] fetchAlertsWithCompletion:
        ^(NSData *data, BOOL notModified, NSError *error) {
        if (notModified || error != nil || data == nil) {
            [self updateStatusLine]; // keep last good alerts state
            return;
        }
        self.alertCount = [self alertCountFromFeedData:data];
        self.showingCachedData = NO;
        [self updateStatusLine];
    }];
}

// One vehicle feed file landed: parse it, swap it into its plumbing
// slot, rebuild the ONE merged list, and redraw only on a real change.
- (void)handleVehicleFeedData:(NSData *)data
                  notModified:(BOOL)notModified
                        error:(NSError *)error
                  displayFile:(BOOL)isDisplayFile {
    if (notModified) {
        [self updateStatusLine]; // 304: no parse, no redraw
        return;
    }
    if (error != nil || data == nil) {
        [self updateStatusLine]; // keep showing last good data
        return;
    }
    NSError *parseError = nil;
    NSArray<LTDVehicle *> *fresh =
        [LTDVehicle vehiclesFromFeedData:data error:&parseError];
    if (fresh == nil) {
        [self updateStatusLine];
        return;
    }
    if (isDisplayFile) {
        self.displayFileVehicles = fresh;
        self.displayFileStamp = [LTDVehicle generatedAtFromFeedData:data];
    } else {
        self.vehiclesFileVehicles = fresh;
        self.vehiclesFileStamp = [LTDVehicle generatedAtFromFeedData:data];
    }
    self.showingCachedData = NO;
    [self refreshFeedStamp];

    NSArray<LTDVehicle *> *merged = [self mergedVehicles];
    if ([self vehicleSetChangedFrom:self.vehicles to:merged]) {
        [self installVehicles:merged forceRedraw:YES];
    } else {
        // Same merged set, same positions: update silently (e.g.
        // speeds), no map redraw, but keep the table truthful.
        self.vehicles = merged;
        [self.tableView reloadData];
        [self updateStatusLine];
    }
}

// THE merge: the two feed files' vehicles become ONE list — sample
// payloads total 58 + 86 = 144 vehicles in a single map, a single
// table, a single count. Deduped by diffKey so a vehicle reported by
// both files (not expected, but cheap to guard) appears exactly once.
- (NSArray<LTDVehicle *> *)mergedVehicles {
    NSMutableArray<LTDVehicle *> *merged =
        [NSMutableArray arrayWithCapacity:
            self.vehiclesFileVehicles.count + self.displayFileVehicles.count];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:merged.count];
    for (LTDVehicle *v in self.vehiclesFileVehicles) {
        if (![seen containsObject:v.diffKey]) {
            [seen addObject:v.diffKey];
            [merged addObject:v];
        }
    }
    for (LTDVehicle *v in self.displayFileVehicles) {
        if (![seen containsObject:v.diffKey]) {
            [seen addObject:v.diffKey];
            [merged addObject:v];
        }
    }
    return [merged copy];
}

// The merged list carries ONE stamp: the newer of the two files'
// generated_at values (same ISO-8601 format, so string order works).
- (void)refreshFeedStamp {
    NSString *a = self.vehiclesFileStamp;
    NSString *b = self.displayFileStamp;
    if (a == nil)      self.feedGeneratedAt = b;
    else if (b == nil) self.feedGeneratedAt = a;
    else               self.feedGeneratedAt = [a compare:b] == NSOrderedDescending ? a : b;
}

// Alerts envelope: {generated_at, count, alerts[{header, ...}], ...}.
// Only the count reaches the presentation (one status line); alert
// detail UI is a later tranche.
- (NSUInteger)alertCountFromFeedData:(NSData *)data {
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) return self.alertCount;
    id alerts = [(NSDictionary *)root objectForKey:@"alerts"];
    if ([alerts isKindOfClass:[NSArray class]]) return [(NSArray *)alerts count];
    return 0;
}

// YES if the keyed set differs OR any shared vehicle's position differs.
- (BOOL)vehicleSetChangedFrom:(NSArray<LTDVehicle *> *)oldList
                           to:(NSArray<LTDVehicle *> *)newList {
    if (oldList.count != newList.count) return YES;
    NSMutableDictionary<NSString *, LTDVehicle *> *byKey =
        [NSMutableDictionary dictionaryWithCapacity:oldList.count];
    for (LTDVehicle *v in oldList) byKey[v.diffKey] = v;
    for (LTDVehicle *fresh in newList) {
        LTDVehicle *old = byKey[fresh.diffKey];
        if (old == nil) return YES;
        if (![fresh isSamePositionAs:old]) return YES;
    }
    return NO;
}

- (void)installVehicles:(NSArray<LTDVehicle *> *)vehicles forceRedraw:(BOOL)force {
    self.vehicles = vehicles;
    self.mapView.vehicles = vehicles;
    if (force) [self.mapView setNeedsDisplay:YES];
    [self.tableView reloadData];
    [self updateStatusLine];
}

// The feed's generated_at stamp is an ISO-8601 UTC string. Parse it
// to a real NSDate (parser pattern adopted from the unshipped
// redesign line, commit 05e7406) so the status line can render it
// as Detroit local time — the raw string never reaches a surface
// (uplift T1, listing row 5).
- (NSDate *)dateFromFeedStamp:(NSString *)stamp {
    if (stamp.length == 0) return nil;
    static NSArray<NSDateFormatter *> *formatters = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSDateFormatter *> *list = [NSMutableArray array];
        for (NSString *format in @[@"yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
                                   @"yyyy-MM-dd'T'HH:mm:ssXXXXX",
                                   @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
                                   @"yyyy-MM-dd'T'HH:mm:ss'Z'"]) {
            NSDateFormatter *f = [[NSDateFormatter alloc] init];
            f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            f.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
            f.dateFormat = format;
            [list addObject:f];
        }
        formatters = [list copy];
    });
    for (NSDateFormatter *f in formatters) {
        NSDate *date = [f dateFromString:stamp];
        if (date != nil) return date;
    }
    return nil;
}

// Singular/plural correctness for counted nouns in the status line
// (uplift T1, listing row 6: "1 service alert", never "1 service
// alerts"). Helper adopted from the redesign line (commit 05e7406).
- (NSString *)plural:(NSUInteger)count singular:(NSString *)one plural:(NSString *)many {
    return [NSString stringWithFormat:@"%lu %@",
            (unsigned long)count, count == 1 ? one : many];
}

- (void)updateStatusLine {
    // ONE presentation (scope ruling 2026-11-07): the whole merged
    // network is "the Live Transit Detroit feed" — a single stamp, a
    // single total vehicle count. No per-source breakdown is shown.
    // The stamp renders as Detroit local time in plain language
    // (NSDateFormatter pinned to America/Detroit, "Updated 5:00 PM
    // EST"); saved (cached) data says so in words, per SDS-2.
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:@"Live Transit Detroit feed"];
    NSDate *date = [self dateFromFeedStamp:self.feedGeneratedAt];
    if (date != nil) {
        NSDateFormatter *display = [[NSDateFormatter alloc] init];
        display.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
        display.timeZone = [NSTimeZone timeZoneWithName:@"America/Detroit"];
        display.dateFormat = @"h:mm a zzz";
        NSString *when = [display stringFromDate:date];
        [parts addObject:self.showingCachedData
            ? [NSString stringWithFormat:@"Showing saved data from %@", when]
            : [NSString stringWithFormat:@"Updated %@", when]];
    } else {
        [parts addObject:@"Loading"];
    }
    [parts addObject:[self plural:self.vehicles.count
                         singular:@"vehicle" plural:@"vehicles"]];
    if (self.alertCount > 0) {
        [parts addObject:[self plural:self.alertCount
                             singular:@"service alert" plural:@"service alerts"]];
    }
    self.statusLabel.stringValue = [parts componentsJoinedByString:@"  •  "];
}

#pragma mark - NSTableViewDataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)self.vehicles.count;
}

- (id)tableView:(NSTableView *)tableView
    objectValueForTableColumn:(NSTableColumn *)tableColumn
                          row:(NSInteger)row {
    (void)tableView;
    if (row < 0 || row >= (NSInteger)self.vehicles.count) return nil;
    LTDVehicle *v = self.vehicles[(NSUInteger)row];
    NSString *identifier = tableColumn.identifier;
    if ([identifier isEqualToString:@"route"]) return v.routeID ?: @"";
    if ([identifier isEqualToString:@"destination"]) return v.destination ?: @"";
    if ([identifier isEqualToString:@"speed"]) {
        return v.hasSpeed ? [NSString stringWithFormat:@"%.0f", v.speedMPH] : @"—";
    }
    return nil;
}

@end
