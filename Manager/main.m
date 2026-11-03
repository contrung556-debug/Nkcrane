#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static NSDictionary *NKRun(NSArray<NSString *> *args) {
    NSString *tool=@"/var/jb/usr/local/bin/nkcranectl";
    if(![[NSFileManager defaultManager] isExecutableFileAtPath:tool]) tool=@"/usr/local/bin/nkcranectl";
    int fds[2]; if(pipe(fds)!=0) return @{@"status":@(-1),@"output":@"pipe failed"};
    NSMutableArray<NSString *> *all=[NSMutableArray arrayWithObject:tool]; [all addObjectsFromArray:args?:@[]];
    char **argv=calloc(all.count+1,sizeof(char*));
    for(NSUInteger i=0;i<all.count;i++){ NSString *s=all[i]; argv[i]=strdup(s.UTF8String?:""); }
    posix_spawn_file_actions_t a; posix_spawn_file_actions_init(&a);
    posix_spawn_file_actions_addclose(&a,fds[0]); posix_spawn_file_actions_adddup2(&a,fds[1],STDOUT_FILENO); posix_spawn_file_actions_adddup2(&a,fds[1],STDERR_FILENO); posix_spawn_file_actions_addclose(&a,fds[1]);
    pid_t pid=0; int rc=posix_spawn(&pid,tool.fileSystemRepresentation,&a,NULL,argv,environ); posix_spawn_file_actions_destroy(&a); close(fds[1]);
    NSMutableData *data=[NSMutableData data]; if(rc==0){ uint8_t b[4096]; ssize_t n; while((n=read(fds[0],b,sizeof(b)))>0)[data appendBytes:b length:(NSUInteger)n]; } close(fds[0]);
    for(NSUInteger i=0;i<all.count;i++) free(argv[i]); free(argv);
    int status=rc; if(rc==0){ int ws=0; waitpid(pid,&ws,0); status=WIFEXITED(ws)?WEXITSTATUS(ws):-1; }
    NSString *out=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]?:@"";
    return @{@"status":@(status),@"output":[out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]};
}

static NSDictionary *NKJSON(NSString *s){ NSData *d=[s dataUsingEncoding:NSUTF8StringEncoding]; if(!d.length)return nil; id o=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]; return [o isKindOfClass:NSDictionary.class]?o:nil; }

static NSArray<NSDictionary *> *NKContainers(NSString *text){ NSMutableArray *r=[NSMutableArray array]; for(NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]){ if(![line hasPrefix:@"* "])continue; NSRange a=[line rangeOfString:@"[" options:NSBackwardsSearch],b=[line rangeOfString:@"]" options:NSBackwardsSearch]; if(a.location==NSNotFound||b.location==NSNotFound||b.location<=a.location)continue; NSString *name=[[line substringWithRange:NSMakeRange(2,a.location-3)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; NSString *cid=[line substringWithRange:NSMakeRange(a.location+1,b.location-a.location-1)]; [r addObject:@{@"name":name.length?name:cid,@"id":cid,@"active":@([line containsString:@"<active>"])}]; } return r; }

static id NKMsg(id o,NSString *n){ SEL s=NSSelectorFromString(n); if(!o||![o respondsToSelector:s])return nil; return ((id(*)(id,SEL))objc_msgSend)(o,s); }
static BOOL NKBMsg(id o,NSString *n){ SEL s=NSSelectorFromString(n); if(!o||![o respondsToSelector:s])return NO; return ((BOOL(*)(id,SEL))objc_msgSend)(o,s); }

static NSArray<NSDictionary *> *NKApps(void){
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices",RTLD_LAZY);
    Class c=NSClassFromString(@"LSApplicationWorkspace"); SEL ds=NSSelectorFromString(@"defaultWorkspace"),as=NSSelectorFromString(@"allInstalledApplications"); if(!c||![c respondsToSelector:ds])return @[];
    id ws=((id(*)(id,SEL))objc_msgSend)(c,ds); if(!ws||![ws respondsToSelector:as])return @[]; NSArray *p=((id(*)(id,SEL))objc_msgSend)(ws,as); if(![p isKindOfClass:NSArray.class])return @[];
    NSMutableArray *r=[NSMutableArray array]; for(id x in p){ if(NKBMsg(x,@"isPlaceholder"))continue; NSString *type=NKMsg(x,@"applicationType"); if([type isKindOfClass:NSString.class]&&![type isEqualToString:@"User"])continue; NSString *bid=NKMsg(x,@"applicationIdentifier"); if(![bid isKindOfClass:NSString.class]||!bid.length)bid=NKMsg(x,@"bundleIdentifier"); if(![bid isKindOfClass:NSString.class]||!bid.length||[bid hasPrefix:@"com.apple."]||[bid isEqualToString:@"com.nktouch.nkcrane.manager"])continue; NSString *name=NKMsg(x,@"localizedName"); if(![name isKindOfClass:NSString.class]||!name.length)name=bid; [r addObject:@{@"name":name,@"bundle":bid}]; }
    [r sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){ return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]]; }]; return r;
}

