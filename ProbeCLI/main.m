#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import <mach/mach.h>
#import <mach/task_info.h>
#import <mach/vm_map.h>
#import <mach-o/dyld_images.h>
#import <unistd.h>
#import <sys/stat.h>
#import <errno.h>
#include "NKCLaunchCapsule.h"

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSURL *containerURL;
@property (nonatomic, readonly) NSString *bundleExecutable;
@end

static NSString * const NKCRegistryPath = @"/var/mobile/Library/NKCrane/Public/registry.json";
static NSString * const NKCPhysicalContainerDirectory = @"__NKCrane_Containers";

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

static id AppProxy(NSString *bundle) {
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices",RTLD_LAZY);
    Class c=NSClassFromString(@"LSApplicationProxy"); SEL s=NSSelectorFromString(@"applicationProxyForIdentifier:");
    if(!c||![c respondsToSelector:s]) return nil;
    return ((id(*)(id,SEL,id))objc_msgSend)(c,s,bundle);
}

static NSString *ContainerPath(NSString *bundle) {
    id p=AppProxy(bundle); SEL u=NSSelectorFromString(@"containerURL");
    if(!p||![p respondsToSelector:u]) return nil;
    id url=((id(*)(id,SEL))objc_msgSend)(p,u);
    return [url isKindOfClass:NSURL.class]?[url path]:nil;
}

