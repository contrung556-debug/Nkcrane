#import <Foundation/Foundation.h>
#import "../NKCraneCore/NKCStore.h"
#import "../NKCraneCore/NKCContainer.h"
#import "../NKCraneCore/NKCAppControl.h"
#import "../NKCraneCore/NKCBackupManager.h"
#import <unistd.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <stdlib.h>
#import <string.h>
#import <errno.h>

static NSString * const NKCJobsRoot = @"/var/mobile/Library/NKCrane/Jobs";

static void usage(void) {
    puts("NKCrane CLI v0.5.0\n"
         "Usage:\n"
         "  nkcranectl enable <bundle-id>\n"
         "  nkcranectl disable <bundle-id>\n"
         "  nkcranectl list <bundle-id>\n"
         "  nkcranectl active <bundle-id>\n"
         "  nkcranectl status <bundle-id> [--json]\n"
         "  nkcranectl create <bundle-id> <name> [--json|--quiet]\n"
         "  nkcranectl rename <bundle-id> <container-id|name> <new-name> [--json|--quiet]\n"
         "  nkcranectl switch <bundle-id> <container-id|name|default> [--no-relaunch] [--quiet]\n"
         "  nkcranectl restart <bundle-id> [--no-relaunch] [--quiet]\n"
         "  nkcranectl wipe <bundle-id> <container-id|name> [--json|--quiet]\n"
         "  nkcranectl delete <bundle-id> <container-id|name> [--json|--quiet]\n"
         "  nkcranectl path <bundle-id> <container-id|name|default>\n"
         "  nkcranectl clone <bundle-id> <container-id|name|default> <new-name> [--json|--quiet]\n"
         "  nkcranectl backup <bundle-id> <container-id|name|default> [destination.nkcb] [--safe] [--background] [--json|--quiet] [--no-relaunch]\n"
         "  nkcranectl restore <bundle-id> <container-id|name> <backup.nkcb> [--background] [--json|--quiet] [--no-relaunch]\n"
         "  nkcranectl backups <bundle-id>\n"
         "  nkcranectl job <job-id>\n"
         "  nkcranectl jobs\n"
         "  nkcranectl link <owner-bundle-id> <child-bundle-id>\n"
         "  nkcranectl unlink <child-bundle-id>\n"
         "  nkcranectl family <owner-bundle-id>\n"
         "  nkcranectl resolve <bundle-id>\n");
}

static BOOL hasFlag(int argc, const char **argv, NSString *flag) {
    for (int i = 1; i < argc; i++) {
        NSString *v = [NSString stringWithUTF8String:argv[i]];
        if ([v isEqualToString:flag]) return YES;
    }
    return NO;
}

static NSString *flagValue(int argc, const char **argv, NSString *prefix) {
    for (int i = 1; i < argc; i++) {
        NSString *v = [NSString stringWithUTF8String:argv[i]];
        if ([v hasPrefix:prefix]) return [v substringFromIndex:prefix.length];
    }
    return nil;
}

static NSArray<NSString *> *positionals(int argc, const char **argv) {
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (int i = 1; i < argc; i++) {
        NSString *v = [NSString stringWithUTF8String:argv[i]];
        if (![v hasPrefix:@"--"]) [items addObject:v];
    }
    return items;
}

static void printJSON(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object ?: @{} options:0 error:nil];
    if (data) {
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
    }
}

static void emitResult(NSDictionary *object, NSString *human, BOOL json, BOOL quiet) {
    if (quiet) return;
    if (json) printJSON(object);
    else if (human.length) printf("%s\n", human.UTF8String);
}

static BOOL ensureDirectory(NSString *path) {
    return [NSFileManager.defaultManager createDirectoryAtPath:path
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions:@0755}
                                                        error:nil];
}

static NSString *jobPath(NSString *jobID) {
    return [NKCJobsRoot stringByAppendingPathComponent:[jobID stringByAppendingPathExtension:@"json"]];
}

static BOOL writeJob(NSString *jobID, NSDictionary *job) {
    if (!ensureDirectory(NKCJobsRoot)) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:job options:NSJSONWritingPrettyPrinted error:nil];
    return data && [data writeToFile:jobPath(jobID) options:NSDataWritingAtomic error:nil];
}

