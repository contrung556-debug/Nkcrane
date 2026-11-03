#import "NKCFilesystemHooks.h"
#import <substrate.h>
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <dirent.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <limits.h>
#import <stdarg.h>

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif
#ifndef F_GETPATH
#define F_GETPATH 50
#endif

static char sRealHome[PATH_MAX] = {0};
static char sRealHomeAlt[PATH_MAX] = {0};
static char sMappedHome[PATH_MAX] = {0};
static char sExcludedPrefix[PATH_MAX] = {0};
static BOOL sInstalled = NO;

static int (*orig_open)(const char *, int, ...) = NULL;
static int (*orig_openat)(int, const char *, int, ...) = NULL;
static int (*orig_creat)(const char *, mode_t) = NULL;
static FILE *(*orig_fopen)(const char *, const char *) = NULL;
static FILE *(*orig_freopen)(const char *, const char *, FILE *) = NULL;
static int (*orig_stat)(const char *, struct stat *) = NULL;
static int (*orig_lstat)(const char *, struct stat *) = NULL;
static int (*orig_access)(const char *, int) = NULL;
static int (*orig_chmod)(const char *, mode_t) = NULL;
static int (*orig_chown)(const char *, uid_t, gid_t) = NULL;
static int (*orig_unlink)(const char *) = NULL;
static int (*orig_remove)(const char *) = NULL;
static int (*orig_mkdir)(const char *, mode_t) = NULL;
static int (*orig_rmdir)(const char *) = NULL;
static DIR *(*orig_opendir)(const char *) = NULL;
static int (*orig_rename)(const char *, const char *) = NULL;
static int (*orig_link)(const char *, const char *) = NULL;
static int (*orig_symlink)(const char *, const char *) = NULL;
static ssize_t (*orig_readlink)(const char *, char *, size_t) = NULL;
static int (*orig_truncate)(const char *, off_t) = NULL;
static int (*orig_chdir)(const char *) = NULL;

static BOOL NKCPrefixBoundary(const char *path, const char *prefix) {
    if (!path || !prefix || !prefix[0]) return NO;
    size_t n = strlen(prefix);
    if (strncmp(path, prefix, n) != 0) return NO;
    return path[n] == '\0' || path[n] == '/';
}

static BOOL NKCNormalizeAbsolute(const char *input, char *output, size_t cap) {
    if (!input || input[0] != '/' || !output || cap < 2) return NO;
    char work[PATH_MAX];
    if (strlen(input) >= sizeof(work)) return NO;
    strlcpy(work, input, sizeof(work));

    const char *parts[PATH_MAX / 2];
    size_t count = 0;
    char *save = NULL;
    for (char *tok = strtok_r(work, "/", &save); tok; tok = strtok_r(NULL, "/", &save)) {
        if (tok[0] == '\0' || strcmp(tok, ".") == 0) continue;
        if (strcmp(tok, "..") == 0) {
            if (count > 0) count--;
            continue;
        }
        if (count >= sizeof(parts) / sizeof(parts[0])) return NO;
        parts[count++] = tok;
    }

    size_t pos = 0;
    output[pos++] = '/';
    output[pos] = '\0';
    for (size_t i = 0; i < count; i++) {
        size_t len = strlen(parts[i]);
        if (pos + len + 2 > cap) return NO;
        if (pos > 1) output[pos++] = '/';
        memcpy(output + pos, parts[i], len);
        pos += len;
        output[pos] = '\0';
    }
    return YES;
}

static BOOL NKCMapAbsolutePath(const char *absolutePath, char *mapped, size_t cap) {
    if (!absolutePath || !mapped || !sRealHome[0] || !sMappedHome[0]) return NO;

    char normalized[PATH_MAX];
    if (!NKCNormalizeAbsolute(absolutePath, normalized, sizeof(normalized))) return NO;

    // Never redirect NKCrane's own backing store or an already-mapped path.
    if (NKCPrefixBoundary(normalized, sExcludedPrefix) || NKCPrefixBoundary(normalized, sMappedHome)) return NO;

    const char *base = NULL;
    if (NKCPrefixBoundary(normalized, sRealHome)) base = sRealHome;
    else if (sRealHomeAlt[0] && NKCPrefixBoundary(normalized, sRealHomeAlt)) base = sRealHomeAlt;
    if (!base) return NO;

    const char *relative = normalized + strlen(base);
    int written = snprintf(mapped, cap, "%s%s", sMappedHome, relative);
    return written > 0 && (size_t)written < cap;
}

