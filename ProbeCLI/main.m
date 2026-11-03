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
        if (!home.length) { PrintJSON(@{@"seen":@NO,@"bundle":bundle?:@"",@"error":@"container path unavailable"}); return 2; }
        NSString *marker=[home stringByAppendingPathComponent:[NSString stringWithFormat:@".nkcrane/runtime-%@.json",Safe(bundle)]];
        NSData *data=[NSData dataWithContentsOfFile:marker];
        if (!data.length) {
            PrintJSON(@{@"seen":@NO,@"bundle":bundle?:@"",@"marker_path":marker,@"reason":@"runtime marker not found"});
            return 3;
        }
        id raw=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSMutableDictionary *out=[raw isKindOfClass:NSDictionary.class]?[raw mutableCopy]:[NSMutableDictionary dictionary];
        out[@"seen"]=@YES;
        out[@"marker_path"]=marker;
        NSDictionary *attrs=[[NSFileManager defaultManager] attributesOfItemAtPath:marker error:nil];
        if (attrs[NSFileModificationDate]) out[@"marker_mtime"]=@([attrs[NSFileModificationDate] timeIntervalSince1970]);
        PrintJSON(out);
        return 0;
    }
}