static NSDictionary *readJob(NSString *jobID) {
    NSData *data = [NSData dataWithContentsOfFile:jobPath(jobID)];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

static NSMutableDictionary *baseJob(NSString *jobID, NSString *operation, NSString *owner, NSString *container) {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    return [@{
        @"job_id": jobID,
        @"operation": operation,
        @"state": @"queued",
        @"owner_bundle_id": owner ?: @"",
        @"container": container ?: @"",
        @"submitted_at": @(now),
        @"updated_at": @(now)
    } mutableCopy];
}

static void updateJob(NSString *jobID, void (^mutator)(NSMutableDictionary *job)) {
    NSMutableDictionary *job = [readJob(jobID) mutableCopy];
    if (!job) job = [NSMutableDictionary dictionary];
    mutator(job);
    job[@"updated_at"] = @(NSDate.date.timeIntervalSince1970);
    writeJob(jobID, job);
}

static void redirectBackgroundIO(void) {
    int fd = open("/dev/null", O_RDWR);
    if (fd >= 0) {
        dup2(fd, STDIN_FILENO);
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        if (fd > STDERR_FILENO) close(fd);
    }
}

static pid_t spawnWorker(int argc, const char **argv, NSString *jobID, NSError **error) {
    char **childArgs = calloc((size_t)argc + 2, sizeof(char *));
    if (!childArgs) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
        return -1;
    }

    int out = 0;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--background") == 0) continue;
        childArgs[out++] = strdup(argv[i]);
    }
    NSString *worker = [NSString stringWithFormat:@"--worker-job=%@", jobID];
    childArgs[out++] = strdup(worker.UTF8String);
    childArgs[out] = NULL;

    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        redirectBackgroundIO();
        execvp(childArgs[0], childArgs);
        _exit(127);
    }

    for (int i = 0; i < out; i++) free(childArgs[i]);
    free(childArgs);

    if (pid < 0 && error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    return pid;
}

static void terminateFamilySilently(NKCStore *store, NSString *owner) {
    for (NSString *child in [store linkedBundleIdentifiersForOwnerBundleIdentifier:owner]) [NKCAppControl terminateBundleIdentifier:child error:nil];
    [NKCAppControl terminateBundleIdentifier:owner error:nil];
}

static void relaunchOwnerSilently(NSString *owner) {
    [NKCAppControl launchBundleIdentifier:owner error:nil];
}

static int restartFamily(NKCStore *store, NSString *bundle, BOOL relaunch, BOOL quiet) {
    NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundle];
    for (NSString *child in [store linkedBundleIdentifiersForOwnerBundleIdentifier:owner]) [NKCAppControl terminateBundleIdentifier:child error:nil];

    NSError *error = nil;
    if (![NKCAppControl restartBundleIdentifier:owner relaunch:relaunch error:&error]) {
        if (!quiet) fprintf(stderr, "restart failed: %s\n", error.localizedDescription.UTF8String);
        return 5;
    }
    if (!quiet) printf(relaunch ? "restarted family %s\n" : "terminated family %s\n", owner.UTF8String);
    return 0;
}