static BOOL NKCMapPath(const char *path, char *mapped, size_t cap) {
    if (!path || !path[0]) return NO;
    if (path[0] == '/') return NKCMapAbsolutePath(path, mapped, cap);

    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof(cwd))) return NO;
    char combined[PATH_MAX];
    int written = snprintf(combined, sizeof(combined), "%s/%s", cwd, path);
    if (written <= 0 || (size_t)written >= sizeof(combined)) return NO;
    return NKCMapAbsolutePath(combined, mapped, cap);
}

static BOOL NKCMapAtPath(int dirfd, const char *path, int *effectiveDirFD, char *mapped, size_t cap) {
    if (!path || !effectiveDirFD) return NO;
    if (path[0] == '/') {
        if (NKCMapAbsolutePath(path, mapped, cap)) {
            *effectiveDirFD = AT_FDCWD;
            return YES;
        }
        return NO;
    }

    char base[PATH_MAX];
    if (dirfd == AT_FDCWD) {
        if (!getcwd(base, sizeof(base))) return NO;
    } else {
        if (fcntl(dirfd, F_GETPATH, base) != 0) return NO;
    }

    char combined[PATH_MAX];
    int written = snprintf(combined, sizeof(combined), "%s/%s", base, path);
    if (written <= 0 || (size_t)written >= sizeof(combined)) return NO;
    if (!NKCMapAbsolutePath(combined, mapped, cap)) return NO;
    *effectiveDirFD = AT_FDCWD;
    return YES;
}

static int NK_open(const char *path, int flags, ...) {
    char mapped[PATH_MAX];
    const char *effective = NKCMapPath(path, mapped, sizeof(mapped)) ? mapped : path;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); mode_t mode = (mode_t)va_arg(ap, int); va_end(ap);
        return orig_open(effective, flags, mode);
    }
    return orig_open(effective, flags);
}

static int NK_openat(int dirfd, const char *path, int flags, ...) {
    char mapped[PATH_MAX];
    int effectiveDirFD = dirfd;
    const char *effective = path;
    if (NKCMapAtPath(dirfd, path, &effectiveDirFD, mapped, sizeof(mapped))) effective = mapped;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); mode_t mode = (mode_t)va_arg(ap, int); va_end(ap);
        return orig_openat(effectiveDirFD, effective, flags, mode);
    }
    return orig_openat(effectiveDirFD, effective, flags);
}

static int NK_creat(const char *path, mode_t mode) { char m[PATH_MAX]; return orig_creat(NKCMapPath(path,m,sizeof(m))?m:path, mode); }
static FILE *NK_fopen(const char *path, const char *mode) { char m[PATH_MAX]; return orig_fopen(NKCMapPath(path,m,sizeof(m))?m:path, mode); }
static FILE *NK_freopen(const char *path, const char *mode, FILE *stream) { if (!path) return orig_freopen(path,mode,stream); char m[PATH_MAX]; return orig_freopen(NKCMapPath(path,m,sizeof(m))?m:path, mode, stream); }
static int NK_stat(const char *path, struct stat *st) { char m[PATH_MAX]; return orig_stat(NKCMapPath(path,m,sizeof(m))?m:path, st); }
static int NK_lstat(const char *path, struct stat *st) { char m[PATH_MAX]; return orig_lstat(NKCMapPath(path,m,sizeof(m))?m:path, st); }
static int NK_access(const char *path, int mode) { char m[PATH_MAX]; return orig_access(NKCMapPath(path,m,sizeof(m))?m:path, mode); }
static int NK_chmod(const char *path, mode_t mode) { char m[PATH_MAX]; return orig_chmod(NKCMapPath(path,m,sizeof(m))?m:path, mode); }
static int NK_chown(const char *path, uid_t u, gid_t g) { char m[PATH_MAX]; return orig_chown(NKCMapPath(path,m,sizeof(m))?m:path, u, g); }
static int NK_unlink(const char *path) { char m[PATH_MAX]; return orig_unlink(NKCMapPath(path,m,sizeof(m))?m:path); }
static int NK_remove(const char *path) { char m[PATH_MAX]; return orig_remove(NKCMapPath(path,m,sizeof(m))?m:path); }
static int NK_mkdir(const char *path, mode_t mode) { char m[PATH_MAX]; return orig_mkdir(NKCMapPath(path,m,sizeof(m))?m:path, mode); }
static int NK_rmdir(const char *path) { char m[PATH_MAX]; return orig_rmdir(NKCMapPath(path,m,sizeof(m))?m:path); }
static DIR *NK_opendir(const char *path) { char m[PATH_MAX]; return orig_opendir(NKCMapPath(path,m,sizeof(m))?m:path); }
static int NK_rename(const char *a, const char *b) { char ma[PATH_MAX], mb[PATH_MAX]; return orig_rename(NKCMapPath(a,ma,sizeof(ma))?ma:a, NKCMapPath(b,mb,sizeof(mb))?mb:b); }
static int NK_link(const char *a, const char *b) { char ma[PATH_MAX], mb[PATH_MAX]; return orig_link(NKCMapPath(a,ma,sizeof(ma))?ma:a, NKCMapPath(b,mb,sizeof(mb))?mb:b); }
static int NK_symlink(const char *target, const char *linkpath) { char ml[PATH_MAX]; return orig_symlink(target, NKCMapPath(linkpath,ml,sizeof(ml))?ml:linkpath); }
static ssize_t NK_readlink(const char *path, char *buf, size_t size) { char m[PATH_MAX]; return orig_readlink(NKCMapPath(path,m,sizeof(m))?m:path, buf, size); }
static int NK_truncate(const char *path, off_t length) { char m[PATH_MAX]; return orig_truncate(NKCMapPath(path,m,sizeof(m))?m:path, length); }
static int NK_chdir(const char *path) { char m[PATH_MAX]; return orig_chdir(NKCMapPath(path,m,sizeof(m))?m:path); }

