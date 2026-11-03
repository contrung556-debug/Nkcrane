#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static void (*orig_viewDidLoad)(id,SEL)=NULL;

static NSString *RunProbe(NSString *bundle) {
    NSString *tool=@"/var/jb/usr/local/bin/nkcraneprobe";
    if(![[NSFileManager defaultManager] isExecutableFileAtPath:tool]) tool=@"/usr/local/bin/nkcraneprobe";
    int fds[2]; if(pipe(fds)!=0) return @"probe pipe failed";
    const char *argv[]={tool.fileSystemRepresentation,bundle.UTF8String,NULL};
    posix_spawn_file_actions_t a; posix_spawn_file_actions_init(&a);
    posix_spawn_file_actions_addclose(&a,fds[0]);
    posix_spawn_file_actions_adddup2(&a,fds[1],STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&a,fds[1],STDERR_FILENO);
    posix_spawn_file_actions_addclose(&a,fds[1]);
    pid_t pid=0; int rc=posix_spawn(&pid,tool.fileSystemRepresentation,&a,NULL,(char *const *)argv,environ);
    posix_spawn_file_actions_destroy(&a); close(fds[1]);
    NSMutableData *data=[NSMutableData data];
    if(rc==0){ uint8_t b[2048]; ssize_t n; while((n=read(fds[0],b,sizeof(b)))>0)[data appendBytes:b length:(NSUInteger)n]; }
    close(fds[0]);
    if(rc==0){ int ws=0; waitpid(pid,&ws,0); }
    NSString *out=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return out.length?out:[NSString stringWithFormat:@"probe failed (%d)",rc];
}

static void NKShowDiagnostics(id self, SEL _cmd) {
    NSDictionary *app=nil;
    @try { app=[self valueForKey:@"app"]; } @catch(__unused NSException *e) {}
    NSString *bundle=[app isKindOfClass:NSDictionary.class]?app[@"bundle"]:nil;
    NSString *output=bundle.length?RunProbe(bundle):@"bundle id unavailable";
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"NKCrane Diagnostics" message:output preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [(UIViewController *)self presentViewController:a animated:YES completion:nil];
}

static void NKDiagViewDidLoad(id self, SEL _cmd) {
    if(orig_viewDidLoad) orig_viewDidLoad(self,_cmd);
    UIBarButtonItem *item=[[UIBarButtonItem alloc] initWithTitle:@"Diag" style:UIBarButtonItemStylePlain target:self action:NSSelectorFromString(@"nkc_showDiagnostics")];
    [(UIViewController *)self navigationItem].leftBarButtonItem=item;
}

__attribute__((constructor))
static void NKInstallManagerDiagnostics(void) {
    Class cls=NSClassFromString(@"NKDetail");
    if(!cls) return;
    class_addMethod(cls,NSSelectorFromString(@"nkc_showDiagnostics"),(IMP)NKShowDiagnostics,"v@:");
    Method m=class_getInstanceMethod(cls,@selector(viewDidLoad));
    if(m){ orig_viewDidLoad=(void *)method_getImplementation(m); method_setImplementation(m,(IMP)NKDiagViewDidLoad); }
}
