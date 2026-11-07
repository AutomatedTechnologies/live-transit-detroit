// LTDVehicle.m — see LTDVehicle.h. ARC.
#import "LTDVehicle.h"

@implementation LTDVehicle

- (NSString *)diffKey {
    return [NSString stringWithFormat:@"%@/%@",
            self.agency ?: @"", self.vehicleID ?: @""];
}

+ (NSString *)generatedAtFromFeedData:(NSData *)data {
    if (data.length == 0) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) return nil;
    id gen = [(NSDictionary *)root objectForKey:@"generated_at"];
    return [gen isKindOfClass:[NSString class]] ? (NSString *)gen : nil;
}

+ (NSArray<LTDVehicle *> *)vehiclesFromFeedData:(NSData *)data
                                          error:(NSError **)error {
    if (data.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"LTDFeedParse" code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"Empty feed data."}];
        }
        return nil;
    }
    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data
                                              options:0
                                                error:&jsonError];
    if (jsonError != nil || ![root isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = jsonError ?: [NSError errorWithDomain:@"LTDFeedParse" code:2 userInfo:@{
                NSLocalizedDescriptionKey: @"Feed root is not a JSON object."}];
        }
        return nil;
    }
    id list = [(NSDictionary *)root objectForKey:@"vehicles"];
    if (list == nil || list == [NSNull null]) {
        return [NSArray array]; // well-formed envelope, no vehicles key
    }
    if (![list isKindOfClass:[NSArray class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"LTDFeedParse" code:3 userInfo:@{
                NSLocalizedDescriptionKey: @"Feed 'vehicles' is not an array."}];
        }
        return nil;
    }

    NSMutableArray<LTDVehicle *> *out = [NSMutableArray arrayWithCapacity:[(NSArray *)list count]];
    for (id item in (NSArray *)list) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *d = (NSDictionary *)item;
        // A vehicle without coordinates cannot be drawn; skip it.
        id lat = [d objectForKey:@"lat"];
        id lon = [d objectForKey:@"lon"];
        if (![lat isKindOfClass:[NSNumber class]] ||
            ![lon isKindOfClass:[NSNumber class]]) continue;

        LTDVehicle *v = [[LTDVehicle alloc] init];
        id agency = [d objectForKey:@"agency"];
        v.agency = [agency isKindOfClass:[NSString class]] ? agency : nil;
        id route = [d objectForKey:@"route_id"];
        v.routeID = [route isKindOfClass:[NSString class]] ? route
                  : ([route isKindOfClass:[NSNumber class]] ? [(NSNumber *)route stringValue] : nil);
        id vid = [d objectForKey:@"vehicle_id"];
        v.vehicleID = [vid isKindOfClass:[NSString class]] ? vid
                    : ([vid isKindOfClass:[NSNumber class]] ? [(NSNumber *)vid stringValue] : nil);
        v.lat = [(NSNumber *)lat doubleValue];
        v.lon = [(NSNumber *)lon doubleValue];
        id bearing = [d objectForKey:@"bearing"];
        if ([bearing isKindOfClass:[NSNumber class]]) {
            v.bearing = [(NSNumber *)bearing doubleValue];
            v.hasBearing = YES;
        } else {
            // Null bearing (the display feed sends bearing: null): keep
            // 0.0 as a placeholder but flag it absent — drawing a north
            // tick for it would fabricate a heading the feed never sent.
            v.bearing = 0.0;
            v.hasBearing = NO;
        }
        id speed = [d objectForKey:@"speed_mph"];
        if ([speed isKindOfClass:[NSNumber class]]) {
            v.speedMPH = [(NSNumber *)speed doubleValue];
            v.hasSpeed = YES;
        } else {
            v.speedMPH = 0.0;
            v.hasSpeed = NO;
        }
        id dest = [d objectForKey:@"destination"];
        v.destination = [dest isKindOfClass:[NSString class]] ? dest : nil;
        id upd = [d objectForKey:@"updated_at"];
        v.updatedAt = [upd isKindOfClass:[NSString class]] ? upd : nil;
        [out addObject:v];
    }
    return [out copy];
}

- (BOOL)isSamePositionAs:(LTDVehicle *)other {
    if (other == nil) return NO;
    if (fabs(self.lat - other.lat) > 1e-9) return NO;
    if (fabs(self.lon - other.lon) > 1e-9) return NO;
    if (self.hasBearing != other.hasBearing) return NO;
    if (fabs(self.bearing - other.bearing) > 1e-9) return NO;
    if ((self.routeID == nil) != (other.routeID == nil)) return NO;
    if (self.routeID && ![self.routeID isEqualToString:other.routeID]) return NO;
    if ((self.destination == nil) != (other.destination == nil)) return NO;
    if (self.destination && ![self.destination isEqualToString:other.destination]) return NO;
    return YES;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<LTDVehicle %@ route %@ @ %.5f,%.5f brg %.0f>",
            self.diffKey, self.routeID ?: @"-", self.lat, self.lon, self.bearing];
}

@end
