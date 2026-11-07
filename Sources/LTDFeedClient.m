// LTDFeedClient.m — see LTDFeedClient.h. ARC.
#import "LTDFeedClient.h"

static NSString * const kLTDBundleID = @"com.detroitautomationacademy.livetransit";

@interface LTDFeedClient ()
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation LTDFeedClient

+ (instancetype)sharedClient {
    static LTDFeedClient *client = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = [[LTDFeedClient alloc] init];
    });
    return client;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _vehiclesURL = [NSURL URLWithString:@"https://detroitautomationacademy.com/live-data/vehicles.json"];
        _alertsURL   = [NSURL URLWithString:@"https://detroitautomationacademy.com/live-data/alerts.json"];
        NSURLSessionConfiguration *config =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 20.0;
        config.timeoutIntervalForResource = 30.0;
        // The feed republishes every ~5 min; conditional GET handles
        // freshness, so the URL cache would only add staleness risk.
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _session = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}

#pragma mark - Conditional-GET validators (NSUserDefaults, per URL)

- (NSString *)defaultsKeyForURL:(NSURL *)url suffix:(NSString *)suffix {
    return [NSString stringWithFormat:@"LTDFeedValidator.%@.%@",
            [url absoluteString], suffix];
}

- (void)storeValidatorsFromResponse:(NSHTTPURLResponse *)response {
    NSDictionary *headers = [response allHeaderFields];
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    NSString *etag = [headers objectForKey:@"ETag"];
    if ([etag isKindOfClass:[NSString class]] && etag.length > 0) {
        [defs setObject:etag forKey:[self defaultsKeyForURL:[response URL] suffix:@"ETag"]];
    }
    NSString *modified = [headers objectForKey:@"Last-Modified"];
    if ([modified isKindOfClass:[NSString class]] && modified.length > 0) {
        [defs setObject:modified forKey:[self defaultsKeyForURL:[response URL] suffix:@"LastModified"]];
    }
}

#pragma mark - Disk cache (last good payload)

+ (NSURL *)cacheDirectoryURL {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                         NSUserDomainMask, YES);
    NSString *base = dirs.firstObject ?: NSTemporaryDirectory();
    NSString *path = [base stringByAppendingPathComponent:kLTDBundleID];
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [NSURL fileURLWithPath:path];
}

+ (NSURL *)cacheFileURLForFeedName:(NSString *)name {
    return [[self cacheDirectoryURL] URLByAppendingPathComponent:
            [name stringByAppendingPathExtension:@"json"]];
}

+ (NSData *)cachedVehiclesData {
    return [NSData dataWithContentsOfURL:[self cacheFileURLForFeedName:@"vehicles"]];
}

+ (void)writeCacheData:(NSData *)data feedName:(NSString *)name {
    [data writeToURL:[self cacheFileURLForFeedName:name]
             options:NSDataWritingAtomic
               error:nil];
}

#pragma mark - Fetch

- (void)fetchURL:(NSURL *)url feedName:(NSString *)name completion:(LTDFeedCompletion)completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    NSString *etag = [defs stringForKey:[self defaultsKeyForURL:url suffix:@"ETag"]];
    if (etag.length > 0) {
        [request setValue:etag forHTTPHeaderField:@"If-None-Match"];
    }
    NSString *modified = [defs stringForKey:[self defaultsKeyForURL:url suffix:@"LastModified"]];
    if (modified.length > 0) {
        [request setValue:modified forHTTPHeaderField:@"If-Modified-Since"];
    }

    NSURLSessionDataTask *task =
        [self.session dataTaskWithRequest:request
                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
                                ? (NSHTTPURLResponse *)response : nil;

        NSData *resultData = nil;
        BOOL notModified = NO;
        NSError *resultError = error;

        if (resultError == nil && http != nil) {
            if (http.statusCode == 304) {
                notModified = YES; // nil data, nil error — caller keeps state
            } else if (http.statusCode == 200 && data.length > 0) {
                resultData = data;
                [self storeValidatorsFromResponse:http];
                [LTDFeedClient writeCacheData:data feedName:name];
            } else {
                resultError = [NSError errorWithDomain:@"LTDFeedHTTP"
                                                  code:http.statusCode
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                  [NSString stringWithFormat:@"Feed HTTP %ld",
                                                      (long)http.statusCode]}];
            }
        }

        if (completion) {
            // Completion always lands on the main queue.
            [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                completion(resultData, notModified, resultError);
            }];
        }
    }];
    [task resume];
}

- (void)fetchVehiclesWithCompletion:(LTDFeedCompletion)completion {
    [self fetchURL:self.vehiclesURL feedName:@"vehicles" completion:completion];
}

- (void)fetchAlertsWithCompletion:(LTDFeedCompletion)completion {
    [self fetchURL:self.alertsURL feedName:@"alerts" completion:completion];
}

@end
