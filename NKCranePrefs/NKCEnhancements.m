#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

@interface NKCRootListController : PSListController @end
@interface NKCAppListController : PSListController <UISearchResultsUpdating> @end
@interface NKCContainerListController : PSListController @end
@interface NKCContainerDetailController : PSListController @end
@interface NKCJobsController : PSListController @end
@interface NKCCommandRunner : NSObject
+ (NSDictionary *)run:(NSArray<NSString *> *)arguments;
+ (void)runAsync:(NSArray<NSString *> *)arguments completion:(void (^)(NSDictionary *result))completion;
@end

@interface NKCQuickSwitchController : PSListController @end
@interface NKCQuickAppController : PSListController @end

static const void *NKC8SearchKey = &NKC8SearchKey;
static const void *NKC8MetaKey = &NKC8MetaKey;
static const void *NKC8MetaLoadingKey = &NKC8MetaLoadingKey;
static const void *NKC8JobsTimerKey = &NKC8JobsTimerKey;

static NSDictionary *NKC8JSON(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

static NSString *NKC8ToolPath(NSString *name) {
    NSArray *roots = @[@"/var/jb/usr/local/bin", @"/usr/local/bin"];
    for (NSString *root in roots) {
        NSString *path = [root stringByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) return path;
    }
    return [[roots firstObject] stringByAppendingPathComponent:name];
}

static NSDictionary *NKC8RunTool(NSString *toolName, NSArray<NSString *> *arguments) {
    NSString *tool = NKC8ToolPath(toolName);
    int fds[2] = {-1, -1};
    if (pipe(fds) != 0) return @{@"status":@(-1), @"output":@"pipe failed"};
    NSMutableArray *all = [NSMutableArray arrayWithObject:tool];
    [all addObjectsFromArray:arguments ?: @[]];
    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < all.count; i++) argv[i] = strdup([all[i] UTF8String]);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[1]);
    pid_t pid = 0;
    int spawn = posix_spawn(&pid, tool.fileSystemRepresentation, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);

    NSMutableData *data = [NSMutableData data];
    if (spawn == 0) {
        uint8_t buffer[4096];
        ssize_t n;
        while ((n = read(fds[0], buffer, sizeof(buffer))) > 0) [data appendBytes:buffer length:(NSUInteger)n];
    }
    close(fds[0]);
    for (NSUInteger i = 0; i < all.count; i++) free(argv[i]);
    free(argv);

    int status = spawn;
    if (spawn == 0) {
        int waitStatus = 0;
        waitpid(pid, &waitStatus, 0);
        status = WIFEXITED(waitStatus) ? WEXITSTATUS(waitStatus) : -1;
    }
    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return @{@"status":@(status), @"output":[out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]};
}

static void NKC8LoadMetaAsync(NSString *bundleID, void (^completion)(NSDictionary *meta)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *result = NKC8RunTool(@"nkcranemeta", @[@"app", bundleID ?: @""]);
        NSDictionary *meta = [result[@"status"] integerValue] == 0 ? NKC8JSON(result[@"output"]) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(meta); });
    });
}

static NSString *NKC8FormatBytes(unsigned long long bytes) {
    double value = (double)bytes;
    NSArray *units = @[@"B", @"KB", @"MB", @"GB", @"TB"];
    NSUInteger index = 0;
    while (value >= 1024.0 && index + 1 < units.count) { value /= 1024.0; index++; }
    if (index == 0) return [NSString stringWithFormat:@"%llu %@", bytes, units[index]];
    return [NSString stringWithFormat:value >= 10.0 ? @"%.0f %@" : @"%.1f %@", value, units[index]];
}

static NSString *NKC8FormatTime(NSTimeInterval ts) {
    if (ts <= 0) return @"Never";
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateStyle = NSDateFormatterShortStyle;
    f.timeStyle = NSDateFormatterShortStyle;
    return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]] ?: @"Unknown";
}

static NSDictionary *NKC8MetaForContainer(NSDictionary *meta, NSString *containerID) {
    NSArray *items = meta[@"containers"];
    if (![items isKindOfClass:NSArray.class]) return nil;
    for (NSDictionary *item in items) if ([item[@"id"] isEqualToString:containerID]) return item;
    return nil;
}

static id NKC8ObjMsg(id object, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, sel);
}

static BOOL NKC8BoolMsg(id object, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, sel);
}

