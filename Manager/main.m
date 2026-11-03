#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static NSDictionary *NKRun(NSArray<NSString *> *args) {
    NSString *tool = @"/var/jb/usr/local/bin/nkcranectl";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:tool]) tool = @"/usr/local/bin/nkcranectl";
    int fds[2] = {-1,-1};
    if (pipe(fds) != 0) return @{@"status":@(-1), @"output":@"pipe failed"};
    NSMutableArray *all = [NSMutableArray arrayWithObject:tool];
    [all addObjectsFromArray:args ?: @[]];
    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i=0;i<all.count;i++) argv[i] = strdup(all[i].UTF8String ?: "");
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[1]);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, tool.fileSystemRepresentation, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);
    NSMutableData *data = [NSMutableData data];
    if (rc == 0) {
        uint8_t buf[4096]; ssize_t n;
        while ((n = read(fds[0], buf, sizeof(buf))) > 0) [data appendBytes:buf length:(NSUInteger)n];
    }
    close(fds[0]);
    for (NSUInteger i=0;i<all.count;i++) free(argv[i]);
    free(argv);
    int status = rc;
    if (rc == 0) {
        int ws = 0; waitpid(pid, &ws, 0);
        status = WIFEXITED(ws) ? WEXITSTATUS(ws) : -1;
    }
    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return @{@"status":@(status), @"output":[out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]};
}

static NSDictionary *NKJSON(NSString *text) {
    NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!d.length) return nil;
    id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return [o isKindOfClass:NSDictionary.class] ? o : nil;
}

static NSArray<NSDictionary *> *NKContainers(NSString *text) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (![line hasPrefix:@"* "]) continue;
        NSRange a = [line rangeOfString:@"[" options:NSBackwardsSearch];
        NSRange b = [line rangeOfString:@"]" options:NSBackwardsSearch];
        if (a.location == NSNotFound || b.location == NSNotFound || b.location <= a.location) continue;
        NSString *name = [[line substringWithRange:NSMakeRange(2, a.location-3)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *cid = [line substringWithRange:NSMakeRange(a.location+1, b.location-a.location-1)];
        [out addObject:@{@"name":name.length?name:cid, @"id":cid, @"active":@([line containsString:@"<active>"])}];
    }
    return out;
}

static id NKObj(id obj, NSString *selName) {
    SEL s = NSSelectorFromString(selName);
    if (!obj || ![obj respondsToSelector:s]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(obj,s);
}

static BOOL NKBool(id obj, NSString *selName) {
    SEL s = NSSelectorFromString(selName);
    if (!obj || ![obj respondsToSelector:s]) return NO;
    return ((BOOL(*)(id,SEL))objc_msgSend)(obj,s);
}

static NSArray<NSDictionary *> *NKApps(void) {
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    SEL ds = NSSelectorFromString(@"defaultWorkspace");
    SEL as = NSSelectorFromString(@"allInstalledApplications");
    if (!cls || ![cls respondsToSelector:ds]) return @[];
    id ws = ((id(*)(id,SEL))objc_msgSend)(cls,ds);
    if (!ws || ![ws respondsToSelector:as]) return @[];
    NSArray *proxies = ((id(*)(id,SEL))objc_msgSend)(ws,as);
    if (![proxies isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *apps = [NSMutableArray array];
    for (id p in proxies) {
        if (NKBool(p,@"isPlaceholder")) continue;
        NSString *type = NKObj(p,@"applicationType");
        if ([type isKindOfClass:NSString.class] && ![type isEqualToString:@"User"]) continue;
        NSString *bid = NKObj(p,@"applicationIdentifier");
        if (![bid isKindOfClass:NSString.class] || !bid.length) bid = NKObj(p,@"bundleIdentifier");
        if (![bid isKindOfClass:NSString.class] || !bid.length || [bid hasPrefix:@"com.apple."] || [bid isEqualToString:@"com.nktouch.nkcrane.manager"]) continue;
        NSString *name = NKObj(p,@"localizedName");
        if (![name isKindOfClass:NSString.class] || !name.length) name = bid;
        [apps addObject:@{@"name":name,@"bundle":bid}];
    }
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){ return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]]; }];
    return apps;
}

static void NKAlert(UIViewController *vc, NSString *title, NSString *message) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}

@interface NKAppDetailController : UITableViewController
- (instancetype)initWithApp:(NSDictionary *)app;
@end

@interface NKAppListController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic,strong) NSArray<NSDictionary *> *apps;
@property(nonatomic,strong) NSArray<NSDictionary *> *filtered;
@end

@implementation NKAppListController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"NKCrane";
    self.navigationItem.prompt = @"Container Manager · v0.8.2";
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    UISearchController *s = [[UISearchController alloc] initWithSearchResultsController:nil];
    s.searchResultsUpdater = self;
    s.obscuresBackgroundDuringPresentation = NO;
    s.searchBar.placeholder = @"Tìm ứng dụng";
    self.navigationItem.searchController = s;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadApps)];
    [self reloadApps];
}
- (void)reloadApps { self.apps = NKApps(); self.filtered = self.apps; [self.tableView reloadData]; }
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *q = [searchController.searchBar.text lowercaseString];
    if (!q.length) self.filtered = self.apps;
    else self.filtered = [self.apps filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *a, NSDictionary *bindings){ return [[a[@"name"] lowercaseString] containsString:q] || [[a[@"bundle"] lowercaseString] containsString:q]; }]];
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.filtered.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"app"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
    NSDictionary *a = self.filtered[indexPath.row];
    c.textLabel.text = a[@"name"]; c.detailTextLabel.text = a[@"bundle"]; c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self.navigationController pushViewController:[[NKAppDetailController alloc] initWithApp:self.filtered[indexPath.row]] animated:YES];
}
@end