static NSString *ExecutableName(NSString *bundle) {
    id p=AppProxy(bundle); SEL s=NSSelectorFromString(@"bundleExecutable");
    if(!p||![p respondsToSelector:s]) return nil;
    id value=((id(*)(id,SEL))objc_msgSend)(p,s);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSArray<NSNumber *> *PIDsForExecutable(NSString *name) {
    if(!name.length) return @[];
    int mib[4]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0}; size_t size=0;
    if(sysctl(mib,4,NULL,&size,NULL,0)!=0||!size) return @[];
    struct kinfo_proc *procs=calloc(1,size); if(!procs) return @[];
    if(sysctl(mib,4,procs,&size,NULL,0)!=0){free(procs);return @[];}
    NSUInteger count=size/sizeof(struct kinfo_proc); NSMutableArray *out=[NSMutableArray array];
    for(NSUInteger i=0;i<count;i++){
        pid_t pid=procs[i].kp_proc.p_pid; if(pid<=1||pid==getpid()) continue;
        NSString *comm=[NSString stringWithUTF8String:procs[i].kp_proc.p_comm?:""];
        if([comm isEqualToString:name]) [out addObject:@(pid)];
    }
    free(procs); return out;
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

static BOOL FileExists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static NSDictionary *PhysicalRuntimeDiagnostics(NSString *home, NSString *active) {
    NSMutableDictionary *out=[NSMutableDictionary dictionary];
    if(!home.length){
        out[@"available"]=@NO;
        out[@"reason"]=@"live app data root unavailable";
        return out;
    }
    if(!active.length||[active isEqualToString:@"default"]){
        out[@"available"]=@YES;
        out[@"active_is_default"]=@YES;
        return out;
    }

    NSString *physical=[[[home stringByAppendingPathComponent:@"Library"]
                          stringByAppendingPathComponent:NKCPhysicalContainerDirectory]
                          stringByAppendingPathComponent:active];
    NSString *runtimeMarker=[physical stringByAppendingPathComponent:@".nkcrane-runtime.json"];
    NSString *layoutMarker=[physical stringByAppendingPathComponent:@".nkcrane-layout.json"];
    NSString *legacy=[[[home stringByAppendingPathComponent:@".nkcrane"]
                       stringByAppendingPathComponent:active]
                       stringByAppendingPathComponent:@"Root"];

    NSFileManager *fm=NSFileManager.defaultManager;
    BOOL physicalIsDir=NO;
    BOOL physicalExists=[fm fileExistsAtPath:physical isDirectory:&physicalIsDir];
    // fileExistsAtPath follows symlinks and reports NO for a dangling one.
    // lstat differentiates absent, broken symlink and existing real directory.
    struct stat legacyStat = {0};
    int legacyStatResult = lstat(legacy.fileSystemRepresentation, &legacyStat);
    int legacyErrno = (legacyStatResult == 0) ? 0 : errno;
    BOOL legacyExists = legacyStatResult == 0;
    BOOL legacySymlink = legacyExists && S_ISLNK(legacyStat.st_mode);
    NSString *legacyDestination = legacySymlink
        ? [fm destinationOfSymbolicLinkAtPath:legacy error:nil] : nil;
    NSString *normalizedDestination = [legacyDestination stringByResolvingSymlinksInPath];
    NSString *normalizedPhysical = [physical stringByResolvingSymlinksInPath];
    BOOL legacyLinkValid = legacySymlink && [fm fileExistsAtPath:legacy] &&
        normalizedDestination.length && [normalizedDestination isEqualToString:normalizedPhysical];
    NSDictionary *runtime=ReadJSON(runtimeMarker);
    NSDictionary *layout=ReadJSON(layoutMarker);

    out[@"available"]=@YES;
    out[@"active_is_default"]=@NO;
    out[@"physical_root"]=physical;
    out[@"physical_root_exists"]=@(physicalExists&&physicalIsDir);
    out[@"runtime_marker_path"]=runtimeMarker;
    out[@"runtime_marker_seen"]=@(runtime!=nil);
    if(runtime) out[@"runtime_marker"]=runtime;
    out[@"layout_marker_path"]=layoutMarker;
    out[@"layout_marker_seen"]=@(layout!=nil);
    if(layout) out[@"layout_marker"]=layout;
    out[@"legacy_root"]=legacy;
    out[@"legacy_root_exists"]=@(legacyExists);
    out[@"legacy_root_is_symlink"]=@(legacySymlink);
    out[@"legacy_root_target_exists"]=@([fm fileExistsAtPath:legacy]);
    out[@"legacy_root_lstat_errno"]=@(legacyErrno);
    if(legacyDestination.length) out[@"legacy_root_destination"]=legacyDestination;
    out[@"legacy_points_to_physical"]=@(legacyLinkValid);
    out[@"legacy_link_status"]=legacyLinkValid ? @"ok" :
        (!legacyExists ? @"missing" : (legacySymlink ? @"broken_or_wrong_target" : @"occupied_directory"));
    return out;
}

static NSDictionary *ChoicyDiagnostics(NSString *bundle) {
    NSArray *candidatePrefs=@[
        @"/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.opa334.choicyprefs.plist"
    ];
    NSString *prefsPath=nil; NSDictionary *prefs=nil;
    for(NSString *path in candidatePrefs){
        NSDictionary *obj=[NSDictionary dictionaryWithContentsOfFile:path];
        if([obj isKindOfClass:NSDictionary.class]){prefsPath=path;prefs=obj;break;}
    }
    BOOL installed = FileExists(@"/var/jb/Library/MobileSubstrate/DynamicLibraries/ Choicy.dylib") ||
                     FileExists(@"/var/jb/usr/lib/TweakInject/ Choicy.dylib") || prefs != nil;
    NSMutableDictionary *out=[NSMutableDictionary dictionaryWithObject:@(installed) forKey:@"installed"];
    if(prefsPath) out[@"prefs_path"]=prefsPath;
    if(!prefs) return out;

    NSDictionary *appSettings=[prefs[@"appSettings"] isKindOfClass:NSDictionary.class]?prefs[@"appSettings"]:@{};
    NSDictionary *app=[appSettings[bundle] isKindOfClass:NSDictionary.class]?appSettings[bundle]:nil;
    NSArray *globalDenied=[prefs[@"globalDeniedTweaks"] isKindOfClass:NSArray.class]?prefs[@"globalDeniedTweaks"]:@[];
    out[@"global_denies_nkcrane"]=@([globalDenied containsObject:@"NKCrane"]);
    if(app){
        out[@"app_settings_seen"]=@YES;
        out[@"tweak_injection_disabled"]=@([app[@"tweakInjectionDisabled"] boolValue]);
        out[@"custom_config_enabled"]=@([app[@"customTweakConfigurationEnabled"] boolValue]);
        NSArray *denied=[app[@"deniedTweaks"] isKindOfClass:NSArray.class]?app[@"deniedTweaks"]:@[];
        NSArray *allowed=[app[@"allowedTweaks"] isKindOfClass:NSArray.class]?app[@"allowedTweaks"]:@[];
        out[@"app_denies_nkcrane"]=@([denied containsObject:@"NKCrane"]);
        out[@"app_allows_nkcrane"]=@([allowed containsObject:@"NKCrane"]);
    } else {
        out[@"app_settings_seen"]=@NO;
    }
    return out;
}

static NSString *ReadRemoteCString(task_t task, vm_address_t address, NSUInteger maxLen) {
    if(!address||!maxLen) return nil;
    NSMutableData *data=[NSMutableData data];
    const NSUInteger chunk=128;
    for(NSUInteger offset=0;offset<maxLen;offset+=chunk){
        char buf[chunk]; vm_size_t outSize=0;
        kern_return_t kr=vm_read_overwrite(task,address+(vm_address_t)offset,(vm_size_t)MIN(chunk,maxLen-offset),(vm_address_t)buf,&outSize);
        if(kr!=KERN_SUCCESS||outSize==0) break;
        for(vm_size_t i=0;i<outSize;i++){
            if(buf[i]=='\0') return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            [data appendBytes:&buf[i] length:1];
        }
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSDictionary *LoadedImageDiagnostics(pid_t pid) {
    NSMutableDictionary *out=[NSMutableDictionary dictionaryWithObject:@(pid) forKey:@"pid"];
    task_t task=MACH_PORT_NULL;
    kern_return_t kr=task_for_pid(mach_task_self(),pid,&task);
    out[@"task_for_pid_kr"]=@(kr);
    if(kr!=KERN_SUCCESS||task==MACH_PORT_NULL){out[@"process_images_readable"]=@NO;out[@"loader_status"]=@"UNKNOWN_task_for_pid_denied_or_unavailable";return out;}

    task_dyld_info_data_t dyldInfo={0}; mach_msg_type_number_t count=TASK_DYLD_INFO_COUNT;
    kr=task_info(task,TASK_DYLD_INFO,(task_info_t)&dyldInfo,&count);
    out[@"task_dyld_info_kr"]=@(kr);
    if(kr!=KERN_SUCCESS||!dyldInfo.all_image_info_addr){mach_port_deallocate(mach_task_self(),task);out[@"process_images_readable"]=@NO;return out;}

    struct dyld_all_image_infos infos={0}; vm_size_t copied=0;
    kr=vm_read_overwrite(task,(vm_address_t)dyldInfo.all_image_info_addr,(vm_size_t)sizeof(infos),(vm_address_t)&infos,&copied);
    if(kr!=KERN_SUCCESS||copied<sizeof(infos)){mach_port_deallocate(mach_task_self(),task);out[@"process_images_readable"]=@NO;return out;}

    uint32_t imageCount=MIN(infos.infoArrayCount,2048U);
    out[@"image_count"]=@(imageCount);
    if(!infos.infoArray||imageCount==0){mach_port_deallocate(mach_task_self(),task);out[@"process_images_readable"]=@YES;return out;}

    size_t bytes=(size_t)imageCount*sizeof(struct dyld_image_info);
    struct dyld_image_info *images=calloc(imageCount,sizeof(struct dyld_image_info));
    if(!images){mach_port_deallocate(mach_task_self(),task);out[@"process_images_readable"]=@NO;return out;}
    copied=0; kr=vm_read_overwrite(task,(vm_address_t)infos.infoArray,(vm_size_t)bytes,(vm_address_t)images,&copied);
    if(kr!=KERN_SUCCESS){free(images);mach_port_deallocate(mach_task_self(),task);out[@"process_images_readable"]=@NO;return out;}

    BOOL nk=NO, elle=NO, choicy=NO; NSMutableArray *interesting=[NSMutableArray array];
    for(uint32_t i=0;i<imageCount;i++){
        NSString *path=ReadRemoteCString(task,(vm_address_t)images[i].imageFilePath,1024);
        if(!path.length) continue;
        NSString *lower=path.lowercaseString;
        BOOL isInteresting=NO;
        if([lower containsString:@"nkcrane.dylib"]){nk=YES;isInteresting=YES;}
        if([lower containsString:@"ellekit"]||[lower containsString:@"tweakloader"]||[lower containsString:@"systemhook.dylib"]){elle=YES;isInteresting=YES;}
        if([lower containsString:@"choicy.dylib"]){choicy=YES;isInteresting=YES;}
        if(isInteresting&&interesting.count<20) [interesting addObject:path];
    }
    free(images); mach_port_deallocate(mach_task_self(),task);
    out[@"process_images_readable"]=@YES;
    out[@"loader_status"]=@"images_enumerated";
    out[@"nkcrane_loaded"]=@(nk);
    out[@"loader_images_seen"]=@(elle);
    out[@"choicy_loaded"]=@(choicy);
    out[@"interesting_images"]=interesting;
    return out;
}


// Read-only diagnostics. This is NOT a trusted daemon resolver and never
// changes the active container: ABSENT/UNKNOWN must not mean DEFAULT.
static NSDictionary *LaunchCapsuleDiagnostics(pid_t pid) {
    if (pid <= 1) return @{@"status": @"UNKNOWN", @"reason": @"invalid_pid"};
    int mibArgmax[2] = {CTL_KERN, KERN_ARGMAX};
    int argmax = 0;
    size_t argmaxSize = sizeof(argmax);
    if (sysctl(mibArgmax, 2, &argmax, &argmaxSize, NULL, 0) != 0 ||
        argmax <= 0 || argmax > (4 * 1024 * 1024)) {
        return @{@"status": @"UNKNOWN", @"reason": @"argmax_unavailable"};
    }
    void *buffer = calloc(1, (size_t)argmax);
    if (!buffer) return @{@"status": @"UNKNOWN", @"reason": @"alloc_failed"};
    size_t length = (size_t)argmax;
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    if (sysctl(mib, 3, buffer, &length, NULL, 0) != 0) {
        free(buffer);
        return @{@"status": @"UNKNOWN", @"reason": @"procargs_read_failed"};
    }
    NKCLaunchCapsule capsule = NKCParseProcArgs2(buffer, length);
    free(buffer);
    NSMutableDictionary *result = [@{
        @"status": [NSString stringWithUTF8String:NKCCapsuleStatusName(capsule.status)],
        @"source": @"KERN_PROCARGS2",
        @"diagnostic_only": @YES
    } mutableCopy];
    if (capsule.status == NKC_CAPSULE_NAMED)
        result[@"container_id"] = [NSString stringWithUTF8String:capsule.uuid];
    return result;
}

static void PrintJSON(id obj) {
    NSData *d=[NSJSONSerialization dataWithJSONObject:obj?:@{} options:NSJSONWritingPrettyPrinted error:nil];
    if(d) fwrite(d.bytes,1,d.length,stdout); fputc('\n',stdout);
}


static NSDictionary *BriefDict(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
static NSString *BriefBool(id value) {
    return [value isKindOfClass:NSNumber.class] ? ([value boolValue] ? @"YES" : @"NO") : @"UNKNOWN";
}
static NSString *BriefAge(id value) {
    if (![value isKindOfClass:NSNumber.class]) return @"?";
    NSTimeInterval seconds = NSDate.date.timeIntervalSince1970 - [value doubleValue];
    if (seconds < -60) return @"clock-skew";
    if (seconds < 0) seconds = 0;
    if (seconds < 3600) return [NSString stringWithFormat:@"%ldm", (long)(seconds / 60)];
    if (seconds < 86400) return [NSString stringWithFormat:@"%ldh", (long)(seconds / 3600)];
    return [NSString stringWithFormat:@"%ldd", (long)(seconds / 86400)];
}

// Compact, read-only evidence. No full sandbox paths or Keychain values.
// UNKNOWN image access must never be interpreted as a missing dylib.
static void PrintBrief(NSDictionary *out) {
    NSDictionary *physical = BriefDict(out[@"physical_runtime"]);
    NSDictionary *runtime = BriefDict(physical[@"runtime_marker"]);
    NSDictionary *shim = BriefDict(out[@"registry_runtime"]);
    NSDictionary *loader = BriefDict(out[@"loader_truth"]);
    NSDictionary *choicy = BriefDict(out[@"choicy"]);
    NSArray *pids = [out[@"running_pids"] isKindOfClass:NSArray.class] ? out[@"running_pids"] : @[];
    NSString *active = [out[@"registry_active"] isKindOfClass:NSString.class] ? out[@"registry_active"] : nil;
    BOOL named = active.length && ![active isEqualToString:@"default"];
    BOOL running = pids.count > 0;
    BOOL readable = [loader[@"process_images_readable"] isKindOfClass:NSNumber.class] &&
                    [loader[@"process_images_readable"] boolValue];
    BOOL loaded = readable && [loader[@"nkcrane_loaded"] boolValue];
    BOOL rootOK = [physical[@"physical_root_exists"] boolValue];
    BOOL runtimeOK = [physical[@"runtime_marker_seen"] boolValue] &&
                     [runtime[@"active_container_id"] isEqualToString:active];
    BOOL shimOK = [out[@"shim_seen"] boolValue] &&
                  [shim[@"active_container_id"] isEqualToString:active];
    NSNumber *shimPID = [shim[@"pid"] isKindOfClass:NSNumber.class] ? shim[@"pid"] : nil;
    BOOL pidMatches = running && shimPID && [pids containsObject:shimPID];
    BOOL blocked = [choicy[@"tweak_injection_disabled"] boolValue] ||
                   [choicy[@"app_denies_nkcrane"] boolValue] ||
                   [choicy[@"global_denies_nkcrane"] boolValue];
    BOOL safeMode = [out[@"dopamine_safe_mode"] boolValue];
    NSString *shortID = named ? [active substringToIndex:MIN((NSUInteger)8, active.length)] : (active ?: @"UNKNOWN");
    NSString *loaderStatus = !running ? @"UNKNOWN (app stopped)" :
        !readable ? @"UNKNOWN (task_for_pid)" : (loaded ? @"YES" : @"NO");
    NSString *linkStatus = [physical[@"legacy_link_status"] isKindOfClass:NSString.class]
        ? physical[@"legacy_link_status"] : @"UNKNOWN";
    NSString *runtimeStatus = [physical[@"runtime_marker_seen"] boolValue] ?
        [NSString stringWithFormat:@"YES v%@ age=%@", runtime[@"version"] ?: @"?", BriefAge(runtime[@"timestamp"])] : @"NO";
    NSString *shimStatus = [out[@"shim_seen"] boolValue] ?
        [NSString stringWithFormat:@"YES v%@ age=%@ %@", shim[@"version"] ?: @"?", BriefAge(shim[@"timestamp"]),
          !running ? @"PID=UNKNOWN" : (!shimPID ? @"PID=UNKNOWN" : (pidMatches ? @"PID=MATCH" : @"PID=STALE"))] : @"NO";

    NSString *result;
    NSString *next;
    if (![out[@"registry_seen"] boolValue]) {
        result = @"REGISTRY_UNREADABLE"; next = @"Check registry read permissions";
    } else if (![out[@"enabled"] boolValue]) {
        result = @"APP_NOT_ENABLED"; next = @"Enable NKCrane for app";
    } else if (!named) {
        result = @"DEFAULT_SELECTED"; next = @"Select named container";
    } else if (blocked || safeMode) {
        result = @"INJECTION_MAY_BE_BLOCKED"; next = @"Check Choicy and safe mode";
    } else if (!running) {
        result = @"APP_NOT_RUNNING"; next = @"Launch app and retry";
    } else if (readable && !loaded) {
        result = @"DYLIB_NOT_LISTED"; next = @"Check tweak injection";
    } else if (!rootOK) {
        result = @"PHYSICAL_ROOT_MISSING"; next = @"Check container layout";
    } else if (!runtimeOK) {
        result = @"RUNTIME_MARKER_MISSING_OR_WRONG"; next = @"Relaunch app; check runtime";
    } else if (!shimOK || (shimPID && !pidMatches)) {
        result = @"SHIM_MARKER_MISSING_OR_STALE"; next = @"Relaunch app; check marker PID";
    } else if (!readable) {
        result = @"MARKERS_PRESENT_LOADER_UNKNOWN"; next = @"Loader not independently verified";
    } else {
        result = @"APP_RUNTIME_EVIDENCE_OK"; next = @"Test data isolation separately";
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithArray:@[
        @"=== NKCRANE QUICK CHECK v1.4.2 ===",
        [NSString stringWithFormat:@"App: %@", out[@"bundle"] ?: @"?"],
        [NSString stringWithFormat:@"Registry: %@ Enabled: %@", BriefBool(out[@"registry_seen"]), BriefBool(out[@"enabled"])],
        [NSString stringWithFormat:@"Container: %@ %@", named ? @"NAMED" : @"DEFAULT/UNKNOWN", shortID],
        [NSString stringWithFormat:@"Process: %@", running ? [NSString stringWithFormat:@"RUNNING pid=%@", pids.firstObject] : @"STOPPED"],
        [NSString stringWithFormat:@"NKCrane dylib: %@", loaderStatus],
        [NSString stringWithFormat:@"Physical root: %@", BriefBool(physical[@"physical_root_exists"])],
        [NSString stringWithFormat:@"Runtime marker: %@", runtimeStatus],
        [NSString stringWithFormat:@"Shim marker: %@", shimStatus],
        [NSString stringWithFormat:@"Layout marker: %@", BriefBool(physical[@"layout_marker_seen"])],
        [NSString stringWithFormat:@"Legacy link: %@", linkStatus],
        [NSString stringWithFormat:@"Choicy block: %@", blocked ? @"YES" : @"NO RULE FOUND"],
        [NSString stringWithFormat:@"Safe mode: %@", BriefBool(out[@"dopamine_safe_mode"])],
        [NSString stringWithFormat:@"Result: %@", result],
        [NSString stringWithFormat:@"Next: %@", next],
        @"Note: NOT proof of session isolation."
    ]];
    NSString *report = [lines componentsJoinedByString:@"\n"];
    fputs(report.UTF8String, stdout);
    fputc('\n', stdout);
}

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: nkcraneprobe <bundle-id> [--brief]\n");
            return 1;
        }
        NSString *bundle = nil;
        BOOL brief = NO;
        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"--brief"]) brief = YES;
            else if ([arg hasPrefix:@"-"] || bundle) {
                fprintf(stderr, "usage: nkcraneprobe <bundle-id> [--brief]\n");
                return 1;
            } else bundle = arg;
        }
        if (!bundle.length) {
            fprintf(stderr, "missing bundle ID\n");
            return 1;
        }
        NSDictionary *registry=ReadJSON(NKCRegistryPath);
        NSString *owner=registry?ResolveOwner(registry,bundle):bundle;
        NSDictionary *apps=[registry[@"apps"] isKindOfClass:NSDictionary.class]?registry[@"apps"]:@{};
        NSDictionary *entry=[apps[owner] isKindOfClass:NSDictionary.class]?apps[owner]:nil;
        NSString *active=[entry[@"active"] isKindOfClass:NSString.class]?entry[@"active"]:@"default";
        NSString *home=ContainerPath(owner);
        NSString *executable=ExecutableName(bundle);
        NSArray<NSNumber *> *pids=PIDsForExecutable(executable);

        NSMutableDictionary *out=[NSMutableDictionary dictionary];
        out[@"mode"]=@"v1.4.2-runtime-diagnostics";
        out[@"bundle"]=bundle?:@"";
        out[@"owner"]=owner?:@"";
        out[@"executable"]=executable?:@"";
        out[@"running_pids"]=pids;
        out[@"registry_path"]=NKCRegistryPath;
        out[@"registry_seen"]=@(registry!=nil);
        out[@"dopamine_safe_mode"]=@(FileExists(@"/var/jb/basebin/.safe_mode")||FileExists(@"/basebin/.safe_mode"));
        out[@"choicy"]=ChoicyDiagnostics(bundle);
        if(entry){
            out[@"enabled"]=@([entry[@"enabled"] boolValue]);
            out[@"registry_active"]=active;
        }
        if(home.length){
            out[@"live_root"]=home;
            NSString *physicalShim = [[[[home stringByAppendingPathComponent:@"Library"]
                 stringByAppendingPathComponent:NKCPhysicalContainerDirectory]
                 stringByAppendingPathComponent:active]
                 stringByAppendingPathComponent:@".nkcrane-shim.json"];
            NSString *legacyShim=[home stringByAppendingPathComponent:
                 [NSString stringWithFormat:@".nkcrane/runtime-registry-%@.json",Safe(bundle)]];
            NSDictionary *runtime = ReadJSON(physicalShim);
            NSString *marker = physicalShim;
            if (!runtime) { runtime=ReadJSON(legacyShim); marker=legacyShim; }
            out[@"registry_marker_path"]=marker;
            out[@"shim_seen"]=@(runtime!=nil);
            out[@"shim_marker_source"]=runtime ? ([marker isEqualToString:physicalShim] ? @"physical" : @"legacy") : @"missing";
            if(runtime) out[@"registry_runtime"]=runtime;
            out[@"physical_runtime"]=PhysicalRuntimeDiagnostics(home,active);
        } else {
            out[@"shim_seen"]=@NO;
            out[@"physical_runtime"]=PhysicalRuntimeDiagnostics(nil,active);
            out[@"error"]=@"container path unavailable";
        }
        NSMutableArray *capsules = [NSMutableArray array];
        for (NSNumber *pid in [pids subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)8, pids.count))]) {
            NSMutableDictionary *item = [LaunchCapsuleDiagnostics((pid_t)pid.intValue) mutableCopy];
            item[@"pid"] = pid;
            [capsules addObject:item];
        }
        out[@"process_launch_capsules"] = capsules;
        out[@"launch_capsule_contract"] = @"v1.4-diagnostics-only";
        if(pids.count>0) out[@"loader_truth"]=LoadedImageDiagnostics((pid_t)pids.firstObject.intValue);
        else out[@"loader_truth"]=@{ @"process_running": @NO };
        if (brief) PrintBrief(out);
        else PrintJSON(out);
        return 0;
    }
}
