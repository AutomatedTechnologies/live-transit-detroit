// LTDMapView.m — see LTDMapView.h. ARC.
//
// Uplift (v0.1.0-rc4, SH-3 Coding under the standing delegation
// authority of 2026-11-13; conformance listing files/06 rows 1 + 2):
// SDS-1 surfaces — the map field is the `paper` token (#ffffff,
// SDS-1 Rule 5 + token table; High Sierra targets use the light
// ramp) and vehicle markers carry no hue (SDS-1 Rule 1): ink discs
// with a paper ring, ink bearing ticks, and ink route labels —
// legible by construction on paper. The light-ramp values are the
// unshipped redesign line's (commit 05e7406): field paper, routes
// mid-gray, core anchor darkened to remain legible on paper.
#import "LTDMapView.h"
#import <math.h>

@implementation LTDRoutePolyline
+ (instancetype)polylineWithRouteID:(NSString *)routeID
                               name:(NSString *)name
                             points:(NSArray<NSValue *> *)points {
    LTDRoutePolyline *p = [[LTDRoutePolyline alloc] init];
    p.routeID = routeID;
    p.name = name;
    p.points = points ?: [NSArray array];
    return p;
}
@end

@implementation NSValue (LTDGeoPoint)
+ (NSValue *)valueWithLTDPoint:(LTDGeoPoint)point {
    return [NSValue valueWithBytes:&point objCType:@encode(LTDGeoPoint)];
}
- (LTDGeoPoint)ltdPointValue {
    LTDGeoPoint point = {0, 0};
    [self getValue:&point];
    return point;
}
@end

@interface LTDMapView ()
@property (nonatomic, strong, nullable) NSImage *staticLayerImage;
@property (nonatomic, assign) NSSize staticLayerSize;
@property (nonatomic, assign) BOOL staticLayerDirty;
@end

// Full regional network bounds (scope ruling 2026-11-07): the default
// projection fits ALL of this, so the whole network — not a city-only
// subset — is the product the map presents.
static const double kLTDRegionMinLat = 42.11;
static const double kLTDRegionMaxLat = 42.73;
static const double kLTDRegionMinLon = -83.58;
static const double kLTDRegionMaxLon = -82.72;
// Detroit core anchor (Rosa Parks TC area), drawn on the static layer.
static const double kLTDCoreLat = 42.3314;
static const double kLTDCoreLon = -83.0458;

@implementation LTDMapView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _centerLat = (kLTDRegionMinLat + kLTDRegionMaxLat) / 2.0; // 42.42
        _centerLon = (kLTDRegionMinLon + kLTDRegionMaxLon) / 2.0; // -83.15
        _staticLayerDirty = YES;
        _staticLayerSize = NSZeroSize;
    }
    return self;
}

// Flipped: (0,0) top-left, y down — documented in the header.
- (BOOL)isFlipped {
    return YES;
}

- (void)setRoutes:(NSArray<LTDRoutePolyline *> *)routes {
    _routes = [routes copy];
    _staticLayerDirty = YES; // routes live on the static layer
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    _staticLayerDirty = YES; // static layer is rendered at view size
}

#pragma mark - Projection

// Degrees-per-pixel: fit the FULL regional bounds into the view —
// whichever span (latitude, or longitude corrected by cos(lat)) needs
// more room wins — with 5% padding so edge vehicles are not clipped.
- (double)degreesPerPixel {
    double w = NSWidth(self.bounds);
    double h = NSHeight(self.bounds);
    if (w < 1 || h < 1) return 0.001;
    double latSpan = kLTDRegionMaxLat - kLTDRegionMinLat;              // 0.62
    double lonSpan = (kLTDRegionMaxLon - kLTDRegionMinLon) *
                     cos(_centerLat * M_PI / 180.0);                   // ~0.64
    double dpp = fmax(latSpan / h, lonSpan / w);
    return dpp * 1.05;
}

- (NSPoint)pointForLat:(double)lat lon:(double)lon {
    double dpp = [self degreesPerPixel];
    double cosLat = cos(_centerLat * M_PI / 180.0);
    NSRect b = self.bounds;
    double cx = NSMidX(b);
    double cy = NSMidY(b);
    double x = cx + ((lon - _centerLon) * cosLat) / dpp;
    // Flipped view: larger latitude must appear higher (smaller y).
    double y = cy - ((lat - _centerLat) / dpp);
    return NSMakePoint(x, y);
}

#pragma mark - Static layer (routes + border), cached offscreen

