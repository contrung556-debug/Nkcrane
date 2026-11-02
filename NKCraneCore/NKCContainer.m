#import "NKCContainer.h"

@implementation NKCContainer

+ (instancetype)containerWithDictionary:(NSDictionary *)dictionary {
    NKCContainer *c = [NKCContainer new];
    c.identifier = [dictionary[@"id"] isKindOfClass:NSString.class] ? dictionary[@"id"] : NSUUID.UUID.UUIDString.lowercaseString;
    c.name = [dictionary[@"name"] isKindOfClass:NSString.class] ? dictionary[@"name"] : @"Container";

    id created = dictionary[@"created_at"];
    if ([created isKindOfClass:NSDate.class]) {
        c.createdAt = created;
    } else if ([created isKindOfClass:NSNumber.class]) {
        c.createdAt = [NSDate dateWithTimeIntervalSince1970:[created doubleValue]];
    } else {
        c.createdAt = [NSDate date];
    }
    return c;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        @"id": self.identifier ?: @"",
        @"name": self.name ?: @"Container",
        @"created_at": @([self.createdAt timeIntervalSince1970])
    };
}

@end