void NKCInstallFilesystemHooks(NSString *realHome, NSString *mappedHome) {
    if (sInstalled || !realHome.length || !mappedHome.length) return;
    sInstalled = YES;

    strlcpy(sRealHome, realHome.fileSystemRepresentation, sizeof(sRealHome));
    strlcpy(sMappedHome, mappedHome.fileSystemRepresentation, sizeof(sMappedHome));
    snprintf(sExcludedPrefix, sizeof(sExcludedPrefix), "%s/.nkcrane", sRealHome);

    if (strncmp(sRealHome, "/var/", 5) == 0) {
        snprintf(sRealHomeAlt, sizeof(sRealHomeAlt), "/private%s", sRealHome);
    } else if (strncmp(sRealHome, "/private/var/", 13) == 0) {
        strlcpy(sRealHomeAlt, sRealHome + 8, sizeof(sRealHomeAlt));
    }

    MSHookFunction((void *)open, (void *)NK_open, (void **)&orig_open);
    MSHookFunction((void *)openat, (void *)NK_openat, (void **)&orig_openat);
    MSHookFunction((void *)creat, (void *)NK_creat, (void **)&orig_creat);
    MSHookFunction((void *)fopen, (void *)NK_fopen, (void **)&orig_fopen);
    MSHookFunction((void *)freopen, (void *)NK_freopen, (void **)&orig_freopen);
    MSHookFunction((void *)stat, (void *)NK_stat, (void **)&orig_stat);
    MSHookFunction((void *)lstat, (void *)NK_lstat, (void **)&orig_lstat);
    MSHookFunction((void *)access, (void *)NK_access, (void **)&orig_access);
    MSHookFunction((void *)chmod, (void *)NK_chmod, (void **)&orig_chmod);
    MSHookFunction((void *)chown, (void *)NK_chown, (void **)&orig_chown);
    MSHookFunction((void *)unlink, (void *)NK_unlink, (void **)&orig_unlink);
    MSHookFunction((void *)remove, (void *)NK_remove, (void **)&orig_remove);
    MSHookFunction((void *)mkdir, (void *)NK_mkdir, (void **)&orig_mkdir);
    MSHookFunction((void *)rmdir, (void *)NK_rmdir, (void **)&orig_rmdir);
    MSHookFunction((void *)opendir, (void *)NK_opendir, (void **)&orig_opendir);
    MSHookFunction((void *)rename, (void *)NK_rename, (void **)&orig_rename);
    MSHookFunction((void *)link, (void *)NK_link, (void **)&orig_link);
    MSHookFunction((void *)symlink, (void *)NK_symlink, (void **)&orig_symlink);
    MSHookFunction((void *)readlink, (void *)NK_readlink, (void **)&orig_readlink);
    MSHookFunction((void *)truncate, (void *)NK_truncate, (void **)&orig_truncate);
    MSHookFunction((void *)chdir, (void *)NK_chdir, (void **)&orig_chdir);
}