static NSArray<NSDictionary *> *NKC8InstalledApps(void) {
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSel = NSSelectorFromString(@"defaultWorkspace");
    SEL allSel = NSSelectorFromString(@"allInstalledApplications");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultSel]) return @[];
    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSel);
    if (!workspace || ![workspace respondsToSelector:allSel]) return @[];
    NSArray *proxies = ((id (*)(id, SEL))objc_msgSend)(workspace, allSel);
    NSMutableArray *apps = [NSMutableArray array];
    for (id proxy in proxies) {
        if (NKC8BoolMsg(proxy, @"isPlaceholder")) continue;
        NSString *type = NKC8ObjMsg(proxy, @"applicationType");
        if ([type isKindOfClass:NSString.class] && ![type isEqualToString:@"User"]) continue;
        NSString *bundle = NKC8ObjMsg(proxy, @"applicationIdentifier");
        if (![bundle isKindOfClass:NSString.class] || !bundle.length) bundle = NKC8ObjMsg(proxy, @"bundleIdentifier");
        if (![bundle isKindOfClass:NSString.class] || !bundle.length || [bundle hasPrefix:@"com.apple."]) continue;
        NSString *name = NKC8ObjMsg(proxy, @"localizedName");
        if (![name isKindOfClass:NSString.class] || !name.length) name = bundle;
        [apps addObject:@{@"name":name, @"bundle":bundle}];
    }
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]]; }];
    return apps;
}

static UIImage *NKC8AppIcon(NSString *bundleID) {
    SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([UIImage.class respondsToSelector:sel]) {
        return ((id (*)(id, SEL, id, NSInteger, CGFloat))objc_msgSend)(UIImage.class, sel, bundleID, 2, UIScreen.mainScreen.scale);
    }
    return nil;
}

static NSSet<NSString *> *NKC8ConfiguredOwners(void) {
    CFPropertyListRef raw = CFPreferencesCopyAppValue(CFSTR("store"), CFSTR("com.nktouch.nkcrane"));
    NSDictionary *store = CFBridgingRelease(raw);
    NSDictionary *apps = [store isKindOfClass:NSDictionary.class] ? store[@"apps"] : nil;
    if (![apps isKindOfClass:NSDictionary.class]) return [NSSet set];
    NSMutableSet *set = [NSMutableSet set];
    [apps enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *obj, __unused BOOL *stop) {
        if ([obj isKindOfClass:NSDictionary.class] && [obj[@"enabled"] boolValue]) [set addObject:key];
    }];
    return set;
}

