// LTDFeedClient.h — Live Transit Detroit (native macOS, codename:distro T1)
// Foundation only. Target: macOS 10.13. Memory: ARC (see README.md).
//
// Performance contract (no browser, no polling waste):
//  - One shared ephemeral NSURLSession; requests are cheap and stateless.
//  - Conditional GET: ETag / Last-Modified are stored per URL in
//    NSUserDefaults and replayed as If-None-Match / If-Modified-Since.
//    A 304 is reported as notModified=YES with nil data and NO error, so
//    the caller skips parsing and redraw entirely.
//  - The last good payload for each feed is cached on disk under
//    ~/Library/Caches/com.detroitautomationacademy.livetransit/ so a cold
//    launch paints instantly from cache while the first fetch runs.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// data == nil && error == nil && notModified == YES  -> 304, nothing changed.
// data == nil && error != nil                        -> failure; keep old data.
typedef void (^LTDFeedCompletion)(NSData * _Nullable data, BOOL notModified, NSError * _Nullable error);

@interface LTDFeedClient : NSObject

+ (instancetype)sharedClient;

@property (nonatomic, copy, readonly) NSURL *vehiclesURL;
@property (nonatomic, copy, readonly) NSURL *alertsURL;

- (void)fetchVehiclesWithCompletion:(LTDFeedCompletion)completion;
- (void)fetchAlertsWithCompletion:(LTDFeedCompletion)completion;

// Last good vehicles payload from the on-disk cache (nil if none yet).
+ (nullable NSData *)cachedVehiclesData;

@end

NS_ASSUME_NONNULL_END
