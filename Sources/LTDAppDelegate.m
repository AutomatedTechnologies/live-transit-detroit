// LTDAppDelegate.m — Live Transit Detroit (native macOS, codename:distro T1)
// Window 1100x700: status line on top, map left (~70%), vehicle table right.
// Refresh: 60 s timer. The feed itself republishes on a ~5-min cron, and
// conditional GET (LTDFeedClient) makes an unchanged poll a 304 with no
// parse and no redraw — do NOT poll faster than 60 s.
// Redraw rule: new data is diffed by vehicle diffKey + isSamePositionAs:;
// the map is told to redraw ONLY when the set or a position changed.
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
@property (nonatomic, copy) NSArray<LTDVehicle *> *vehicles;
@property (nonatomic, copy, nullable) NSString *feedGeneratedAt;
@property (nonatomic, assign) BOOL showingCachedData;
@end

@implementation LTDAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.vehicles = [NSArray array];
    [self buildWindow];

    // 1) Instant cold launch: paint last good payload from disk cache.
    NSData *cached = [LTDFeedClient cachedVehiclesData];
    if (cached.length > 0) {
        NSError *error = nil;
        NSArray<LTDVehicle *> *cachedVehicles =
            [LTDVehicle vehiclesFromFeedData:cached error:&error];
        if (cachedVehicles != nil) {
            self.feedGeneratedAt = [LTDVehicle generatedAtFromFeedData:cached];
            self.showingCachedData = YES;
            [self installVehicles:cachedVehicles forceRedraw:YES];
        }
    }

    // 2) Then fetch live; 60 s timer thereafter.
    [self refreshVehicles:nil];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
                                                           target:self
                                                         selector:@selector(refreshVehicles:)
                                                         userInfo:nil
                                                          repeats:YES];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
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

#pragma mark - Fetch + keyed diff

- (void)refreshVehicles:(NSTimer *)timer {
    (void)timer;
    [[LTDFeedClient sharedClient] fetchVehiclesWithCompletion:
        ^(NSData *data, BOOL notModified, NSError *error) {
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
        self.feedGeneratedAt = [LTDVehicle generatedAtFromFeedData:data];
        self.showingCachedData = NO;

        if ([self vehicleSetChangedFrom:self.vehicles to:fresh]) {
            [self installVehicles:fresh forceRedraw:YES];
        } else {
            // Same set, same positions: update silently (e.g. speeds),
            // no map redraw, but keep the table truthful.
            self.vehicles = fresh;
            [self.tableView reloadData];
            [self updateStatusLine];
        }
    }];
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
    NSString *stamp = self.feedGeneratedAt ?: @"—";
    NSString *suffix = self.showingCachedData ? @"  •  cached" : @"";
    self.statusLabel.stringValue = [NSString stringWithFormat:
        @"Feed %@  •  %lu vehicles%@",
        stamp, (unsigned long)self.vehicles.count, suffix];
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