- (void)rebuildStaticLayerIfNeeded {
    NSSize size = self.bounds.size;
    if (!_staticLayerDirty && _staticLayerImage != nil &&
        NSEqualSizes(_staticLayerSize, size)) {
        return;
    }
    if (size.width < 1 || size.height < 1) return;

    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image lockFocus];

    // Background: the SDS-1 `paper` token (Rule 5 — light ramp on
    // High Sierra targets). Was white 0.08, a black void.
    [[NSColor colorWithCalibratedWhite:1.0 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(0, 0, size.width, size.height));

    // Routes.
    [[NSColor colorWithCalibratedWhite:0.55 alpha:0.8] setStroke];
    for (LTDRoutePolyline *route in _routes ?: @[]) {
        if (route.points.count < 2) continue;
        NSBezierPath *path = [NSBezierPath bezierPath];
        path.lineWidth = 1.5;
        BOOL first = YES;
        for (NSValue *value in route.points) {
            LTDGeoPoint gp = [value ltdPointValue];
            NSPoint pt = [self pointForLat:gp.lat lon:gp.lon];
            if (first) { [path moveToPoint:pt]; first = NO; }
            else       { [path lineToPoint:pt]; }
        }
        [path stroke];
    }

    // Detroit core anchor: a small ring + label at the core point, so
    // the regional framing keeps the city centre legible as its anchor.
    NSPoint core = [self pointForLat:kLTDCoreLat lon:kLTDCoreLon];
    // Anchor ring + label darkened from white 0.85 (calibrated for
    // the old black field) to a legible gray on paper.
    [[NSColor colorWithCalibratedWhite:0.35 alpha:0.9] setStroke];
    NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(core.x - 4.0, core.y - 4.0, 8.0, 8.0)];
    ring.lineWidth = 1.5;
    [ring stroke];
    NSDictionary *coreAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10.0],
        NSForegroundColorAttributeName:
            [NSColor colorWithCalibratedWhite:0.35 alpha:0.9],
    };
    [@"DETROIT" drawAtPoint:NSMakePoint(core.x + 7.0, core.y - 5.0)
             withAttributes:coreAttrs];

    // Border.
    [[NSColor colorWithCalibratedWhite:0.35 alpha:1.0] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRect:
        NSMakeRect(0.5, 0.5, size.width - 1.0, size.height - 1.0)];
    border.lineWidth = 1.0;
    [border stroke];

    [image unlockFocus];

    _staticLayerImage = image;
    _staticLayerSize = size;
    _staticLayerDirty = NO;
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    [self rebuildStaticLayerIfNeeded];
    if (_staticLayerImage != nil) {
        [_staticLayerImage drawInRect:self.bounds
                             fromRect:NSZeroRect
                            operation:NSCompositingOperationSourceOver
                             fraction:1.0];
    } else {
        [[NSColor colorWithCalibratedWhite:1.0 alpha:1.0] setFill];
        NSRectFill(self.bounds);
    }

    // Dynamic layer: vehicle markers only. SDS-1 Rule 1 — no hue:
    // ink discs (the ramp's `ink` token) with a paper ring, so a
    // marker stays legible over the gray route lines; the route
    // label and bearing tick are ink on paper. (Was: a saturated
    // hue fill with a white label — the listing's row 1.)
    NSFont *labelFont = [NSFont systemFontOfSize:9.0];
    NSDictionary *labelAttrs = @{
        NSFontAttributeName: labelFont,
        NSForegroundColorAttributeName: [NSColor blackColor],
    };
    const double radius = 5.0;

    for (LTDVehicle *v in _vehicles ?: @[]) {
        NSPoint c = [self pointForLat:v.lat lon:v.lon];
        if (!NSPointInRect(c, NSInsetRect(self.bounds, -20, -20))) continue;

        NSRect circle = NSMakeRect(c.x - radius, c.y - radius,
                                   radius * 2.0, radius * 2.0);
        [[NSColor colorWithCalibratedWhite:0.0 alpha:1.0] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:circle] fill];
        [[NSColor whiteColor] setStroke];
        NSBezierPath *ringPath = [NSBezierPath bezierPathWithOvalInRect:circle];
        ringPath.lineWidth = 1.5;
        [ringPath stroke];

        // Bearing tick: 0 deg = north = up (smaller y in flipped coords).
        // Drawn ONLY when the feed actually sent a bearing — a null
        // bearing must not become a fabricated north heading. Starts
        // at the disc's edge so the ink tick reads on paper.
        if (v.hasBearing) {
            double rad = v.bearing * M_PI / 180.0;
            NSPoint edge = NSMakePoint(c.x + sin(rad) * radius,
                                       c.y - cos(rad) * radius);
            NSPoint tip = NSMakePoint(c.x + sin(rad) * (radius + 5.0),
                                      c.y - cos(rad) * (radius + 5.0));
            NSBezierPath *tick = [NSBezierPath bezierPath];
            tick.lineWidth = 1.5;
            [tick moveToPoint:edge];
            [tick lineToPoint:tip];
            [[NSColor blackColor] setStroke];
            [tick stroke];
        }

        if (v.routeID.length > 0) {
            [v.routeID drawAtPoint:NSMakePoint(c.x + radius + 2.0, c.y - 5.0)
                    withAttributes:labelAttrs];
        }
    }
}

@end
