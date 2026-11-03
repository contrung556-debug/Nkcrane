#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

@interface NKCRootListController : PSListController @end
@interface NKCAppListController : PSListController @end
@interface NKCContainerListController : PSListController @end
@interface NKCContainerDetailController : PSListController @end
@interface NKCJobsController : PSListController @end

#pragma mark - CLI bridge

@interface NKCCommandRunner : NSObject
+ (NSDictionary *)run:(NSArray<NSString *> *)arguments;
+ (void)runAsync:(NSArray<NSString *> *)arguments completion:(void (^)(NSDictionary *result))completion;
@end

@implementation NKCCommandRunner

+ (NSString *)toolPath {
    NSArray<NSString *> *paths = @[@"/var/jb/usr/local/bin/nkcranectl", @"/usr/local/bin/nkcranectl"];
    for (NSString *path in paths) if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) return path;
    return paths.firstObject;
}

+ (NSDictionary *)run:(NSArray<NSString *> *)arguments {
    NSString *tool = [self toolPath];
    int fds[2] = {-1, -1};
    if (pipe(fds) != 0) return @{@"status": @(-1), @"output": @"pipe() failed"};

    NSMutableArray<NSString *> *all = [NSMutableArray arrayWithObject:tool];
    [all addObjectsFromArray:arguments ?: @[]];
    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < all.count; i++) argv[i] = strdup(all[i].UTF8String ?: "");

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[1]);

    pid_t pid = 0;
    int spawnStatus = posix_spawn(&pid, tool.fileSystemRepresentation, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);

    NSMutableData *data = [NSMutableData data];
    if (spawnStatus == 0) {
        uint8_t buffer[4096];
        ssize_t n = 0;
        while ((n = read(fds[0], buffer, sizeof(buffer))) > 0) [data appendBytes:buffer length:(NSUInteger)n];
    }
    close(fds[0]);

    for (NSUInteger i = 0; i < all.count; i++) free(argv[i]);
    free(argv);

    int status = spawnStatus;
    if (spawnStatus == 0) {
        int waitStatus = 0;
        waitpid(pid, &waitStatus, 0);
        if (WIFEXITED(waitStatus)) status = WEXITSTATUS(waitStatus);
        else if (WIFSIGNALED(waitStatus)) status = 128 + WTERMSIG(waitStatus);
        else status = -1;
    }

    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    output = [output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return @{@"status": @(status), @"output": output};
}

+ (void)runAsync:(NSArray<NSString *> *)arguments completion:(void (^)(NSDictionary *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = [self run:arguments];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(result); });
    });
}

@end

#pragma mark - Helpers

static NSDictionary *NKJSON(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static NSArray *NKJSONArray(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSArray.class] ? object : nil;
}

static NSString *NKShortID(NSString *value) {
    if (value.length <= 8) return value ?: @"";
    return [value substringToIndex:8];
}

static void NKPresentMessage(UIViewController *controller, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void NKPresentError(UIViewController *controller, NSDictionary *result) {
    NSString *message = result[@"output"];
    if (!message.length) message = [NSString stringWithFormat:@"Command failed (%@)", result[@"status"] ?: @"?"];
    NKPresentMessage(controller, @"NKCrane", message);
}

static id NKObjectMessage(id object, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, sel);
}

static BOOL NKBoolMessage(id object, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, sel);
}

static NSArray<NSDictionary *> *NKInstalledApplications(void) {
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSel = NSSelectorFromString(@"defaultWorkspace");
    SEL allSel = NSSelectorFromString(@"allInstalledApplications");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultSel]) return @[];
    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSel);
    if (!workspace || ![workspace respondsToSelector:allSel]) return @[];
    NSArray *proxies = ((id (*)(id, SEL))objc_msgSend)(workspace, allSel);
    if (![proxies isKindOfClass:NSArray.class]) return @[];

    NSMutableArray<NSDictionary *> *apps = [NSMutableArray array];
    for (id proxy in proxies) {
        if (NKBoolMessage(proxy, @"isPlaceholder")) continue;
        NSString *type = NKObjectMessage(proxy, @"applicationType");
        if ([type isKindOfClass:NSString.class] && ![type isEqualToString:@"User"]) continue;
        NSString *bundle = NKObjectMessage(proxy, @"applicationIdentifier");
        if (![bundle isKindOfClass:NSString.class] || !bundle.length) bundle = NKObjectMessage(proxy, @"bundleIdentifier");
        if (![bundle isKindOfClass:NSString.class] || !bundle.length || [bundle hasPrefix:@"com.apple."]) continue;
        NSString *name = NKObjectMessage(proxy, @"localizedName");
        if (![name isKindOfClass:NSString.class] || !name.length) name = bundle;
        [apps addObject:@{@"name": name, @"bundle": bundle}];
    }
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return apps;
}