static NSArray<NSDictionary *> *NKC8ParseContainers(NSString *output) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *line in [output componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (![line hasPrefix:@"* "]) continue;
        NSRange open = [line rangeOfString:@"[" options:NSBackwardsSearch];
        NSRange close = [line rangeOfString:@"]" options:NSBackwardsSearch];
        if (open.location == NSNotFound || close.location == NSNotFound || close.location <= open.location) continue;
        NSString *name = [[line substringWithRange:NSMakeRange(2, open.location - 3)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *identifier = [line substringWithRange:NSMakeRange(open.location + 1, close.location - open.location - 1)];
        [items addObject:@{@"name":name.length ? name : identifier, @"id":identifier, @"active":@([line containsString:@"<active>"])}];
    }
    return items;
}

#pragma mark - Root enhancements

@implementation NKCRootListController (NKC8)
- (NSArray *)nk8_specifiers {
    NSArray *base = [self nk8_specifiers];
    NSMutableArray *out = [base mutableCopy];
    BOOL hasQuick = NO;
    for (PSSpecifier *s in out) {
        if ([s.name isEqualToString:@"Quick Switch"]) hasQuick = YES;
        if ([s.name hasPrefix:@"Version "]) [s setName:@"Version 0.8.0"];
    }
    if (!hasQuick) {
        PSSpecifier *quick = [PSSpecifier preferenceSpecifierNamed:@"Quick Switch" target:self set:nil get:nil detail:[NKCQuickSwitchController class] cell:PSLinkCell edit:nil];
        NSUInteger index = MIN((NSUInteger)2, out.count);
        [out insertObject:quick atIndex:index];
    }
    return out;
}
@end

#pragma mark - App search + icons

@implementation NKCAppListController (NKC8)
- (void)nk8_viewDidLoad {
    [self nk8_viewDidLoad];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchResultsUpdater = self;
    search.searchBar.placeholder = @"Search apps";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    objc_setAssociatedObject(self, NKC8SearchKey, searchController.searchBar.text ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self reloadSpecifiers];
}

- (NSArray *)nk8_appSpecifiers {
    NSArray *base = [self nk8_appSpecifiers];
    NSString *query = objc_getAssociatedObject(self, NKC8SearchKey);
    query = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    NSMutableArray *out = [NSMutableArray array];
    for (PSSpecifier *s in base) {
        NSString *bundle = [s propertyForKey:@"bundleID"];
        if (!bundle.length) { [out addObject:s]; continue; }
        UIImage *icon = NKC8AppIcon(bundle);
        if (icon) [s setProperty:icon forKey:@"iconImage"];
        if (!query.length || [s.name.lowercaseString containsString:query] || [bundle.lowercaseString containsString:query]) [out addObject:s];
    }
    return out;
}
@end

#pragma mark - Container metadata

@implementation NKCContainerListController (NKC8)
- (NSArray *)nk8_containerSpecifiers {
    NSArray *base = [self nk8_containerSpecifiers];
    NSString *bundle = [self.specifier propertyForKey:@"bundleID"];
    NSDictionary *meta = objc_getAssociatedObject(self, NKC8MetaKey);
    NSNumber *loading = objc_getAssociatedObject(self, NKC8MetaLoadingKey);
    if (!meta && !loading.boolValue && bundle.length) {
        objc_setAssociatedObject(self, NKC8MetaLoadingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak typeof(self) weakSelf = self;
        NKC8LoadMetaAsync(bundle, ^(NSDictionary *loaded) {
            if (!weakSelf) return;
            objc_setAssociatedObject(weakSelf, NKC8MetaKey, loaded ?: @{}, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(weakSelf, NKC8MetaLoadingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [weakSelf reloadSpecifiers];
        });
    }
    if (!meta) return base;

    for (PSSpecifier *s in base) {
        NSString *cid = [s propertyForKey:@"containerID"];
        if (!cid.length) continue;
        NSDictionary *item = NKC8MetaForContainer(meta, cid);
        if (!item) continue;
        NSString *baseName = [s propertyForKey:@"containerName"] ?: s.name;
        BOOL active = [[s propertyForKey:@"active"] boolValue];
        NSString *size = NKC8FormatBytes([item[@"bytes"] unsignedLongLongValue]);
        NSDictionary *backup = item[@"latest_backup"];
        NSString *suffix = backup ? @" · ↻" : @"";
        [s setName:[NSString stringWithFormat:@"%@%@ · %@%@", active ? @"✓ " : @"", baseName, size, suffix]];
    }
    return base;
}
@end

@implementation NKCContainerDetailController (NKC8)
- (NSArray *)nk8_detailSpecifiers {
    NSArray *base = [self nk8_detailSpecifiers];
    NSString *bundle = [self.specifier propertyForKey:@"bundleID"];
    NSString *cid = [self.specifier propertyForKey:@"containerID"];
    if (!bundle.length || !cid.length) return base;
    NSDictionary *result = NKC8RunTool(@"nkcranemeta", @[@"app", bundle]);
    NSDictionary *meta = [result[@"status"] integerValue] == 0 ? NKC8JSON(result[@"output"]) : nil;
    NSDictionary *item = NKC8MetaForContainer(meta, cid);
    if (!item) return base;

    NSMutableArray *out = [base mutableCopy];
    PSSpecifier *metaGroup = [PSSpecifier preferenceSpecifierNamed:@"Storage" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
    [out insertObject:metaGroup atIndex:MIN((NSUInteger)1, out.count)];
    PSSpecifier *size = [PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"Size · %@", NKC8FormatBytes([item[@"bytes"] unsignedLongLongValue])] target:self set:nil get:nil detail:nil cell:PSStaticTextCell edit:nil];
    [out insertObject:size atIndex:MIN((NSUInteger)2, out.count)];
    NSDictionary *backup = item[@"latest_backup"];
    NSString *backupText = backup ? NKC8FormatTime([backup[@"created_at"] doubleValue]) : @"Never";
    PSSpecifier *last = [PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"Last Backup · %@", backupText] target:self set:nil get:nil detail:nil cell:PSStaticTextCell edit:nil];
    [out insertObject:last atIndex:MIN((NSUInteger)3, out.count)];
    return out;
}
@end

#pragma mark - Quick switch

@implementation NKCQuickSwitchController
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Quick Switch"; }
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"Configured Apps" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [group setProperty:@"Fast access to apps that currently have NKCrane enabled." forKey:@"footerText"];
        [specs addObject:group];
        NSSet *configured = NKC8ConfiguredOwners();
        for (NSDictionary *app in NKC8InstalledApps()) {
            if (![configured containsObject:app[@"bundle"]]) continue;
            PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:app[@"name"] target:self set:nil get:nil detail:[NKCQuickAppController class] cell:PSLinkCell edit:nil];
            [s setProperty:app[@"bundle"] forKey:@"bundleID"];
            [s setProperty:app[@"name"] forKey:@"appName"];
            UIImage *icon = NKC8AppIcon(app[@"bundle"]);
            if (icon) [s setProperty:icon forKey:@"iconImage"];
            [specs addObject:s];
        }
        if (specs.count == 1) [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"No enabled apps yet" target:self set:nil get:nil detail:nil cell:PSStaticTextCell edit:nil]];
        _specifiers = [specs copy];
    }
    return _specifiers;
}
@end

