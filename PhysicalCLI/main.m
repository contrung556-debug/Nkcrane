#import <Foundation/Foundation.h>
#import "../NKCraneCore/NKCStore.h"
#import "../NKCraneCore/NKCContainer.h"
#import "../NKCraneCore/NKCAppControl.h"
#import "../NKCraneCore/NKCPhysicalSwap.h"

static void PrintJSON(id obj) {
    NSData *d=[NSJSONSerialization dataWithJSONObject:obj?:@{} options:NSJSONWritingPrettyPrinted error:nil];
    if (d) fwrite(d.bytes,1,d.length,stdout);
    fputc('\n',stdout);
}

static void TerminateFamily(NKCStore *store, NSString *owner) {
    for (NSString *child in [store linkedBundleIdentifiersForOwnerBundleIdentifier:owner]) {
        [NKCAppControl terminateBundleIdentifier:child error:nil];
    }
    [NKCAppControl terminateBundleIdentifier:owner error:nil];
}

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr,"usage: nkcraneswitch <bundle-id> <container-id|name|default>\n");
            return 1;
        }
        NSString *bundle=[NSString stringWithUTF8String:argv[1]];
        NSString *value=[NSString stringWithUTF8String:argv[2]];
        NKCStore *store=NKCStore.sharedStore;
        NSString *owner=[store ownerBundleIdentifierForProcessBundleIdentifier:bundle];
        NKCContainer *target=[store containerForIdentifierOrName:value bundleIdentifier:owner];
        if (!target) {
            PrintJSON(@{@"ok":@NO,@"error":@"container not found",@"bundle":bundle?:@""});
            return 2;
        }

        NSString *beforeLogical=[store activeContainerIdentifierForBundleIdentifier:owner]?:NKCDefaultContainerIdentifier;
        NSString *beforePhysical=[NKCPhysicalSwap physicalActiveForBundleIdentifier:owner];

        TerminateFamily(store,owner);
        usleep(250000);

        NSError *error=nil;
        if (![NKCPhysicalSwap switchBundleIdentifier:owner toContainerIdentifier:target.identifier error:&error]) {
            PrintJSON(@{@"ok":@NO,@"stage":@"physical_swap",@"error":error.localizedDescription?:@"swap failed",@"logical_before":beforeLogical,@"physical_before":beforePhysical?:@"default"});
            [NKCAppControl launchBundleIdentifier:owner error:nil];
            return 3;
        }

        if (![store setActiveContainerIdentifier:target.identifier bundleIdentifier:owner error:&error]) {
            [NKCPhysicalSwap switchBundleIdentifier:owner toContainerIdentifier:beforePhysical error:nil];
            PrintJSON(@{@"ok":@NO,@"stage":@"logical_state",@"error":error.localizedDescription?:@"active state failed"});
            [NKCAppControl launchBundleIdentifier:owner error:nil];
            return 4;
        }

        NSError *launchError=nil;
        BOOL launched=[NKCAppControl launchBundleIdentifier:owner error:&launchError];
        NSDictionary *diag=[NKCPhysicalSwap diagnosticsForBundleIdentifier:owner];
        NSMutableDictionary *out=[diag mutableCopy];
        out[@"ok"]=@YES;
        out[@"target_name"]=target.name?:target.identifier;
        out[@"launched"]=@(launched);
        if (!launched && launchError) out[@"launch_warning"]=launchError.localizedDescription;
        PrintJSON(out);
        return 0;
    }
}