static NSArray<NSDictionary *> *NKParseContainers(NSString *output) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *line in [output componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (![line hasPrefix:@"* "]) continue;
        NSRange open = [line rangeOfString:@"[" options:NSBackwardsSearch];
        NSRange close = [line rangeOfString:@"]" options:NSBackwardsSearch];
        if (open.location == NSNotFound || close.location == NSNotFound || close.location <= open.location) continue;
        NSString *name = [[line substringWithRange:NSMakeRange(2, open.location - 3)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *identifier = [line substringWithRange:NSMakeRange(open.location + 1, close.location - open.location - 1)];
        BOOL active = [line containsString:@"<active>"];
        [items addObject:@{@"name": name.length ? name : identifier, @"id": identifier, @"active": @(active)}];
    }
    return items;
}

#pragma mark - Root

@implementation NKCRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"NKCrane" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [group setProperty:@"On-device container manager. Backup and restore jobs run in the background through nkcranectl." forKey:@"footerText"];
        [specs addObject:group];
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"Applications" target:self set:nil get:nil detail:[NKCAppListController class] cell:PSLinkCell edit:nil]];
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"Background Jobs" target:self set:nil get:nil detail:[NKCJobsController class] cell:PSLinkCell edit:nil]];
        PSSpecifier *aboutGroup = [PSSpecifier preferenceSpecifierNamed:@"About" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [specs addObject:aboutGroup];
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"Version 0.7.0" target:self set:nil get:nil detail:nil cell:PSStaticTextCell edit:nil]];
        _specifiers = [specs copy];
    }
    return _specifiers;
}

@end

#pragma mark - Applications

@implementation NKCAppListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Applications";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshApps)];
}

- (void)refreshApps {
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"Installed Apps" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [group setProperty:@"Tap an app to enable NKCrane and manage its containers." forKey:@"footerText"];
        [specs addObject:group];
        NSArray *apps = NKInstalledApplications();
        if (!apps.count) {
            [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"No user applications found" target:self set:nil get:nil detail:nil cell:PSStaticTextCell edit:nil]];
        }
        for (NSDictionary *app in apps) {
            PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:app[@"name"] target:self set:nil get:nil detail:[NKCContainerListController class] cell:PSLinkCell edit:nil];
            [s setProperty:app[@"bundle"] forKey:@"bundleID"];
            [s setProperty:app[@"name"] forKey:@"appName"];
            [specs addObject:s];
        }
        _specifiers = [specs copy];
    }
    return _specifiers;
}

@end

#pragma mark - Containers

@implementation NKCContainerListController {
    NSString *_bundleID;
    NSString *_appName;
    BOOL _enabled;
    NSArray<NSDictionary *> *_containers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _bundleID = [[self.specifier propertyForKey:@"bundleID"] copy];
    _appName = [[self.specifier propertyForKey:@"appName"] copy] ?: _bundleID;
    self.title = _appName;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(createContainer)];
    [self loadModel];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadModel];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)loadModel {
    if (!_bundleID.length) return;
    NSDictionary *status = [NKCCommandRunner run:@[@"status", _bundleID, @"--json"]];
    NSDictionary *json = NKJSON(status[@"output"]);
    _enabled = [json[@"enabled"] boolValue];
    NSDictionary *list = [NKCCommandRunner run:@[@"list", _bundleID]];
    _containers = NKParseContainers(list[@"output"]);
}

- (NSNumber *)enabledValue:(PSSpecifier *)specifier { return @(_enabled); }

