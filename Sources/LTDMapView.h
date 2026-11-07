// LTDMapView.h — Live Transit Detroit (native macOS, codename:distro T1)
// AppKit only. No WebView, no WebGL, no tiles, no browser anything.
// Target: macOS 10.13. Memory: ARC (see README.md).
//
// Performance design (the whole point of the native build):
//  - Static layer (route polylines + view border) is rendered ONCE into an
//    offscreen NSImage cache. It is invalidated ONLY when the view bounds
//    change or the routes array is replaced.
//  - drawRect: blits the cached static image, then draws ONLY the vehicle
//    markers (circle + bearing tick + route label). ~60 markers is a few
//    hundred path operations — no per-frame cost beyond the blit.
//  - No timers, no animation loop, no display-link inside this view. The
//    owner (app delegate) calls setNeedsDisplay only when the keyed diff
//    says a vehicle actually moved.
//  - Coordinates: isFlipped == YES, so (0,0) is top-left and y grows down,
//    matching screen/map intuition and keeping the projection trivial.
#import <AppKit/AppKit.h>
#import "LTDVehicle.h"

NS_ASSUME_NONNULL_BEGIN

// One route polyline: an ordered list of lat/lon points.
// Points are NSValue-wrapped structs: use +[NSValue valueWithLTDPoint:]
// / -ltdPointValue (category below) so callers never touch raw buffers.
typedef struct {
    double lat;
    double lon;
} LTDGeoPoint;

@interface LTDRoutePolyline : NSObject
@property (nonatomic, copy, nullable) NSString *routeID;
@property (nonatomic, copy, nullable) NSString *name;
// NSArray of NSValue, each wrapping an LTDGeoPoint.
@property (nonatomic, copy) NSArray<NSValue *> *points;
+ (instancetype)polylineWithRouteID:(nullable NSString *)routeID
                               name:(nullable NSString *)name
                             points:(NSArray<NSValue *> *)points;
@end

@interface NSValue (LTDGeoPoint)
+ (NSValue *)valueWithLTDPoint:(LTDGeoPoint)point;
- (LTDGeoPoint)ltdPointValue;
@end

@interface LTDMapView : NSView

// Replacing either property does NOT redraw by itself; the owner calls
// setNeedsDisplay after its diff decides a redraw is warranted.
// (routes replacement DOES invalidate the static-layer cache.)
@property (nonatomic, copy, nullable) NSArray<LTDVehicle *> *vehicles;
@property (nonatomic, copy, nullable) NSArray<LTDRoutePolyline *> *routes;

// Map centre (Detroit: Rosa Parks TC area). Fixed for T1.
@property (nonatomic, assign, readonly) double centerLat;
@property (nonatomic, assign, readonly) double centerLon;

// Equirectangular projection: lon is scaled by cos(centerLat) so shapes
// are not stretched at Detroit's latitude.
- (NSPoint)pointForLat:(double)lat lon:(double)lon;

@end

NS_ASSUME_NONNULL_END
