#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSURL *containerURL;
@end

static NSString * const NKCRegistryPath = @"/var/mobile/Library/NKCrane/Public/registry.json";

static NSString *Safe(NSString *value) {
    if (!value.length) return @"unknown";
    NSMutableString *out=[value mutableCopy];
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    for (NSInteger i=(NSInteger)out.length-1;i>=0;i--) {
        unichar c=[out characterAtIndex:(NSUInteger)i];
        if (![allowed characterIsMember:c]) [out replaceCharactersInRange:NSMakeRange((NSUInteger)i,1) withString:@"_"];
    }
    return out;
}

static NSString *ContainerPath(NSString *bundle) {
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices",RTLD_LAZY);
    Class c=NSClassFromString(@"LSApplicationProxy"); SEL s=NSSelectorFromString(@"applicationProxyForIdentifier:");
    if(!c||![c respondsToSelector:s]) return nil;
    id p=((id(*)(id,SEL,id))objc_msgSend)(c,s,bundle); SEL u=NSSelectorFromString(@"containerURL");
    if(!p||![p respondsToSelector:u]) return nil;
    id url=((id(*)(id,SEL))objc_msgSend)(p,u);
    return [url isKindOfClass:NSURL.class]?[url path]:nil;
}

static NSDictionary *ReadJSON(NSString *path) {
    NSData *data=[NSData dataWithContentsOfFile:path];
    if(!data.length) return nil;
    id obj=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class]?obj:nil;
}

static NSString *ResolveOwner(NSDictionary *registry, NSString *bundle) {
    NSDictionary *aliases=[registry[@"aliases"] isKindOfClass:NSDictionary.class]?registry[@"aliases"]:@{};
    NSString *current=bundle; NSMutableSet *seen=[NSMutableSet set];
    for(NSUInteger i=0;i<8;i++){
        if(!current.length||[seen containsObject:current]) break;
        [seen addObject:current];
        NSString *next=[aliases[current] isKindOfClass:NSString.class]?aliases[current]:nil;
        if(!next.length) break;
        current=next;
    }
    return current?:bundle;
}

static void PrintJSON(id obj) {
    NSData *d=[NSJSONSerialization dataWithJSONObject:obj?:@{} options:NSJSONWritingPrettyPrinted error:nil];
    if(d) fwrite(d.bytes,1,d.length,stdout); fputc('\n',stdout);
}

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if(argc<2){ fprintf(stderr,"usage: nkcraneprobe <bundle-id>\n"); return 1; }
        NSString *bundle=[NSString stringWithUTF8String:argv[1]];
        NSDictionary *registry=ReadJSON(NKCRegistryPath);
        NSString *owner=registry?ResolveOwner(registry,bundle):bundle;
        NSDictionary *apps=[registry[@"apps"] isKindOfClass:NSDictionary.class]?registry[@"apps"]:@{};
        NSDictionary *entry=[apps[owner] isKindOfClass:NSDictionary.class]?apps[owner]:nil;
        NSString *home=ContainerPath(owner);

        NSMutableDictionary *out=[NSMutableDictionary dictionary];
        out[@"mode"]=@"registry-shim-v1";
        out[@"bundle"]=bundle?:@"";
        out[@"owner"]=owner?:@"";
        out[@"registry_path"]=NKCRegistryPath;
        out[@"registry_seen"]=@(registry!=nil);
        if(entry){
            out[@"enabled"]=@([entry[@"enabled"] boolValue]);
            out[@"registry_active"]=[entry[@"active"] isKindOfClass:NSString.class]?entry[@"active"]:@"default";
        }
        if(home.length){
            out[@"live_root"]=home;
            NSString *marker=[home stringByAppendingPathComponent:[NSString stringWithFormat:@".nkcrane/runtime-registry-%@.json",Safe(bundle)]];
            NSDictionary *runtime=ReadJSON(marker);
            out[@"marker_path"]=marker;
            out[@"shim_seen"]=@(runtime!=nil);
            if(runtime) out[@"runtime"]=runtime;
        } else {
            out[@"shim_seen"]=@NO;
            out[@"error"]=@"container path unavailable";
        }
        PrintJSON(out);
        return (registry && [out[@"shim_seen"] boolValue])?0:3;
    }
}