- (void)setEnabledValue:(NSNumber *)value specifier:(PSSpecifier *)specifier {
    _enabled = value.boolValue;
    NSString *command = _enabled ? @"enable" : @"disable";
    [NKCCommandRunner runAsync:@[command, _bundleID] completion:^(NSDictionary *result) {
        if ([result[@"status"] integerValue] != 0) {
            self->_enabled = !self->_enabled;
            [self reloadSpecifier:specifier animated:YES];
            NKPresentError(self, result);
        }
    }];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *settingsGroup = [PSSpecifier preferenceSpecifierNamed:@"App" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [settingsGroup setProperty:_bundleID ?: @"" forKey:@"footerText"];
        [specs addObject:settingsGroup];
        PSSpecifier *enabled = [PSSpecifier preferenceSpecifierNamed:@"Enable NKCrane" target:self set:@selector(setEnabledValue:specifier:) get:@selector(enabledValue:) detail:nil cell:PSSwitchCell edit:nil];
        [specs addObject:enabled];

        PSSpecifier *containersGroup = [PSSpecifier preferenceSpecifierNamed:@"Containers" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [containersGroup setProperty:@"The checkmark marks the active container. Use + to create a new one." forKey:@"footerText"];
        [specs addObject:containersGroup];
        for (NSDictionary *container in _containers ?: @[]) {
            NSString *name = container[@"name"] ?: container[@"id"];
            if ([container[@"active"] boolValue]) name = [@"✓ " stringByAppendingString:name];
            PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self set:nil get:nil detail:[NKCContainerDetailController class] cell:PSLinkCell edit:nil];
            [s setProperty:_bundleID forKey:@"bundleID"];
            [s setProperty:_appName forKey:@"appName"];
            [s setProperty:container[@"id"] forKey:@"containerID"];
            [s setProperty:container[@"name"] forKey:@"containerName"];
            [s setProperty:container[@"active"] forKey:@"active"];
            [specs addObject:s];
        }
        _specifiers = [specs copy];
    }
    return _specifiers;
}