static NSString *submitBackgroundJob(int argc, const char **argv, NSString *operation, NSString *owner, NKCContainer *container, NSDictionary *extra, NSError **error) {
    NSString *jobID = NSUUID.UUID.UUIDString.lowercaseString;
    NSMutableDictionary *job = baseJob(jobID, operation, owner, container.identifier);
    [job addEntriesFromDictionary:extra ?: @{}];
    if (!writeJob(jobID, job)) {
        if (error) *error = [NSError errorWithDomain:@"NKCrane.Job" code:500 userInfo:@{NSLocalizedDescriptionKey:@"Could not create background job file"}];
        return nil;
    }

    pid_t pid = spawnWorker(argc, argv, jobID, error);
    if (pid < 0) {
        NSString *message = (error && *error) ? (*error).localizedDescription : @"Could not start worker";
        updateJob(jobID, ^(NSMutableDictionary *j) {
            j[@"state"] = @"failed";
            j[@"ok"] = @NO;
            j[@"error"] = message;
        });
        return nil;
    }

    updateJob(jobID, ^(NSMutableDictionary *j) {
        j[@"state"] = @"running";
        j[@"pid"] = @(pid);
    });
    return jobID;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *args = positionals(argc, argv);
        if (args.count < 1) { usage(); return 1; }

        NSString *cmd = args[0];
        BOOL json = hasFlag(argc, argv, @"--json");
        BOOL quiet = hasFlag(argc, argv, @"--quiet");
        BOOL background = hasFlag(argc, argv, @"--background");
        BOOL relaunch = !hasFlag(argc, argv, @"--no-relaunch");
        NSString *workerJobID = flagValue(argc, argv, @"--worker-job=");
        NKCStore *store = NKCStore.sharedStore;

        if (workerJobID.length) {
            updateJob(workerJobID, ^(NSMutableDictionary *j) {
                j[@"state"] = @"running";
                j[@"worker_pid"] = @(getpid());
            });
            quiet = YES;
        }

        if ([cmd isEqualToString:@"job"]) {
            if (args.count < 2) { usage(); return 1; }
            NSDictionary *job = readJob(args[1]);
            if (!job) { fprintf(stderr, "job not found\n"); return 2; }
            printJSON(job);
            return 0;
        }

        if ([cmd isEqualToString:@"jobs"]) {
            ensureDirectory(NKCJobsRoot);
            NSArray *files = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:NKCJobsRoot error:nil] sortedArrayUsingSelector:@selector(compare:)];
            NSMutableArray *jobs = [NSMutableArray array];
            for (NSString *file in files) {
                if (![file.pathExtension isEqualToString:@"json"]) continue;
                NSDictionary *job = readJob(file.stringByDeletingPathExtension);
                if (job) [jobs addObject:job];
            }
            printJSON(jobs);
            return 0;
        }

        if ([cmd isEqualToString:@"link"]) {
            if (args.count < 3) { usage(); return 1; }
            NSError *error = nil;
            if (![store linkBundleIdentifier:args[2] toOwnerBundleIdentifier:args[1] error:&error]) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 3; }
            printf("linked %s -> %s\n", args[2].UTF8String, args[1].UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"unlink"]) {
            if (args.count < 2) { usage(); return 1; }
            NSError *error = nil;
            if (![store unlinkBundleIdentifier:args[1] error:&error]) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 3; }
            printf("unlinked %s\n", args[1].UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"resolve"]) {
            if (args.count < 2) { usage(); return 1; }
            printf("%s\n", [store ownerBundleIdentifierForProcessBundleIdentifier:args[1]].UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"family"]) {
            if (args.count < 2) { usage(); return 1; }
            NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:args[1]];
            printf("owner: %s\n", owner.UTF8String);
            for (NSString *child in [store linkedBundleIdentifiersForOwnerBundleIdentifier:owner]) printf("child: %s\n", child.UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"enable"] || [cmd isEqualToString:@"disable"]) {
            if (args.count < 2) { usage(); return 1; }
            NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:args[1]];
            [store setEnabled:[cmd isEqualToString:@"enable"] forBundleIdentifier:owner];
            printf("%s %s\n", cmd.UTF8String, owner.UTF8String);
            return 0;
        }

        if (args.count < 2) { usage(); return 1; }
        NSString *bundle = args[1];
        NSString *owner = [store ownerBundleIdentifierForProcessBundleIdentifier:bundle];

        if ([cmd isEqualToString:@"backups"]) {
            NSString *directory = [NKCBackupManager defaultBackupDirectoryForBundleIdentifier:owner];
            NSArray *items = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil] sortedArrayUsingSelector:@selector(compare:)];
            for (NSString *item in items) if ([item.pathExtension isEqualToString:@"nkcb"]) printf("%s\n", [directory stringByAppendingPathComponent:item].UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"list"]) {
            NSString *active = [store activeContainerIdentifierForBundleIdentifier:owner];
            printf("* Default [default]%s\n", [active isEqualToString:@"default"] ? "  <active>" : "");
            for (NKCContainer *c in [store containersForBundleIdentifier:owner]) printf("* %s [%s]%s\n", c.name.UTF8String, c.identifier.UTF8String, [active isEqualToString:c.identifier] ? "  <active>" : "");
            return 0;
        }

        if ([cmd isEqualToString:@"active"]) {
            printf("%s\n", [store activeContainerIdentifierForBundleIdentifier:owner].UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"status"]) {
            NSString *active = [store activeContainerIdentifierForBundleIdentifier:owner];
            NSString *path = [store rootPathForContainerIdentifier:active bundleIdentifier:owner create:NO];
            NSDictionary *result = @{@"process":bundle,@"owner":owner,@"enabled":@([store isEnabledForBundleIdentifier:owner]),@"active":active,@"path":path ?: [NSNull null]};
            if (json) printJSON(result);
            else printf("process: %s\nowner: %s\nenabled: %s\nactive: %s\npath: %s\n", bundle.UTF8String, owner.UTF8String, [store isEnabledForBundleIdentifier:owner] ? "yes" : "no", active.UTF8String, (path ?: @"unavailable").UTF8String);
            return 0;
        }

        if ([cmd isEqualToString:@"create"]) {
            if (args.count < 3) { usage(); return 1; }
            NKCContainer *c = [store createContainerNamed:args[2] bundleIdentifier:owner];
            if (!c) { fprintf(stderr, "create failed\n"); return 2; }
            emitResult(@{@"ok":@YES,@"container_id":c.identifier,@"name":c.name}, [NSString stringWithFormat:@"created %@ [%@]", c.name, c.identifier], json, quiet);
            return 0;
        }

        if ([cmd isEqualToString:@"restart"]) return restartFamily(store, owner, relaunch, quiet);

        if (args.count < 3) { usage(); return 1; }
        NSString *value = args[2];
        NKCContainer *c = [store containerForIdentifierOrName:value bundleIdentifier:owner];
        if (!c) { fprintf(stderr, "container not found: %s\n", value.UTF8String); return 2; }
        NSError *error = nil;

        if ([cmd isEqualToString:@"backup"]) {
            NSString *destination = args.count >= 4 ? args[3] : nil;
            BOOL safe = hasFlag(argc, argv, @"--safe");

            if (background && !workerJobID.length) {
                NSMutableDictionary *extra = [NSMutableDictionary dictionaryWithObject:@(safe) forKey:@"safe"];
                if (destination.length) extra[@"destination"] = destination;
                NSString *jobID = submitBackgroundJob(argc, argv, @"backup", owner, c, extra, &error);
                if (!jobID) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 6; }
                emitResult(@{@"ok":@YES,@"job_id":jobID,@"state":@"running"}, [NSString stringWithFormat:@"backup job %@ running", jobID], json, quiet);
                return 0;
            }

            if (safe) terminateFamilySilently(store, owner);
            NSString *path = [NKCBackupManager backupContainerIdentifier:c.identifier bundleIdentifier:owner destination:destination error:&error];
            if (safe && relaunch) relaunchOwnerSilently(owner);

            if (workerJobID.length) {
                updateJob(workerJobID, ^(NSMutableDictionary *j) {
                    j[@"ok"] = @(path != nil);
                    j[@"state"] = path ? @"completed" : @"failed";
                    if (path) j[@"result_path"] = path;
                    else j[@"error"] = error.localizedDescription ?: @"Backup failed";
                });
            }
            if (!path) { if (!quiet) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 6; }
            emitResult(@{@"ok":@YES,@"path":path,@"container_id":c.identifier}, path, json, quiet);
            return 0;
        }

        if ([cmd isEqualToString:@"restore"]) {
            if (args.count < 4) { usage(); return 1; }
            NSString *backupPath = args[3];

            if (background && !workerJobID.length) {
                NSString *jobID = submitBackgroundJob(argc, argv, @"restore", owner, c, @{@"backup_path":backupPath}, &error);
                if (!jobID) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 7; }
                emitResult(@{@"ok":@YES,@"job_id":jobID,@"state":@"running"}, [NSString stringWithFormat:@"restore job %@ running", jobID], json, quiet);
                return 0;
            }

            terminateFamilySilently(store, owner);
            BOOL ok = [NKCBackupManager restoreBackupAtPath:backupPath toContainerIdentifier:c.identifier bundleIdentifier:owner error:&error];
            if (relaunch) relaunchOwnerSilently(owner);

            if (workerJobID.length) {
                updateJob(workerJobID, ^(NSMutableDictionary *j) {
                    j[@"ok"] = @(ok);
                    j[@"state"] = ok ? @"completed" : @"failed";
                    if (!ok) j[@"error"] = error.localizedDescription ?: @"Restore failed";
                });
            }
            if (!ok) { if (!quiet) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 7; }
            emitResult(@{@"ok":@YES,@"container_id":c.identifier,@"backup_path":backupPath}, @"restore complete", json, quiet);
            return 0;
        }

        if ([cmd isEqualToString:@"clone"]) {
            if (args.count < 4) { usage(); return 1; }
            NKCContainer *created = [NKCBackupManager cloneContainerIdentifier:c.identifier bundleIdentifier:owner newName:args[3] error:&error];
            if (!created) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 8; }
            emitResult(@{@"ok":@YES,@"container_id":created.identifier,@"name":created.name}, [NSString stringWithFormat:@"cloned -> %@ [%@]", created.name, created.identifier], json, quiet);
            return 0;
        }

        if ([cmd isEqualToString:@"switch"]) {
            if (![store setActiveContainerIdentifier:c.identifier bundleIdentifier:owner error:&error]) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 3; }
            if (!quiet) printf("active -> %s [%s]\n", c.name.UTF8String, c.identifier.UTF8String);
            return restartFamily(store, owner, relaunch, quiet);
        }

        if ([cmd isEqualToString:@"rename"]) {
            if (args.count < 4) { usage(); return 1; }
            if (![store renameContainer:c.identifier toName:args[3] bundleIdentifier:owner error:&error]) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 3; }
            emitResult(@{@"ok":@YES,@"container_id":c.identifier,@"name":args[3]}, [NSString stringWithFormat:@"renamed [%@] -> %@", c.identifier, args[3]], json, quiet);
            return 0;
        }

        if ([cmd isEqualToString:@"wipe"]) {
            if (![store wipeContainer:c.identifier bundleIdentifier:owner error:&error]) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 3; }
            emitResult(@{@"ok":@YES,@"container_id":c.identifier}, @"wiped", json, quiet);
            return 0;
        }

        if ([cmd isEqualToString:@"delete"]) {
            if (![store deleteContainer:c.identifier bundleIdentifier:owner error:&error]) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 3; }
            emitResult(@{@"ok":@YES,@"container_id":c.identifier}, @"deleted", json, quiet);
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
