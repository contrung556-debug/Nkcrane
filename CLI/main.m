#import <Foundation/Foundation.h>
#import "../NKCraneCore/NKCStore.h"
#import "../NKCraneCore/NKCContainer.h"
#import "../NKCraneCore/NKCAppControl.h"

static void usage(void) {
    puts("NKCrane CLI v0.4.0\n"
         "Usage:\n"
         "  nkcranectl enable <bundle-id>\n"
         "  nkcranectl disable <bundle-id>\n"
         "  nkcranectl list <bundle-id>\n"
         "  nkcranectl active <bundle-id>\n"
         "  nkcranectl status <bundle-id>\n"
         "  nkcranectl create <bundle-id> <name>\n"
         "  nkcranectl rename <bundle-id> <container-id|name> <new-name>\n"
         "  nkcranectl switch <bundle-id> <container-id|name|default> [--no-relaunch]\n"
         "  nkcranectl restart <bundle-id> [--no-relaunch]\n"
         "  nkcranectl wipe <bundle-id> <container-id|name>\n"
         "  nkcranectl delete <bundle-id> <container-id|name>\n"
         "  nkcranectl path <bundle-id> <container-id|name|default>\n"
         "  nkcranectl link <owner-bundle-id> <child-bundle-id>\n"
         "  nkcranectl unlink <child-bundle-id>\n"
         "  nkcranectl family <owner-bundle-id>\n"
         "  nkcranectl resolve <bundle-id>\n");
}

static NSString *arg(int argc, const char **argv, int i) {
    if (i >= argc) return nil;
    return [NSString stringWithUTF8String:argv[i]];
}

static BOOL hasFlag(int argc, const char **argv, NSString *flag) {
    for (int i = 1; i < argc; i++) {
        NSString *v = [NSString stringWithUTF8String:argv[i]];
        if ([v isEqualToString:flag]) return YES;
    }
    return NO;
}

