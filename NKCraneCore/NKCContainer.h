#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NKCContainer : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSDate *createdAt;

+ (instancetype)containerWithDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)dictionaryRepresentation;
@end

NS_ASSUME_NONNULL_END