static void NKAlert(UIViewController *vc,NSString *title,NSString *message){ UIAlertController *a=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [vc presentViewController:a animated:YES completion:nil]; }

@interface NKDetail : UITableViewController
@property(nonatomic,strong) NSDictionary *app; @property(nonatomic,strong) NSArray *containers; @property(nonatomic,assign) BOOL enabled;
- (instancetype)initWithApp:(NSDictionary *)app;
@end

@interface NKAppsVC : UITableViewController <UISearchResultsUpdating>
@property(nonatomic,strong) NSArray *apps; @property(nonatomic,strong) NSArray *filtered;
@end

@implementation NKAppsVC
- (void)viewDidLoad{ [super viewDidLoad]; self.title=@"NKCrane"; self.navigationItem.prompt=@"Container Manager · v0.8.2"; UISearchController *s=[[UISearchController alloc] initWithSearchResultsController:nil]; s.searchResultsUpdater=self; s.obscuresBackgroundDuringPresentation=NO; s.searchBar.placeholder=@"Tìm ứng dụng"; self.navigationItem.searchController=s; self.navigationItem.hidesSearchBarWhenScrolling=NO; self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadApps)]; [self reloadApps]; }
- (void)reloadApps{ self.apps=NKApps(); self.filtered=self.apps; [self.tableView reloadData]; }
- (void)updateSearchResultsForSearchController:(UISearchController *)sc{ NSString *q=sc.searchBar.text.lowercaseString; if(!q.length)self.filtered=self.apps; else self.filtered=[self.apps filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *x,NSDictionary *b){ return [[x[@"name"] lowercaseString] containsString:q]||[[x[@"bundle"] lowercaseString] containsString:q]; }]]; [self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s{ return self.filtered.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)i{ UITableViewCell *c=[t dequeueReusableCellWithIdentifier:@"a"]?:[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"a"]; NSDictionary *x=self.filtered[i.row]; c.textLabel.text=x[@"name"]; c.detailTextLabel.text=x[@"bundle"]; c.accessoryType=UITableViewCellAccessoryDisclosureIndicator; return c; }
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)i{ [t deselectRowAtIndexPath:i animated:YES]; [self.navigationController pushViewController:[[NKDetail alloc] initWithApp:self.filtered[i.row]] animated:YES]; }
@end

