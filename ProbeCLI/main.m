#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSURL *containerURL;
@end

static NSString *Safe(NSString *value) {
    if (!value.length) return @"unknown";
    NSMutableString *out = [value mutableCopy];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    for (NSInteger i=(NSInteger)out.length-1;i>=0;i--) {
        unichar c=[out characterAtIndex:(NSUInteger)i];
        if (![allowed characterIsMember:c]) [out replaceCharactersInRange:NSMakeRange((NSUInteger)i,1) withString:@"_"];
    }
    return out;
}

static NSString *ContainerPath(NSString *bundle) {
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    Class c=NSClassFromString(@"LSApplicationProxy");
    SEL s=NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!c || ![c respondsToSelector:s]) return nil;
    id p=((id(*)(id,SEL,id))objc_msgSend)(c,s,bundle);
    SEL u=NSSelectorFromString(@"containerURL");
    if (!p || ![p respondsToSelector:u]) return nil;
    id url=((id(*)(id,SEL))objc_msgSend)(p,u);
    return [url isKindOfClass:NSURL.class] ? [url path] : nil;
}

static NSDictionary *ReadJSON(NSString *path) {
    NSData *data=[NSData dataWithContentsOfFile:path];
    if(!data.length) return nil;
    id obj=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class]?obj:nil;
}

static void PrintJSON(id obj) {
    NSData *d=[NSJSONSerialization dataWithJSONObject:obj?:@{} options:NSJSONWritingPrettyPrinted error:nil];
    if (d) fwrite(d.bytes,1,d.length,stdout);
    fputc('\n',stdout);
}

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr,"usage: nkcraneprobe <bundle-id>\n"); return 1; }
        NSString *bundle=[NSString stringWithUTF8String:argv[1]];
        NSString *home=ContainerPath(bundle);
        if (!home.length) { PrintJSON(@{@"mode":@"physical-v1",@"bundle":bundle?:@"",@"error":@"container path unavailable"}); return 2; }

        NSString *safeBundle=Safe(bundle);
        NSString *physicalOwnerRoot=[@"/var/mobile/Library/NKCrane/PhysicalProfiles" stringByAppendingPathComponent:safeBundle];
        NSString *physicalStatePath=[physicalOwnerRoot stringByAppendingPathComponent:@"state.json"];
        NSDictionary *physicalState=ReadJSON(physicalStatePath);
        NSString *physicalActive=[physicalState[@"physical_active"] isKindOfClass:NSString.class]?physicalState[@"physical_active"]:@"default";
        NSString *physicalProfileRoot=[[[physicalOwnerRoot stringByAppendingPathComponent:@"containers"] stringByAppendingPathComponent:Safe(physicalActive)] copy];

        // Legacy runtime information is retained only to help migrate/debug old
        // installs. Physical v1 does not require target-app injection.
        NSString *base=[home stringByAppendingPathComponent:@".nkcrane"];
        NSString *configPath=[base stringByAppendingPathComponent:@"config.json"];
        NSDictionary *config=ReadJSON(configPath);
        NSString *marker=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"runtime-%@.json",safeBundle]];
        NSDictionary *runtime=ReadJSON(marker);

        NSMutableDictionary *out=[NSMutableDictionary dictionary];
        out[@"mode"]=@"physical-v1";
        out[@"bundle"]=bundle?:@"";
        out[@"live_root"]=home;
        out[@"physical_state_path"]=physicalStatePath;
        out[@"physical_state_seen"]=@(physicalState!=nil);
        out[@"physical_active"]=physicalActive;
        out[@"physical_profile_root"]=physicalProfileRoot;
        out[@"config_seen_legacy"]=@(config!=nil);
        out[@"runtime_seen_legacy"]=@(runtime!=nil);
        out[@"reason"]=physicalState?@"physical profile state active; target-app injection is not required":@"physical state not created yet; perform one container switch";
        PrintJSON(out);
        return physicalState?0:3;
    }
}