static int restartFamily(NKCStore *store, NSString *bundle, BOOL relaunch) {
    NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundle];
    for (NSString *child in [store linkedBundleIdentifiersForOwnerBundleIdentifier:owner]) {
        [NKCAppControl terminateBundleIdentifier:child error:nil];
    }

    NSError *error = nil;
    if (![NKCAppControl restartBundleIdentifier:owner relaunch:relaunch error:&error]) {
        fprintf(stderr, "restart failed: %s\n", error.localizedDescription.UTF8String);
        return 5;
    }
    printf(relaunch ? "restarted family %s\n" : "terminated family %s\n", owner.UTF8String);
    return 0;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc < 2) { usage(); return 1; }
        NSString *cmd = arg(argc, argv, 1);
        NKCStore *store = NKCStore.sharedStore;

        if ([cmd isEqualToString:@"link"]) {
            NSString *owner = arg(argc, argv, 2);
            NSString *child = arg(argc, argv, 3);
            if (!owner || !child) { usage(); return 1; }
            NSError *error = nil;
            if (![store linkBundleIdentifier:child toOwnerBundleIdentifier:owner error:&error]) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 3;
            }
            printf("linked %s -> %s\n", child.UTF8String, owner.UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"unlink"]) {
            NSString *child = arg(argc, argv, 2);
            if (!child) { usage(); return 1; }
            NSError *error = nil;
            if (![store unlinkBundleIdentifier:child error:&error]) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 3;
            }
            printf("unlinked %s\n", child.UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"resolve"]) {
            NSString *bundle = arg(argc, argv, 2);
            if (!bundle) { usage(); return 1; }
            printf("%s\n", [store ownerBundleIdentifierForProcessBundleIdentifier:bundle].UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"family"]) {
            NSString *bundle = arg(argc, argv, 2);
            if (!bundle) { usage(); return 1; }
            NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundle];
            printf("owner: %s\n", owner.UTF8String);
            for (NSString *child in [store linkedBundleIdentifiersForOwnerBundleIdentifier:owner]) {
                printf("child: %s\n", child.UTF8String);
            }
            return 0;
        }

        if ([cmd isEqualToString:@"enable"] || [cmd isEqualToString:@"disable"]) {
            NSString *bundle = arg(argc, argv, 2);
            if (!bundle) { usage(); return 1; }
            NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundle];
            [store setEnabled:[cmd isEqualToString:@"enable"] forBundleIdentifier:owner];
            printf("%s %s\n", cmd.UTF8String, owner.UTF8String);
            return 0;
        }

        NSString *bundle = arg(argc, argv, 2);
        if (!bundle) { usage(); return 1; }
        NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundle];

        if ([cmd isEqualToString:@"list"]) {
            NSString *active = [store activeContainerIdentifierForBundleIdentifier:owner];
            printf("* Default [default]%s\n", [active isEqualToString:@"default"] ? "  <active>" : "");
            for (NKCContainer *c in [store containersForBundleIdentifier:owner]) {
                printf("* %s [%s]%s\n", c.name.UTF8String, c.identifier.UTF8String,
                       [active isEqualToString:c.identifier] ? "  <active>" : "");
            }
            return 0;
        }

        if ([cmd isEqualToString:@"active"]) {
            printf("%s\n", [store activeContainerIdentifierForBundleIdentifier:owner].UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"status"]) {
            NSString *active = [store activeContainerIdentifierForBundleIdentifier:owner];
            NSString *path = [store rootPathForContainerIdentifier:active bundleIdentifier:owner create:NO];
            printf("process: %s\n", bundle.UTF8String);
            printf("owner: %s\n", owner.UTF8String);
            printf("enabled: %s\n", [store isEnabledForBundleIdentifier:owner] ? "yes" : "no");
            printf("active: %s\n", active.UTF8String);
            printf("path: %s\n", (path ?: @"unavailable").UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"create"]) {
            NSString *name = arg(argc, argv, 3);
            if (!name) { usage(); return 1; }
            NKCContainer *c = [store createContainerNamed:name bundleIdentifier:owner];
            if (!c) { fprintf(stderr, "create failed\n"); return 2; }
            printf("created %s [%s]\n", c.name.UTF8String, c.identifier.UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"restart"]) {
            return restartFamily(store, owner, !hasFlag(argc, argv, @"--no-relaunch"));
        }

        NSString *value = arg(argc, argv, 3);
        if (!value) { usage(); return 1; }
        NKCContainer *c = [store containerForIdentifierOrName:value bundleIdentifier:owner];
        if (!c) { fprintf(stderr, "container not found: %s\n", value.UTF8String); return 2; }

        NSError *error = nil;
        if ([cmd isEqualToString:@"switch"]) {
            if (![store setActiveContainerIdentifier:c.identifier bundleIdentifier:owner error:&error]) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 3;
            }
            printf("active -> %s [%s]\n", c.name.UTF8String, c.identifier.UTF8String);
            return restartFamily(store, owner, !hasFlag(argc, argv, @"--no-relaunch"));
        }

        if ([cmd isEqualToString:@"rename"]) {
            NSString *newName = arg(argc, argv, 4);
            if (!newName) { usage(); return 1; }
            if (![store renameContainer:c.identifier toName:newName bundleIdentifier:owner error:&error]) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 3;
            }
            printf("renamed [%s] -> %s\n", c.identifier.UTF8String, newName.UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"wipe"]) {
            if (![store wipeContainer:c.identifier bundleIdentifier:owner error:&error]) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 3;
            }
            printf("wiped %s [%s]\n", c.name.UTF8String, c.identifier.UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"delete"]) {
            if (![store deleteContainer:c.identifier bundleIdentifier:owner error:&error]) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 3;
            }
            printf("deleted %s [%s]\n", c.name.UTF8String, c.identifier.UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"path"]) {
            NSString *p = [store rootPathForContainerIdentifier:c.identifier bundleIdentifier:owner create:NO];
            if (!p) { fprintf(stderr, "path unavailable\n"); return 4; }
            printf("%s\n", p.UTF8String);
            return 0;
        }

        usage();
        return 1;
    }
}
