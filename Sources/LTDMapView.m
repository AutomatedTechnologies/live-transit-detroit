// LTDMapView.m — see LTDMapView.h. ARC.
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

@implementation LTDMapView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _centerLat = 42.3314;
        _centerLon = -83.0458;
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

// Degrees-per-pixel: fit roughly 0.30 deg latitude across the view height.
- (double)degreesPerPixel {
    double h = NSHeight(self.bounds);
    return (h > 0) ? (0.30 / h) : 0.001;
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

    // Background.
    [[NSColor colorWithCalibratedWhite:0.08 alpha:1.0] setFill];
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
        [[NSColor colorWithCalibratedWhite:0.08 alpha:1.0] setFill];
        NSRectFill(self.bounds);
    }

    // Dynamic layer: vehicle markers only.
    NSFont *labelFont = [NSFont systemFontOfSize:9.0];
    NSDictionary *labelAttrs = @{
        NSFontAttributeName: labelFont,
        NSForegroundColorAttributeName: [NSColor whiteColor],
    };
    const double radius = 5.0;

    for (LTDVehicle *v in _vehicles ?: @[]) {
        NSPoint c = [self pointForLat:v.lat lon:v.lon];
        if (!NSPointInRect(c, NSInsetRect(self.bounds, -20, -20))) continue;

        NSRect circle = NSMakeRect(c.x - radius, c.y - radius,
                                   radius * 2.0, radius * 2.0);
        [[NSColor colorWithCalibratedRed:1.0 green:0.55 blue:0.1 alpha:1.0] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:circle] fill];
        [[NSColor blackColor] setStroke];
        [[NSBezierPath bezierPathWithOvalInRect:circle] stroke];

        // Bearing tick: 0 deg = north = up (smaller y in flipped coords).
        double rad = v.bearing * M_PI / 180.0;
        NSPoint tip = NSMakePoint(c.x + sin(rad) * (radius + 5.0),
                                  c.y - cos(rad) * (radius + 5.0));
        NSBezierPath *tick = [NSBezierPath bezierPath];
        tick.lineWidth = 1.5;
        [tick moveToPoint:c];
        [tick lineToPoint:tip];
        [[NSColor whiteColor] setStroke];
        [tick stroke];

        if (v.routeID.length > 0) {
            [v.routeID drawAtPoint:NSMakePoint(c.x + radius + 2.0, c.y - 5.0)
                    withAttributes:labelAttrs];
        }
    }
}

@end