@implementation NKCQuickAppController
- (void)viewDidLoad { [super viewDidLoad]; self.title = [self.specifier propertyForKey:@"appName"] ?: @"Containers"; }
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSString *bundle = [self.specifier propertyForKey:@"bundleID"];
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"Choose Container" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [group setProperty:@"Selecting a container switches it and relaunches the app." forKey:@"footerText"];
        [specs addObject:group];
        NSDictionary *result = [NKCCommandRunner run:@[@"list", bundle ?: @""]];
        for (NSDictionary *container in NKC8ParseContainers(result[@"output"])) {
            NSString *label = [container[@"active"] boolValue] ? [@"✓ " stringByAppendingString:container[@"name"]] : container[@"name"];
            PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
            [s setProperty:bundle forKey:@"bundleID"];
            [s setProperty:container[@"id"] forKey:@"containerID"];
            [s setButtonAction:@selector(nk8QuickSwitch:)];
            [specs addObject:s];
        }
        _specifiers = [specs copy];
    }
    return _specifiers;
}
- (void)nk8QuickSwitch:(PSSpecifier *)specifier {
    NSString *bundle = [specifier propertyForKey:@"bundleID"] ?: [self.specifier propertyForKey:@"bundleID"];
    NSString *cid = [specifier propertyForKey:@"containerID"];
    if (!bundle.length || !cid.length) return;
    [NKCCommandRunner runAsync:@[@"switch", bundle, cid, @"--quiet"] completion:^(NSDictionary *result) {
        if ([result[@"status"] integerValue] != 0) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"NKCrane" message:result[@"output"] ?: @"Switch failed" preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
            return;
        }
        self->_specifiers = nil;
        [self reloadSpecifiers];
    }];
}
@end

#pragma mark - Live jobs

@implementation NKCJobsController (NKC8)
- (void)nk8_viewDidAppear:(BOOL)animated {
    [self nk8_viewDidAppear:animated];
    NSTimer *old = objc_getAssociatedObject(self, NKC8JobsTimerKey);
    [old invalidate];
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(nk8_tick:) userInfo:nil repeats:YES];
    objc_setAssociatedObject(self, NKC8JobsTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)nk8_viewWillDisappear:(BOOL)animated {
    NSTimer *timer = objc_getAssociatedObject(self, NKC8JobsTimerKey);
    [timer invalidate];
    objc_setAssociatedObject(self, NKC8JobsTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self nk8_viewWillDisappear:animated];
}
- (void)nk8_tick:(__unused NSTimer *)timer {
    if ([self respondsToSelector:NSSelectorFromString(@"refreshJobs")]) [self performSelector:NSSelectorFromString(@"refreshJobs")];
}
- (NSArray *)nk8_jobSpecifiers {
    NSArray *base = [self nk8_jobSpecifiers];
    for (PSSpecifier *s in base) {
        NSString *name = s.name;
        if ([name containsString:@" · running · "] && ![name containsString:@"50%"] ) [s setName:[name stringByAppendingString:@" · 50%"]];
        else if ([name containsString:@" · queued · "] && ![name containsString:@"5%"] ) [s setName:[name stringByAppendingString:@" · 5%"]];
        else if ([name containsString:@" · completed · "] && ![name containsString:@"100%"] ) [s setName:[name stringByAppendingString:@" · 100% ✓"]];
        else if ([name containsString:@" · failed · "] && ![name containsString:@"failed ✕"] ) [s setName:[name stringByAppendingString:@" · failed ✕"]];
    }
    return base;
}
@end

static void NKC8Swap(Class cls, SEL original, SEL replacement) {
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

__attribute__((constructor)) static void NKC8Install(void) {
    @autoreleasepool {
        NKC8Swap(NSClassFromString(@"NKCRootListController"), @selector(specifiers), @selector(nk8_specifiers));
        NKC8Swap(NSClassFromString(@"NKCAppListController"), @selector(viewDidLoad), @selector(nk8_viewDidLoad));
        NKC8Swap(NSClassFromString(@"NKCAppListController"), @selector(specifiers), @selector(nk8_appSpecifiers));
        NKC8Swap(NSClassFromString(@"NKCContainerListController"), @selector(specifiers), @selector(nk8_containerSpecifiers));
        NKC8Swap(NSClassFromString(@"NKCContainerDetailController"), @selector(specifiers), @selector(nk8_detailSpecifiers));
        NKC8Swap(NSClassFromString(@"NKCJobsController"), @selector(viewDidAppear:), @selector(nk8_viewDidAppear:));
        NKC8Swap(NSClassFromString(@"NKCJobsController"), @selector(viewWillDisappear:), @selector(nk8_viewWillDisappear:));
        NKC8Swap(NSClassFromString(@"NKCJobsController"), @selector(specifiers), @selector(nk8_jobSpecifiers));
    }
}
