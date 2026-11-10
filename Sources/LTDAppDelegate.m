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
#import "LTDAppDelegate.h"
#import "LTDMapView.h"
#import "LTDVehicle.h"
#import "LTDFeedClient.h"

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

- (void)presentWelcomeSheet {
    NSWindow *sheet = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 440, 264)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    sheet.title = @"Welcome";
    NSView *content = sheet.contentView;

    [content addSubview:[self welcomeLabelWithText:@"Live Transit Detroit"
                                              font:[NSFont boldSystemFontOfSize:20.0]
                                             frame:NSMakeRect(20, 196, 400, 28)]];
    [content addSubview:[self welcomeLabelWithText:@"Detroit Automation Academy"
                                              font:[NSFont systemFontOfSize:12.0]
                                             frame:NSMakeRect(20, 172, 400, 18)]];
    // The version line (SDS-10 10.2.1): the shipped build string,
    // read from this bundle's Info.plist at runtime.
    [content addSubview:[self welcomeLabelWithText:
        [NSString stringWithFormat:@"Version %@", [self bundleVersionString]]
                                              font:[NSFont systemFontOfSize:12.0]
                                             frame:NSMakeRect(20, 148, 400, 18)]];
    [content addSubview:[self welcomeLabelWithText:
        @"Live regional transit for the District of Detroit — the whole "
        @"network on one map, updated from the Live Transit Detroit feed."
                                              font:[NSFont systemFontOfSize:12.0]
                                             frame:NSMakeRect(40, 84, 360, 52)]];

    NSButton *continueButton = [[NSButton alloc]
        initWithFrame:NSMakeRect(170, 24, 100, 32)];
    continueButton.title = @"Continue";
    continueButton.bezelStyle = NSBezelStyleRounded;
    continueButton.target = self;
    continueButton.action = @selector(dismissWelcomeSheet:);
    continueButton.keyEquivalent = @"\r";
    [content addSubview:continueButton];

    self.welcomeSheet = sheet;

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

- (void)dismissWelcomeSheet:(id)sender {
    (void)sender;
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

- (void)updateStatusLine {
    // ONE presentation (scope ruling 2026-11-07): the whole merged
    // network is "the Live Transit Detroit feed" — a single stamp, a
    // single total vehicle count. No per-source breakdown is shown.
    NSString *stamp = self.feedGeneratedAt ?: @"—";
    NSString *cachedSuffix = self.showingCachedData ? @"  •  cached" : @"";
    NSString *alertSuffix = self.alertCount > 0
        ? [NSString stringWithFormat:@"  •  %lu service alerts",
              (unsigned long)self.alertCount]
        : @"";
    self.statusLabel.stringValue = [NSString stringWithFormat:
        @"Live Transit Detroit feed %@  •  %lu vehicles%@%@",
        stamp, (unsigned long)self.vehicles.count, alertSuffix, cachedSuffix];
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