- (void)createContainer {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"New Container" message:@"Choose a name for this container." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Example: Account 2"; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) return;
        [NKCCommandRunner runAsync:@[@"create", self->_bundleID, name, @"--json"] completion:^(NSDictionary *result) {
            if ([result[@"status"] integerValue] != 0) { NKPresentError(self, result); return; }
            [self loadModel]; self->_specifiers = nil; [self reloadSpecifiers];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Container detail

@implementation NKCContainerDetailController {
    NSString *_bundleID;
    NSString *_appName;
    NSString *_containerID;
    NSString *_containerName;
    BOOL _active;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _bundleID = [[self.specifier propertyForKey:@"bundleID"] copy];
    _appName = [[self.specifier propertyForKey:@"appName"] copy];
    _containerID = [[self.specifier propertyForKey:@"containerID"] copy];
    _containerName = [[self.specifier propertyForKey:@"containerName"] copy] ?: _containerID;
    _active = [[self.specifier propertyForKey:@"active"] boolValue];
    self.title = _containerName;
}

- (PSSpecifier *)actionSpecifier:(NSString *)name selector:(SEL)selector {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    [s setButtonAction:selector];
    return s;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *info = [PSSpecifier preferenceSpecifierNamed:@"Container" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        NSString *footer = [NSString stringWithFormat:@"%@\nID: %@%@", _appName ?: _bundleID, _containerID ?: @"", _active ? @"\nCurrently active" : @""];
        [info setProperty:footer forKey:@"footerText"];
        [specs addObject:info];
        if (!_active) [specs addObject:[self actionSpecifier:@"Switch to This Container" selector:@selector(switchContainer)]];
        [specs addObject:[self actionSpecifier:@"Backup in Background" selector:@selector(backupContainer)]];
        [specs addObject:[self actionSpecifier:@"Clone Container" selector:@selector(cloneContainer)]];
        if (![_containerID isEqualToString:@"default"]) {
            [specs addObject:[self actionSpecifier:@"Restore Backup…" selector:@selector(restoreContainer)]];
            [specs addObject:[self actionSpecifier:@"Rename" selector:@selector(renameContainer)]];
            PSSpecifier *danger = [PSSpecifier preferenceSpecifierNamed:@"Danger Zone" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
            [danger setProperty:@"Wipe clears data but keeps the container. Delete removes the container itself." forKey:@"footerText"];
            [specs addObject:danger];
            [specs addObject:[self actionSpecifier:@"Wipe Container" selector:@selector(wipeContainer)]];
            [specs addObject:[self actionSpecifier:@"Delete Container" selector:@selector(deleteContainer)]];
        }
        _specifiers = [specs copy];
    }
    return _specifiers;
}

- (void)runCommand:(NSArray<NSString *> *)arguments success:(void (^)(NSDictionary *result))success {
    [NKCCommandRunner runAsync:arguments completion:^(NSDictionary *result) {
        if ([result[@"status"] integerValue] != 0) { NKPresentError(self, result); return; }
        if (success) success(result);
    }];
}

- (void)switchContainer {
    [self runCommand:@[@"switch", _bundleID, _containerID, @"--quiet"] success:^(__unused NSDictionary *result) {
        self->_active = YES; self->_specifiers = nil; [self reloadSpecifiers];
        NKPresentMessage(self, @"NKCrane", @"Container switched and the app was relaunched.");
    }];
}

- (void)backupContainer {
    [self runCommand:@[@"backup", _bundleID, _containerID, @"--safe", @"--background", @"--json"] success:^(NSDictionary *result) {
        NSDictionary *json = NKJSON(result[@"output"]);
        NSString *job = json[@"job_id"];
        NSString *message = job.length ? [NSString stringWithFormat:@"Backup started in background.\nJob: %@", NKShortID(job)] : @"Backup started in background.";
        NKPresentMessage(self, @"Backup Started", message);
    }];
}

- (void)cloneContainer {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clone Container" message:@"Name the new copy." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Copy name"; field.text = [self->_containerName stringByAppendingString:@" Copy"]; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clone" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) return;
        [self runCommand:@[@"clone", self->_bundleID, self->_containerID, name, @"--json"] success:^(__unused NSDictionary *result) { NKPresentMessage(self, @"NKCrane", @"Container cloned successfully."); }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)restoreContainer {
    NSDictionary *result = [NKCCommandRunner run:@[@"backups", _bundleID]];
    if ([result[@"status"] integerValue] != 0) { NKPresentError(self, result); return; }
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *line in [result[@"output"] componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) if ([line.pathExtension isEqualToString:@"nkcb"]) [paths addObject:line];
    if (!paths.count) { NKPresentMessage(self, @"Restore", @"No NKCrane backups were found for this app."); return; }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Restore Backup" message:@"The app family will be stopped while the backup is restored." preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *path in [paths reverseObjectEnumerator]) {
        [sheet addAction:[UIAlertAction actionWithTitle:path.lastPathComponent style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self runCommand:@[@"restore", self->_bundleID, self->_containerID, path, @"--background", @"--json"] success:^(NSDictionary *r) {
                NSDictionary *json = NKJSON(r[@"output"]);
                NSString *job = json[@"job_id"];
                NSString *message = job.length ? [NSString stringWithFormat:@"Restore started in background.\nJob: %@", NKShortID(job)] : @"Restore started in background.";
                NKPresentMessage(self, @"Restore Started", message);
            }];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) { popover.sourceView = self.view; popover.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1); }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)renameContainer {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Container" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = self->_containerName; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) return;
        [self runCommand:@[@"rename", self->_bundleID, self->_containerID, name, @"--quiet"] success:^(__unused NSDictionary *result) { self->_containerName = name; self.title = name; NKPresentMessage(self, @"NKCrane", @"Container renamed."); }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)wipeContainer {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Wipe Container?" message:@"All app data in this container will be permanently erased." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Wipe" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self runCommand:@[@"wipe", self->_bundleID, self->_containerID, @"--quiet"] success:^(__unused NSDictionary *result) { NKPresentMessage(self, @"NKCrane", @"Container wiped."); }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)deleteContainer {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete Container?" message:@"This permanently removes the container and its data." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self runCommand:@[@"delete", self->_bundleID, self->_containerID, @"--quiet"] success:^(__unused NSDictionary *result) {
            [self.navigationController popViewControllerAnimated:YES];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Jobs

@implementation NKCJobsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Background Jobs";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshJobs)];
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self refreshJobs]; }

- (void)refreshJobs { _specifiers = nil; [self reloadSpecifiers]; }

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"Recent Jobs" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [group setProperty:@"Backup and restore continue outside Settings. Refresh to see updated state." forKey:@"footerText"];
        [specs addObject:group];
        NSDictionary *result = [NKCCommandRunner run:@[@"jobs"]];
        NSArray *jobs = NKJSONArray(result[@"output"]);
        if (!jobs.count) {
            [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"No background jobs yet" target:self set:nil get:nil detail:nil cell:PSStaticTextCell edit:nil]];
        } else {
            NSArray *ordered = [jobs sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [b[@"updated_at"] compare:a[@"updated_at"]];
            }];
            for (NSDictionary *job in ordered) {
                NSString *op = [job[@"operation"] uppercaseString] ?: @"JOB";
                NSString *state = job[@"state"] ?: @"unknown";
                NSString *jobID = job[@"job_id"] ?: @"";
                NSString *label = [NSString stringWithFormat:@"%@ · %@ · %@", op, state, NKShortID(jobID)];
                [specs addObject:[PSSpecifier preferenceSpecifierNamed:label target:self set:nil get:nil detail:nil cell:PSStaticTextCell edit:nil]];
            }
        }
        _specifiers = [specs copy];
    }
    return _specifiers;
}

@end