@interface NKAppDetailController ()
@property(nonatomic,strong) NSDictionary *app;
@property(nonatomic,strong) NSArray<NSDictionary *> *containers;
@property(nonatomic,assign) BOOL enabled;
@end

@implementation NKAppDetailController
- (instancetype)initWithApp:(NSDictionary *)app { if ((self=[super initWithStyle:UITableViewStyleInsetGrouped])) self.app=app; return self; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title=self.app[@"name"] ?: @"App";
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(createContainer)];
    [self reloadModel];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadModel]; }
- (void)reloadModel {
    NSString *bid=self.app[@"bundle"] ?: @"";
    NSDictionary *st=NKRun(@[@"status",bid,@"--json"]); NSDictionary *j=NKJSON(st[@"output"]); self.enabled=[j[@"enabled"] boolValue];
    NSDictionary *ls=NKRun(@[@"list",bid]); self.containers=NKContainers(ls[@"output"]); [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section==0?1:self.containers.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return section==0?@"NKCrane":@"Containers"; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section==0) {
        UITableViewCell *c=[tableView dequeueReusableCellWithIdentifier:@"toggle"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"toggle"];
        c.textLabel.text=@"Bật NKCrane cho ứng dụng";
        UISwitch *sw=[[UISwitch alloc] init]; sw.on=self.enabled; [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged]; c.accessoryView=sw; return c;
    }
    UITableViewCell *c=[tableView dequeueReusableCellWithIdentifier:@"container"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"container"];
    NSDictionary *x=self.containers[ip.row]; c.textLabel.text=x[@"name"]; c.detailTextLabel.text=x[@"id"]; c.accessoryType=[x[@"active"] boolValue]?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone; return c;
}
- (void)toggle:(UISwitch *)sw {
    NSString *bid=self.app[@"bundle"]; NSDictionary *r=NKRun(@[sw.isOn?@"enable":@"disable",bid]);
    if ([r[@"status"] integerValue]!=0) { sw.on=!sw.on; NKAlert(self,@"NKCrane",r[@"output"] ?: @"Không thể thay đổi trạng thái"); }
    self.enabled=sw.on;
}
- (void)createContainer {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Container mới" message:@"Đặt tên cho container" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f){ f.placeholder=@"Ví dụ: Tài khoản 2"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Tạo" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ NSString *name=[a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; if(!name.length)return; NSDictionary *r=NKRun(@[@"create",self.app[@"bundle"],name,@"--quiet"]); if([r[@"status"] integerValue]!=0) NKAlert(self,@"NKCrane",r[@"output"] ?: @"Tạo thất bại"); [self reloadModel]; }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES]; if(ip.section!=1)return;
    NSDictionary *x=self.containers[ip.row]; NSString *bid=self.app[@"bundle"]; NSString *cid=x[@"id"]; BOOL isDefault=[cid isEqualToString:@"default"];
    UIAlertController *a=[UIAlertController alertControllerWithTitle:x[@"name"] message:cid preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"Chuyển sang container này" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ NSDictionary *r=NKRun(@[@"switch",bid,cid,@"--quiet"]); if([r[@"status"] integerValue]!=0) NKAlert(self,@"NKCrane",r[@"output"] ?: @"Switch thất bại"); [self reloadModel]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Backup ngầm" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ NSDictionary *r=NKRun(@[@"backup",bid,cid,@"--safe",@"--background",@"--json"]); NSDictionary *j=NKJSON(r[@"output"]); NSString *m=[j[@"job_id"] length]?[NSString stringWithFormat:@"Đã tạo job %@",j[@"job_id"]]:r[@"output"]; NKAlert(self,@"Backup",m ?: @"Đã gửi job backup"); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Clone" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ [self promptClone:cid]; }]];
    if (!isDefault) {
        [a addAction:[UIAlertAction actionWithTitle:@"Đổi tên" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ [self promptRename:cid]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Xóa container" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *act){ NSDictionary *r=NKRun(@[@"delete",bid,cid,@"--quiet"]); if([r[@"status"] integerValue]!=0) NKAlert(self,@"NKCrane",r[@"output"] ?: @"Xóa thất bại"); [self reloadModel]; }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView=self.view; a.popoverPresentationController.sourceRect=[self.view convertRect:[tableView rectForRowAtIndexPath:ip] fromView:tableView];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)promptClone:(NSString *)cid {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Clone container" message:@"Tên container mới" preferredStyle:UIAlertControllerStyleAlert]; [a addTextFieldWithConfigurationHandler:nil];
    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Clone" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ NSString *n=[a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; if(!n.length)return; NSDictionary *r=NKRun(@[@"clone",self.app[@"bundle"],cid,n,@"--quiet"]); if([r[@"status"] integerValue]!=0) NKAlert(self,@"NKCrane",r[@"output"] ?: @"Clone thất bại"); [self reloadModel]; }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)promptRename:(NSString *)cid {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Đổi tên" message:nil preferredStyle:UIAlertControllerStyleAlert]; [a addTextFieldWithConfigurationHandler:nil];
    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){ NSString *n=[a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; if(!n.length)return; NSDictionary *r=NKRun(@[@"rename",self.app[@"bundle"],cid,n,@"--quiet"]); if([r[@"status"] integerValue]!=0) NKAlert(self,@"NKCrane",r[@"output"] ?: @"Đổi tên thất bại"); [self reloadModel]; }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

@interface NKAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation NKAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:[[NKAppListController alloc] initWithStyle:UITableViewStyleInsetGrouped]];
    self.window.rootViewController=nav; [self.window makeKeyAndVisible]; return YES;
}
@end

int main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(NKAppDelegate.class)); } }
