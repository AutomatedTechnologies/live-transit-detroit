// LTDVehicle.h — Live Transit Detroit (native macOS, codename:distro T1)
// AppKit+Foundation only. No third-party dependencies. Target: macOS 10.13.
// Memory: ARC (see README.md).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LTDVehicle : NSObject

@property (nonatomic, copy, nullable) NSString *agency;
@property (nonatomic, copy, nullable) NSString *routeID;
@property (nonatomic, copy, nullable) NSString *vehicleID;
@property (nonatomic, assign) double lat;
@property (nonatomic, assign) double lon;
@property (nonatomic, assign) double bearing;    // degrees, 0 = north
@property (nonatomic, assign) double speedMPH;   // 0 when feed sends null
@property (nonatomic, assign) BOOL hasSpeed;     // NO when feed sends null
@property (nonatomic, copy, nullable) NSString *destination;
@property (nonatomic, copy, nullable) NSString *updatedAt; // feed string, verbatim

// Stable identity for diffing: "<agency>/<vehicle_id>".
@property (nonatomic, copy, readonly) NSString *diffKey;

// Parses the live feed envelope:
//   { "generated_at": ..., "count": N, "vehicles": [ {...}, ... ], "sources": {...} }
// Vehicle keys (verified against live-data/vehicles.json, 2026-10-18 sample):
//   agency, route_id, vehicle_id, lat, lon, bearing, speed_mph (nullable),
//   destination (nullable/absent), updated_at.
// Returns an empty array for a well-formed envelope with no vehicles.
// On malformed data, returns nil and sets *error when error != NULL.
+ (nullable NSArray<LTDVehicle *> *)vehiclesFromFeedData:(NSData *)data
                                                   error:(NSError * _Nullable * _Nullable)error;

// Convenience: just the envelope's "generated_at" string (nil if absent).
+ (nullable NSString *)generatedAtFromFeedData:(NSData *)data;

// YES when position-bearing fields match: lat, lon, bearing, routeID,
// destination. Identity fields (agency/vehicleID) and speed/updatedAt are
// deliberately NOT compared — speed churn must not force a redraw.
- (BOOL)isSamePositionAs:(nullable LTDVehicle *)other;

@end

NS_ASSUME_NONNULL_END
