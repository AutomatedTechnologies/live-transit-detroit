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
@end

@implementation LTDAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.vehicles = [NSArray array];
    self.vehiclesFileVehicles = [NSArray array];
    self.displayFileVehicles = [NSArray array];
    [self buildWindow];

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
