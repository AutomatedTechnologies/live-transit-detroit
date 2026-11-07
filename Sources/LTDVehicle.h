// LTDVehicle.h — Live Transit Detroit (native macOS, codename:distro T1)
// AppKit+Foundation only. No third-party dependencies. Target: macOS 10.13.
// Memory: ARC (see README.md).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LTDVehicle : NSObject

// SCOPE RULING (2026-11-07, Justin): the `agency` property below is kept
// for DATA FIDELITY / DEBUGGING ONLY — it records which upstream system
// reported the vehicle, and nothing more. Per the ruling (permission to
// exclude SMART denied; permission to treat SMART as distinct from DDOT
// for non-technical purposes, including specific API reference, denied),
// `agency` must NOT organize UI, copy, or API presentation: there is one
// Live Transit Detroit network, one merged vehicle list, one map, one
// count. Do not group, label, toggle, or section by agency anywhere.
@property (nonatomic, copy, nullable) NSString *agency;
@property (nonatomic, copy, nullable) NSString *routeID;
@property (nonatomic, copy, nullable) NSString *vehicleID;
@property (nonatomic, assign) double lat;
@property (nonatomic, assign) double lon;
@property (nonatomic, assign) double bearing;    // degrees, 0 = north; valid only when hasBearing
@property (nonatomic, assign) BOOL hasBearing;   // NO when feed sends null bearing (display feed does)
@property (nonatomic, assign) double speedMPH;   // 0 when feed sends null
@property (nonatomic, assign) BOOL hasSpeed;     // NO when feed sends null
@property (nonatomic, copy, nullable) NSString *destination;
@property (nonatomic, copy, nullable) NSString *updatedAt; // feed string, verbatim

// Stable identity for diffing: "<agency>/<vehicle_id>".
@property (nonatomic, copy, readonly) NSString *diffKey;

// Parses a live feed envelope. ONE parser serves every vehicle feed
// file; the envelopes differ in plumbing details and the parser
// tolerates all of them:
//   vehicles.json:      { "generated_at": ..., "count": N,
//                         "vehicles": [ {...}, ... ], "sources": {...} }
//   smart-display.json: { "generated_at": ..., "count": N,
//                         "vehicles": [ {...}, ... ], "source": {...} }
// Note "sources" (plural) vs "source" (singular) — the parser reads
// neither key, so the difference is immaterial to it; both envelopes
// parse identically, which is what makes the merged one-network list
// in the app delegate possible.
// Vehicle keys (verified against the 2026-10-18 samples of both files):
//   agency, route_id, vehicle_id, lat, lon, bearing (nullable — null in
//   smart-display.json; see hasBearing), speed_mph (nullable),
//   destination (nullable/absent — absent in smart-display.json),
//   updated_at.
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
