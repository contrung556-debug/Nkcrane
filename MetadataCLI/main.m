#import <Foundation/Foundation.h>
#import "../NKCraneCore/NKCStore.h"
#import "../NKCraneCore/NKCContainer.h"

static NSString *NKSafePathComponent(NSString *value) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    NSMutableString *out = [NSMutableString stringWithCapacity:value.length];
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        NSString *s = [NSString stringWithCharacters:&c length:1];
        [out appendString:[s rangeOfCharacterFromSet:allowed].location != NSNotFound ? s : @"_"];
    }
    return out.length ? out : @"unknown";
}

static unsigned long long NKDirectorySize(NSString *path, BOOL excludeNKCrane) {
    if (!path.length) return 0;
    NSURL *root = [NSURL fileURLWithPath:path isDirectory:YES];
    NSArray *keys = @[NSURLIsRegularFileKey, NSURLFileAllocatedSizeKey, NSURLFileSizeKey];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:root
                                                           includingPropertiesForKeys:keys
                                                                              options:(NSDirectoryEnumerationSkipsHiddenFiles)
                                                                         errorHandler:^BOOL(__unused NSURL *url, __unused NSError *error) { return YES; }];
    unsigned long long total = 0;
    for (NSURL *url in enumerator) {
        NSString *relative = [url.path substringFromIndex:MIN(root.path.length + 1, url.path.length)];
        if (excludeNKCrane && ([relative isEqualToString:@".nkcrane"] || [relative hasPrefix:@".nkcrane/"])) {
            NSNumber *isDir = nil;
            [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
            if (isDir.boolValue) [enumerator skipDescendants];
            continue;
        }
        NSNumber *regular = nil;
        [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        if (!regular.boolValue) continue;
        NSNumber *size = nil;
        [url getResourceValue:&size forKey:NSURLFileAllocatedSizeKey error:nil];
        if (!size) [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        total += size.unsignedLongLongValue;
    }
    return total;
}

static NSDictionary *NKLatestBackups(NSString *owner) {
    NSString *root = [[@"/var/mobile/Library/NKCrane/Backups" stringByAppendingPathComponent:NKSafePathComponent(owner)] copy];
    NSArray *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil] ?: @[];
    NSMutableDictionary *latest = [NSMutableDictionary dictionary];
    for (NSString *name in items) {
        if (![name.pathExtension isEqualToString:@"nkcb"]) continue;
        NSString *package = [root stringByAppendingPathComponent:name];
        NSString *manifestPath = [package stringByAppendingPathComponent:@"manifest.json"];
        NSData *data = [NSData dataWithContentsOfFile:manifestPath];
        if (!data) continue;
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![manifest isKindOfClass:NSDictionary.class]) continue;
        NSString *cid = manifest[@"source_container_id"];
        if (![cid isKindOfClass:NSString.class] || !cid.length) continue;
        NSNumber *created = manifest[@"created_at"];
        NSTimeInterval ts = [created respondsToSelector:@selector(doubleValue)] ? created.doubleValue : 0;
        NSDictionary *old = latest[cid];
        if (!old || [old[@"created_at"] doubleValue] < ts) {
            latest[cid] = @{@"path": package, @"created_at": @(ts)};
        }
    }
    return latest;
}

static void NKPrintJSON(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object ?: @{} options:0 error:nil];
    if (data) {
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3 || strcmp(argv[1], "app") != 0) {
            fprintf(stderr, "NKCrane metadata helper v0.8.0\nUsage: nkcranemeta app <bundle-id>\n");
            return 1;
        }
        NSString *bundle = [NSString stringWithUTF8String:argv[2]];
        NKCStore *store = NKCStore.sharedStore;
        NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundle];
        NSDictionary *latest = NKLatestBackups(owner);
        NSMutableArray *containers = [NSMutableArray array];

        NSMutableArray<NKCContainer *> *all = [NSMutableArray array];
        NKCContainer *def = [NKCContainer new];
        def.identifier = NKCDefaultContainerIdentifier;
        def.name = @"Default";
        [all addObject:def];
        [all addObjectsFromArray:[store containersForBundleIdentifier:owner]];

        for (NKCContainer *container in all) {
            NSString *path = [store rootPathForContainerIdentifier:container.identifier bundleIdentifier:owner create:NO];
            unsigned long long bytes = path.length ? NKDirectorySize(path, [container.identifier isEqualToString:NKCDefaultContainerIdentifier]) : 0;
            NSMutableDictionary *item = [@{
                @"id": container.identifier ?: @"",
                @"name": container.name ?: @"",
                @"bytes": @(bytes),
                @"path": path ?: [NSNull null]
            } mutableCopy];
            NSDictionary *backup = latest[container.identifier];
            if (backup) item[@"latest_backup"] = backup;
            [containers addObject:item];
        }
        NKPrintJSON(@{@"ok":@YES, @"owner":owner ?: bundle, @"containers":containers});
        return 0;
    }
}