@implementation NKDetail
- (instancetype)initWithApp:(NSDictionary *)app{ if((self=[super initWithStyle:UITableViewStyleInsetGrouped]))self.app=app; return self; }
- (void)viewDidLoad{ [super viewDidLoad]; self.title=self.app[@"name"]; self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(createContainer)]; [self reloadModel]; }
- (void)viewWillAppear:(BOOL)a{ [super viewWillAppear:a]; [self reloadModel]; }
- (void)reloadModel{ NSString *bid=self.app[@"bundle"]?:@""; NSDictionary *j=NKJSON(NKRun(@[@"status",bid,@"--json"])[@"output"]); self.enabled=[j[@"enabled"] boolValue]; self.containers=NKContainers(NKRun(@[@"list",bid])[@"output"]); [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t{ return 2; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s{ return s==0?1:self.containers.count; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s{ return s==0?@"NKCrane":@"Containers"; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)i{ if(i.section==0){ UITableViewCell *c=[t dequeueReusableCellWithIdentifier:@"s"]?:[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"s"]; c.textLabel.text=@"Bật NKCrane"; UISwitch *sw=[UISwitch new]; sw.on=self.enabled; [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged]; c.accessoryView=sw; return c; } UITableViewCell *c=[t dequeueReusableCellWithIdentifier:@"c"]?:[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"]; NSDictionary *x=self.containers[i.row]; c.textLabel.text=x[@"name"]; c.detailTextLabel.text=x[@"id"]; c.accessoryType=[x[@"active"] boolValue]?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone; return c; }
- (void)toggle:(UISwitch *)sw{ NSDictionary *r=NKRun(@[sw.on?@"enable":@"disable",self.app[@"bundle"]]); if([r[@"status"] integerValue]!=0){ sw.on=!sw.on; NKAlert(self,@"NKCrane",r[@"output"]); } self.enabled=sw.on; }
- (void)createContainer{ UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Container mới" message:@"Nhập tên" preferredStyle:UIAlertControllerStyleAlert]; [a addTextFieldWithConfigurationHandler:nil]; [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]]; [a addAction:[UIAlertAction actionWithTitle:@"Tạo" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *z){ NSString *n=[a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; if(!n.length)return; NSDictionary *r=NKRun(@[@"create",self.app[@"bundle"],n,@"--quiet"]); if([r[@"status"] integerValue]!=0)NKAlert(self,@"NKCrane",r[@"output"]); [self reloadModel]; }]]; [self presentViewController:a animated:YES completion:nil]; }
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)i{ [t deselectRowAtIndexPath:i animated:YES]; if(i.section!=1)return; NSDictionary *x=self.containers[i.row]; NSString *bid=self.app[@"bundle"],*cid=x[@"id"]; UIAlertController *a=[UIAlertController alertControllerWithTitle:x[@"name"] message:cid preferredStyle:UIAlertControllerStyleActionSheet]; [a addAction:[UIAlertAction actionWithTitle:@"Chuyển sang container này" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *z){ NSDictionary *r=NKRun(@[@"switch",bid,cid,@"--quiet"]); if([r[@"status"] integerValue]!=0)NKAlert(self,@"NKCrane",r[@"output"]); [self reloadModel]; }]]; [a addAction:[UIAlertAction actionWithTitle:@"Backup ngầm" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *z){ NSDictionary *r=NKRun(@[@"backup",bid,cid,@"--safe",@"--background",@"--json"]); NSDictionary *j=NKJSON(r[@"output"]); NSString *m=j[@"job_id"]?[NSString stringWithFormat:@"Job: %@",j[@"job_id"]]:(r[@"output"]?:@"Đã gửi backup"); NKAlert(self,@"Backup",m); }]]; [a addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }
@end

@interface NKDelegate : UIResponder <UIApplicationDelegate> @property(nonatomic,strong) UIWindow *window; @end
@implementation NKDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts{ self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]; self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:[[NKAppsVC alloc] initWithStyle:UITableViewStyleInsetGrouped]]; [self.window makeKeyAndVisible]; return YES; }
@end

int main(int argc,char *argv[]){ @autoreleasepool{ return UIApplicationMain(argc,argv,nil,NSStringFromClass(NKDelegate.class)); } }
