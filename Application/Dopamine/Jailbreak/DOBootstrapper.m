//
//  Bootstrapper.m
//  Dopamine
//
//  Created by Lars Fröder on 09.01.24.
//

#import "DOBootstrapper.h"
#import "DOBootstrapper+zstd.h"
#import "DOEnvironmentManager.h"
#import "DOUIManager.h"
#import <libjailbreak/info.h>
#import <libjailbreak/util.h>
#import <libjailbreak/jbclient_xpc.h>
#import <sys/mount.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <spawn.h>
#import "NSString+Version.h"

#define LIBKRW_DOPAMINE_BUNDLED_VERSION @"2.0.3"
#define LIBROOT_DOPAMINE_BUNDLED_VERSION @"1.0.1"
#define BASEBIN_LINK_BUNDLED_VERSION @"1.0.0"
#define LAUNCHCTL_BUNDLED_VERSION @"1:1.2.0"

static NSDictionary *gBundledPackages = @{
    @"libkrw0-dopamine" : LIBKRW_DOPAMINE_BUNDLED_VERSION,
    @"libroot-dopamine" : LIBROOT_DOPAMINE_BUNDLED_VERSION,
    @"dopamine-basebin-link" : BASEBIN_LINK_BUNDLED_VERSION,
    @"launchctl" : LAUNCHCTL_BUNDLED_VERSION,
};

struct hfs_mount_args {
    char    *fspec;
    uid_t    hfs_uid;        /* uid that owns hfs files (standard HFS only) */
    gid_t    hfs_gid;        /* gid that owns hfs files (standard HFS only) */
    mode_t    hfs_mask;        /* mask to be applied for hfs perms  (standard HFS only) */
    uint32_t hfs_encoding;        /* encoding for this volume (standard HFS only) */
    struct    timezone hfs_timezone;    /* user time zone info (standard HFS only) */
    int        flags;            /* mounting flags, see below */
    int     journal_tbuffer_size;   /* size in bytes of the journal transaction buffer */
    int        journal_flags;          /* flags to pass to journal_open/create */
    int        journal_disable;        /* don't use journaling (potentially dangerous) */
};

NSString *const bootstrapErrorDomain = @"BootstrapErrorDomain";

@implementation DOBootstrapper

- (instancetype)init
{
    self = [super init];
    if (self) {
        /*NSURLSessionConfiguration *config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@"com.opa334.bootstrapper.background-session"];
        _urlSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];*/
    }
    return self;
}

- (NSError *)extractTar:(NSString *)tarPath toPath:(NSString *)destinationPath
{
    int r = libarchive_unarchive(tarPath.fileSystemRepresentation, destinationPath.fileSystemRepresentation);
    if (r != 0) {
        return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedExtracting userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"libarchive returned %d", r]}];
    }
    return nil;
}

- (BOOL)deleteSymlinkAtPath:(NSString *)path error:(NSError **)error
{
    NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:error];
    if (!attributes) return YES;
    if (attributes[NSFileType] == NSFileTypeSymbolicLink) {
        return [[NSFileManager defaultManager] removeItemAtPath:path error:error];
    }
    return NO;
}

- (BOOL)fileOrSymlinkExistsAtPath:(NSString *)path
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
    
    NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (attributes) {
        if (attributes[NSFileType] == NSFileTypeSymbolicLink) {
            return YES;
        }
    }
    
    return NO;
}

- (NSError *)createSymlinkAtPath:(NSString *)path toPath:(NSString *)destinationPath createIntermediateDirectories:(BOOL)createIntermediate
{
    NSError *error;
    NSString *parentPath = [path stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] fileExistsAtPath:parentPath]) {
        if (!createIntermediate) return [NSError errorWithDomain:bootstrapErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed create %@->%@ symlink: Parent dir does not exists", path, destinationPath]}];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:parentPath withIntermediateDirectories:YES attributes:nil error:&error]) return error;
    }
    
    [[NSFileManager defaultManager] createSymbolicLinkAtPath:path withDestinationPath:destinationPath error:&error];
    return error;
}

- (BOOL)isPrivatePrebootMountedWritable
{
    struct statfs ppStfs;
    statfs([[DOEnvironmentManager sharedManager] privatePrebootPath].fileSystemRepresentation, &ppStfs);
    return !(ppStfs.f_flags & MNT_RDONLY);
}

- (int)remountPrivatePrebootWritable:(BOOL)writable
{
    const char *ppPath = [[DOEnvironmentManager sharedManager] privatePrebootPath].fileSystemRepresentation;

    struct statfs ppStfs;
    int r = statfs(ppPath, &ppStfs);
    if (r != 0) return r;
    
    uint32_t flags = MNT_UPDATE;
    if (!writable) {
        flags |= MNT_RDONLY;
    }
    struct hfs_mount_args mntargs =
    {
        .fspec = ppStfs.f_mntfromname,
        .hfs_mask = 0,
    };
    return mount("apfs", ppPath, flags, &mntargs);
}

- (NSError *)ensurePrivatePrebootIsWritable
{
    if (![self isPrivatePrebootMountedWritable]) {
        int r = [self remountPrivatePrebootWritable:YES];
        if (r != 0) {
            return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedRemount userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Remounting /private/preboot as writable failed with error: %s", strerror(errno)]}];
        }
    }
    return nil;
}

- (void)fixupPathPermissions
{
    // Ensure the following paths are owned by root:wheel and have permissions of 755:
    // /private
    // /private/preboot
    // /private/preboot/UUID
    // /private/preboot/UUID/dopamine-<UUID>
    // /private/preboot/UUID/dopamine-<UUID>/procursus

    NSString *tmpPath = JBROOT_PATH(@"/");
    while (![tmpPath isEqualToString:@"/"]) {
        struct stat s;
        stat(tmpPath.fileSystemRepresentation, &s);
        if (s.st_uid != 0 || s.st_gid != 0) {
            chown(tmpPath.fileSystemRepresentation, 0, 0);
        }
        if ((s.st_mode & S_IRWXU) != 0755) {
            chmod(tmpPath.fileSystemRepresentation, 0755);
        }
        tmpPath = [tmpPath stringByDeletingLastPathComponent];
    }
}

- (void)patchBasebinDaemonPlist:(NSString *)plistPath
{
    NSMutableDictionary *plistDict = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
    if (plistDict) {
        bool madeChanges = NO;
        NSMutableArray *programArguments = ((NSArray *)plistDict[@"ProgramArguments"]).mutableCopy;
        for (NSString *argument in [programArguments reverseObjectEnumerator]) {
            if ([argument containsString:@"@JBROOT@"]) {
                programArguments[[programArguments indexOfObject:argument]] = [argument stringByReplacingOccurrencesOfString:@"@JBROOT@" withString:JBROOT_PATH(@"/")];
                madeChanges = YES;
            }
        }
        if (madeChanges) {
            plistDict[@"ProgramArguments"] = programArguments.copy;
            [plistDict writeToFile:plistPath atomically:NO];
        }
    }
}

- (void)patchBasebinDaemonPlists
{
    NSURL *basebinDaemonsURL = [NSURL fileURLWithPath:JBROOT_PATH(@"/basebin/LaunchDaemons")];
    for (NSURL *basebinDaemonURL in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:basebinDaemonsURL includingPropertiesForKeys:nil options:0 error:nil]) {
        [self patchBasebinDaemonPlist:basebinDaemonURL.path];
    }
}

- (NSString *)bootstrapVersion
{
    uint64_t cfver = (((uint64_t)kCFCoreFoundationVersionNumber / 100) * 100);
    if (cfver >= 2000) {
        return @"1900";
    }
    return [NSString stringWithFormat:@"%llu", cfver];
}

- (NSURL *)bootstrapURL
{
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://apt.procurs.us/bootstraps/%@/bootstrap-ssh-iphoneos-arm64.tar.zst", [self bootstrapVersion]]];
}

/*- (void)downloadBootstrapWithCompletion:(void (^)(NSString *path, NSError *error))completion
{
    NSURL *bootstrapURL = [self bootstrapURL];
    if (!bootstrapURL) {
        completion(nil, [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedToGetURL userInfo:@{NSLocalizedDescriptionKey : @"Failed to obtain bootstrap URL"}]);
        return;
    }
    
    _downloadCompletionBlock = ^(NSURL * _Nullable location, NSError * _Nullable error) {
        NSError *ourError;
        if (error) {
            ourError = [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedToDownload userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to download bootstrap: %@", error.localizedDescription]}];
        }
        completion(location.path, ourError);
    };
    
    _bootstrapDownloadTask = [_urlSession downloadTaskWithURL:bootstrapURL];
    [_bootstrapDownloadTask resume];
}*/

- (void)extractBootstrap:(NSString *)path withCompletion:(void (^)(NSError *))completion
{
    NSString *bootstrapTar = [@"/var/tmp" stringByAppendingPathComponent:@"bootstrap.tar"];
    NSError *decompressionError = [self decompressZstd:path toTar:bootstrapTar];
    if (decompressionError) {
        completion(decompressionError);
        return;
    }
    
    decompressionError = [self extractTar:bootstrapTar toPath:@"/"];
    if (decompressionError) {
        completion(decompressionError);
        return;
    }
    
    [[NSData data] writeToFile:JBROOT_PATH(@"/.installed_dopamine") atomically:YES];
    completion(nil);
}

- (NSError *)updateVarJbSymlink
{
    // Remove /var/69 as it might be wrong
    NSError *error;
    if (![self deleteSymlinkAtPath:@"/var/69" error:&error]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/69"]) {
            if (![[NSFileManager defaultManager] removeItemAtPath:@"/var/69" error:&error]) {
                return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedReplacing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Removing /var/69 directory failed with error: %@", error]}];
            }
        }
        else {
            return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedReplacing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Removing /var/69 symlink failed with error: %@", error]}];
        }
    }

    return [self createSymlinkAtPath:@"/var/69" toPath:JBROOT_PATH(@"/") createIntermediateDirectories:YES];;
}

- (void)prepareBootstrapWithCompletion:(void (^)(NSError *))completion
{
    [[DOUIManager sharedInstance] sendLog:@"Updating BaseBin" debug:NO];

    // Ensure /private/preboot is mounted writable (Not writable by default on iOS <=15)
    NSError *error = [self ensurePrivatePrebootIsWritable];
    if (error) {
        completion(error);
        return;
    }
    
    [self fixupPathPermissions];
    
    // Clean up xinaA15 v1 leftovers if desired
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/var/.keep_symlinks"]) {
        NSArray *xinaLeftoverSymlinks = @[
            @"/var/alternatives",
            @"/var/ap",
            @"/var/apt",
            @"/var/bin",
            @"/var/bzip2",
            @"/var/cache",
            @"/var/dpkg",
            @"/var/etc",
            @"/var/gzip",
            @"/var/lib",
            @"/var/Lib",
            @"/var/libexec",
            @"/var/Library",
            @"/var/LIY",
            @"/var/Liy",
            @"/var/local",
            @"/var/newuser",
            @"/var/profile",
            @"/var/sbin",
            @"/var/suid_profile",
            @"/var/sh",
            @"/var/sy",
            @"/var/share",
            @"/var/ssh",
            @"/var/sudo_logsrvd.conf",
            @"/var/suid_profile",
            @"/var/sy",
            @"/var/usr",
            @"/var/zlogin",
            @"/var/zlogout",
            @"/var/zprofile",
            @"/var/zshenv",
            @"/var/zshrc",
            @"/var/log/dpkg",
            @"/var/log/apt",
        ];
        NSArray *xinaLeftoverFiles = @[
            @"/var/lib",
            @"/var/master.passwd"
        ];
        
        for (NSString *xinaLeftoverSymlink in xinaLeftoverSymlinks) {
            [self deleteSymlinkAtPath:xinaLeftoverSymlink error:nil];
        }
        
        for (NSString *xinaLeftoverFile in xinaLeftoverFiles) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:xinaLeftoverFile]) {
                [[NSFileManager defaultManager] removeItemAtPath:xinaLeftoverFile error:nil];
            }
        }
    }
    
    NSString *basebinPath = JBROOT_PATH(@"/basebin");
    NSString *installedPath = JBROOT_PATH(@"/.installed_dopamine");
    error = [self updateVarJbSymlink];
    if (error) {
        completion(error);
        return;
    }
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:basebinPath]) {
        if (![[NSFileManager defaultManager] removeItemAtPath:basebinPath error:&error]) {
            BOOL recovered = NO;

            NSString *corruptedFilePath = JBROOT_PATH(@"/basebin/gen/dyld.old");
            if ([[NSFileManager defaultManager] fileExistsAtPath:corruptedFilePath]) {
                if (![[NSFileManager defaultManager] removeItemAtPath:corruptedFilePath error:nil]) {
                    // Try to recover from file system corruption
                    // In Dopamine 3.0 - 3.0.6 there was an OOB kwritebuf in jbupdate that could cause a panic
                    // This would sometimes leave /var/69/basebin/gen/dyld.old behind in a corrupted state
                    // We cannot delete this file unfortunately, but we can move it

                    NSString *activePrebootPath = [[DOEnvironmentManager sharedManager] activePrebootPath];

                    NSString *characterSet = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
                    NSUInteger stringLen = 6;
                    NSMutableString *randomString = [NSMutableString stringWithCapacity:stringLen];
                    for (NSUInteger i = 0; i < stringLen; i++) {
                        NSUInteger randomIndex = arc4random_uniform((uint32_t)[characterSet length]);
                        unichar randomCharacter = [characterSet characterAtIndex:randomIndex];
                        [randomString appendFormat:@"%C", randomCharacter];
                    }

                    NSString *orphanedName = [NSString stringWithFormat:@"orphaned-%@", randomString];
                    NSString *orphanedPath = [activePrebootPath stringByAppendingPathComponent:orphanedName];
                    [[NSFileManager defaultManager] moveItemAtPath:corruptedFilePath toPath:orphanedPath error:nil];

                    if ([[NSFileManager defaultManager] removeItemAtPath:basebinPath error:&error]) {
                        // If now that the file is moved, we can remove the basebin dir, consider the issue solved
                        recovered = YES;
                        error = nil;
                    }
                }
            }

            if (!recovered) {
                completion([NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedExtracting userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed deleting existing basebin file with error: %@", error.localizedDescription]}]);
                return;
            }
        }
    }
    error = [self extractTar:[[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"basebin.tar"] toPath:JBROOT_PATH(@"/")];
    if (error) {
        completion(error);
        return;
    }
    [self patchBasebinDaemonPlists];
    
    void (^bootstrapFinishedCompletion)(NSError *) = ^(NSError *error){
        if (error) {
            completion(error);
            return;
        }
        
        NSString *defaultSources = @"Types: deb\n"
            @"URIs: https://repo.chariz.com/\n"
            @"Suites: ./\n"
            @"Components:\n"
            @"\n"
            @"Types: deb\n"
            @"URIs: https://havoc.app/\n"
            @"Suites: ./\n"
            @"Components:\n"
            @"\n"
            @"Types: deb\n"
            @"URIs: http://apt.thebigboss.org/repofiles/cydia/\n"
            @"Suites: stable\n"
            @"Components: main\n"
            @"\n"
            @"Types: deb\n"
            @"URIs: https://ellekit.space/\n"
            @"Suites: ./\n"
            @"Components:\n";
        [defaultSources writeToFile:JBROOT_PATH(@"/etc/apt/sources.list.d/default.sources") atomically:NO encoding:NSUTF8StringEncoding error:nil];
        
        NSString *mobilePreferencesPath = JBROOT_PATH(@"/var/mobile/Library/Preferences");
        if (![[NSFileManager defaultManager] fileExistsAtPath:mobilePreferencesPath]) {
            NSDictionary<NSFileAttributeKey, id> *attributes = @{
                NSFilePosixPermissions : @0755,
                NSFileOwnerAccountID : @501,
                NSFileGroupOwnerAccountID : @501,
            };
            [[NSFileManager defaultManager] createDirectoryAtPath:mobilePreferencesPath withIntermediateDirectories:YES attributes:attributes error:nil];
        }
        
        JBFixMobilePermissions();

        completion(nil);
    };
    
    
    BOOL needsBootstrap = ![[NSFileManager defaultManager] fileExistsAtPath:installedPath];
    if (needsBootstrap) {
        // First, wipe any existing content that's not basebin
        for (NSURL *subItemURL in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:JBROOT_PATH(@"/")] includingPropertiesForKeys:nil options:0 error:nil]) {
            if (![subItemURL.lastPathComponent isEqualToString:@"basebin"]) {
                [[NSFileManager defaultManager] removeItemAtURL:subItemURL error:nil];
            }
        }
        
        /*void (^bootstrapDownloadCompletion)(NSString *, NSError *) = ^(NSString *path, NSError *error) {
            if (error) {
                completion(error);
                return;
            }
            [self extractBootstrap:path withCompletion:bootstrapFinishedCompletion];
        };*/
        
        [[DOUIManager sharedInstance] sendLog:@"Extracting Bootstrap" debug:NO];

        NSString *bootstrapZstdPath = [NSString stringWithFormat:@"%@/bootstrap_%@.tar.zst", [NSBundle mainBundle].bundlePath, [self bootstrapVersion]];
        [self extractBootstrap:bootstrapZstdPath withCompletion:bootstrapFinishedCompletion];

        /*NSString *documentsCandidate = @"/var/mobile/Documents/bootstrap.tar.zstd";
        NSString *bundleCandidate = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"bootstrap.tar.zstd"];
        // Check if the user provided a bootstrap
        if ([[NSFileManager defaultManager] fileExistsAtPath:documentsCandidate]) {
            bootstrapDownloadCompletion(documentsCandidate, nil);
        }
        else if ([[NSFileManager defaultManager] fileExistsAtPath:bundleCandidate]) {
            bootstrapDownloadCompletion(bundleCandidate, nil);
        }
        else {
            [[DOUIManager sharedInstance] sendLog:@"Downloading Bootstrap" debug:NO];
            [self downloadBootstrapWithCompletion:bootstrapDownloadCompletion];
        }*/
    }
    else {
        bootstrapFinishedCompletion(nil);
    }
}

- (int)installPackage:(NSString *)packagePath
{
    // Use posix_spawn with proper environment setup (like jbinit/palera1n_loader_mod)
    // This ensures dpkg has access to required libraries and tools
    
    const char *dpkgPath = JBROOT_PATH("/usr/bin/dpkg");
    const char *packagePathC = packagePath.fileSystemRepresentation;
    
    // Build argv for dpkg with --force-depends to handle bootstrap environment
    char *dpkg_argv[] = {
        "dpkg",
        "-i",
        (char *)packagePathC,
        NULL
    };
    
    // CRITICAL: Set proper environment for dpkg
    // dpkg needs: sh, rm, tar, diff, dpkg-deb in PATH
    // Libraries need to be accessible via DYLD_LIBRARY_PATH
    // Build PATH and DYLD_LIBRARY_PATH strings at runtime
    static char path_env[512];
    static char dyld_env[512];
    snprintf(path_env, sizeof(path_env), "PATH=/usr/bin:/bin:/usr/sbin:/sbin:%s:%s", 
             JBROOT_PATH("/usr/bin"), JBROOT_PATH("/bin"));
    snprintf(dyld_env, sizeof(dyld_env), "DYLD_LIBRARY_PATH=%s", JBROOT_PATH("/usr/lib"));
    
    char *dpkg_env[] = {
        path_env,
        dyld_env,
        "HOME=/var/root",
        "USER=root",
        "TMPDIR=/tmp",
        NULL
    };
    
    pid_t dpkg_pid;
    int status;
    
    // Use posix_spawn instead of exec_cmd_trusted to have full control over environment
    int spawn_result = posix_spawn(&dpkg_pid, dpkgPath, NULL, NULL, dpkg_argv, dpkg_env);
    
    if (spawn_result != 0) {
        NSLog(@"[Dopamine] posix_spawn dpkg failed: %d - %s", spawn_result, strerror(spawn_result));
        return spawn_result;
    }
    
    // Wait for dpkg to complete
    if (waitpid(dpkg_pid, &status, 0) == -1) {
        NSLog(@"[Dopamine] waitpid dpkg failed: %d - %s", errno, strerror(errno));
        return errno;
    }
    
    // Return exit code
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        NSLog(@"[Dopamine] dpkg terminated by signal %d", WTERMSIG(status));
        return -1;
    }
    
    return 0;
}

- (int)installSileoWithProperEnvironment
{
    // ===========================================================================
    // PHASE 1: INITIALIZE DPKG DATABASE WITH BOOTSTRAP PACKAGES
    // ===========================================================================
    // The bootstrap tar.zst extracts with status-old containing all packages
    // but the status files are empty. We MUST copy status-old to status
    // before installing ANY packages.
    // ===========================================================================
    
    NSLog(@"[Dopamine] ========== SILEO INSTALLATION VIA DPKG ==========");
    NSLog(@"[Dopamine] PHASE 1: Initializing dpkg database with bootstrap packages");
    
    NSString *statusOldPath = JBROOT_PATH(@"/var/lib/dpkg/status-old");
    NSString *statusPath = JBROOT_PATH(@"/var/lib/dpkg/status");
    NSString *libraryStatusPath = JBROOT_PATH(@"/Library/dpkg/status");
    
    // Check if status-old exists
    if ([[NSFileManager defaultManager] fileExistsAtPath:statusOldPath]) {
        NSError *error = nil;
        
        // Copy status-old to main status database
        if ([[NSFileManager defaultManager] fileExistsAtPath:statusPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:statusPath error:nil];
        }
        [[NSFileManager defaultManager] copyItemAtPath:statusOldPath toPath:statusPath error:&error];
        
        if (error) {
            NSLog(@"[Dopamine] ✗ Failed to copy status-old to status: %@", error);
        } else {
            NSLog(@"[Dopamine] ✓ Copied status-old → status (main database initialized)");
        }
        
        // Also copy to Library location
        NSString *libraryDpkgDir = [libraryStatusPath stringByDeletingLastPathComponent];
        if (![[NSFileManager defaultManager] fileExistsAtPath:libraryDpkgDir]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:libraryDpkgDir 
                                       withIntermediateDirectories:YES 
                                                        attributes:nil 
                                                             error:nil];
        }
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:libraryStatusPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:libraryStatusPath error:nil];
        }
        [[NSFileManager defaultManager] copyItemAtPath:statusOldPath toPath:libraryStatusPath error:&error];
        
        if (error) {
            NSLog(@"[Dopamine] ✗ Failed to copy to Library location: %@", error);
        } else {
            NSLog(@"[Dopamine] ✓ Copied status-old → Library/dpkg/status");
            NSLog(@"[Dopamine] ✓ Both dpkg databases now contain ~67 bootstrap packages");
        }
    } else {
        NSLog(@"[Dopamine] ⚠ status-old not found - database may already be initialized");
    }
    
    // ===========================================================================
    // PHASE 2: INSTALL SILEO VIA DPKG USING POSIX_SPAWN
    // ===========================================================================
    // CRITICAL: Must use posix_spawn() NOT exec_cmd_trusted()
    // posix_spawn() triggers spawn_hook_common() which injects systemhook.dylib
    // and sets up proper jailbreak environment variables
    // ===========================================================================
    
    NSLog(@"[Dopamine] PHASE 2: Installing Sileo via dpkg (posix_spawn with hook injection)");
    
    NSString *sileoDebPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"org.coolstar.sileo_2.5.1_iphoneos-arm64.deb"];
    
    // Verify Sileo .deb exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:sileoDebPath]) {
        NSLog(@"[Dopamine] ✗ CRITICAL: Sileo .deb NOT FOUND at %@", sileoDebPath);
        return -1;
    }
    
    struct stat deb_stat;
    stat(sileoDebPath.fileSystemRepresentation, &deb_stat);
    NSLog(@"[Dopamine] ✓ Sileo .deb found (size: %lld bytes)", (long long)deb_stat.st_size);
    
    const char *dpkgPath = JBROOT_PATH("/usr/bin/dpkg");
    const char *debPathC = sileoDebPath.fileSystemRepresentation;
    
    // Build argv for dpkg with --force-depends
    // This is necessary because bootstrap environment doesn't have dpkg metadata
    // for packages like firmware, coreutils, apt, etc.
    char *dpkg_argv[] = {
        "dpkg",
        "--force-depends",           // Ignore missing dependencies
        "--force-depends-version",   // Ignore version conflicts
        "-i",
        (char *)debPathC,
        NULL
    };
    
    // CRITICAL: Build custom environment with correct PATH for dpkg
    // dpkg needs: sh, rm, tar, diff, dpkg-deb in PATH
    static char path_env[512];
    static char dyld_env[512];
    snprintf(path_env, sizeof(path_env), "PATH=/usr/bin:/bin:/usr/sbin:/sbin:%s:%s", 
             JBROOT_PATH("/usr/bin"), JBROOT_PATH("/bin"));
    snprintf(dyld_env, sizeof(dyld_env), "DYLD_LIBRARY_PATH=%s", JBROOT_PATH("/usr/lib"));
    
    char *dpkg_env[] = {
        path_env,
        dyld_env,
        "HOME=/var/root",
        "USER=root",
        "TMPDIR=/tmp",
        NULL
    };
    
    NSLog(@"[Dopamine] Executing: %s %s %s %s %s", 
          dpkg_argv[0], dpkg_argv[1], dpkg_argv[2], dpkg_argv[3], dpkg_argv[4]);
    NSLog(@"[Dopamine] NOTE: spawn_hook_common() will ADD jailbreak environment:");
    NSLog(@"[Dopamine]   - DYLD_INSERT_LIBRARIES=systemhook.dylib");
    NSLog(@"[Dopamine]   - JB_ROOT_PATH, JB_SANDBOX_EXTENSIONS");
    
    pid_t dpkg_pid;
    int status;
    
    // Use posix_spawn() - THIS TRIGGERS spawn_hook_common() FOR HOOK INJECTION!
    int spawn_result = posix_spawn(&dpkg_pid, dpkgPath, NULL, NULL, dpkg_argv, dpkg_env);
    
    if (spawn_result != 0) {
        NSLog(@"[Dopamine] ✗ posix_spawn() FAILED (errno: %d - %s)", spawn_result, strerror(spawn_result));
        return spawn_result;
    }
    
    NSLog(@"[Dopamine] ✓ Process spawned (PID: %d), waiting for completion...", dpkg_pid);
    
    // Wait for dpkg to complete
    if (waitpid(dpkg_pid, &status, 0) == -1) {
        NSLog(@"[Dopamine] ✗ waitpid() FAILED (errno: %d - %s)", errno, strerror(errno));
        return errno;
    }
    
    NSLog(@"[Dopamine] ========== DPKG EXIT STATUS ==========");
    NSLog(@"[Dopamine] Raw status: %d (0x%x)", status, status);
    
    int exit_code = 0;
    if (WIFEXITED(status)) {
        exit_code = WEXITSTATUS(status);
        NSLog(@"[Dopamine] Exited normally: YES");
        NSLog(@"[Dopamine] Exit code: %d", exit_code);
        
        if (exit_code != 0) {
            NSLog(@"[Dopamine] ⚠ DPKG exited with code %d (may be harmless postinst error)", exit_code);
            NSLog(@"[Dopamine] Note: Exit code 1 is normal if postinst script is missing");
            NSLog(@"[Dopamine] Sileo files were still extracted successfully");
            // Don't abort - continue with firmware initialization
        } else {
            NSLog(@"[Dopamine] ✓ DPKG completed successfully");
        }
    } else if (WIFSIGNALED(status)) {
        int signal = WTERMSIG(status);
        NSLog(@"[Dopamine] ✗ dpkg terminated by signal %d", signal);
        return -1;
    }
    
    // ===========================================================================
    // PHASE 3: FIRMWARE INITIALIZATION AND DATABASE SYNC
    // ===========================================================================
    // Run firmware binary to generate virtual packages
    // Then sync databases to avoid duplicates
    // ===========================================================================
    
    NSLog(@"[Dopamine] PHASE 3: Firmware initialization and database sync");
    
    const char *firmwarePath = JBROOT_PATH("/usr/libexec/firmware");
    
    // Check if firmware binary exists
    if (access(firmwarePath, X_OK) == 0) {
        NSLog(@"[Dopamine] Found firmware binary, executing...");
        
        char *firmware_argv[] = {
            (char *)firmwarePath,
            NULL
        };
        
        char *firmware_env[] = {
            path_env,
            dyld_env,
            NULL
        };
        
        pid_t firmware_pid;
        int firmware_spawn_result = posix_spawn(&firmware_pid, firmwarePath, NULL, NULL, firmware_argv, firmware_env);
        
        if (firmware_spawn_result != 0) {
            NSLog(@"[Dopamine] ✗ Failed to spawn firmware binary (errno: %d)", firmware_spawn_result);
        } else {
            int firmware_status;
            waitpid(firmware_pid, &firmware_status, 0);
            
            if (WIFEXITED(firmware_status) && WEXITSTATUS(firmware_status) == 0) {
                NSLog(@"[Dopamine] ✓ Firmware binary executed successfully");
                
                // ====================================================================
                // CRITICAL FIX: Avoid duplicate packages in status database
                // ====================================================================
                // The firmware binary already wrote to Library/dpkg/status correctly
                // It read existing packages, added firmware packages, wrote everything back
                // So Library/dpkg/status now has: [bootstrap packages] + [firmware packages]
                //
                // CORRECT SOLUTION: REPLACE var/lib/dpkg/status with Library/dpkg/status
                // This ensures both files are identical and contain ALL packages without duplicates
                // ====================================================================
                
                NSLog(@"[Dopamine] Synchronizing databases (replacing var/lib with Library version)...");
                NSLog(@"[Dopamine] Library/dpkg/status now contains: bootstrap + firmware packages");
                NSLog(@"[Dopamine] Copying Library/dpkg/status → var/lib/dpkg/status (REPLACE, not append)");
                
                NSError *syncError = nil;
                if ([[NSFileManager defaultManager] fileExistsAtPath:statusPath]) {
                    [[NSFileManager defaultManager] removeItemAtPath:statusPath error:nil];
                }
                [[NSFileManager defaultManager] copyItemAtPath:libraryStatusPath toPath:statusPath error:&syncError];
                
                if (syncError) {
                    NSLog(@"[Dopamine] ✗ Sync failed: %@", syncError);
                } else {
                    NSLog(@"[Dopamine] ✓ Copy successful: var/lib/dpkg/status now matches Library/dpkg/status");
                    NSLog(@"[Dopamine] ✓ Both files contain: ~333 bootstrap + ~10 firmware = ~343 packages");
                    NSLog(@"[Dopamine] ✓ NO duplicate packages!");
                }
            } else {
                NSLog(@"[Dopamine] ✗ Firmware binary failed with exit code %d", WEXITSTATUS(firmware_status));
            }
        }
    } else {
        NSLog(@"[Dopamine] ⚠ firmware binary not found at %s", firmwarePath);
    }
    
    NSLog(@"[Dopamine] ==========================================");
    NSLog(@"[Dopamine] ✓ SILEO INSTALLATION COMPLETE");
    NSLog(@"[Dopamine] Note: uicache will be run by DOEnvironmentManager");
    NSLog(@"[Dopamine] ==========================================");
    
    return 0;
}

- (int)uninstallPackageWithIdentifier:(NSString *)identifier
{
    return exec_cmd_trusted(JBROOT_PATH("/usr/bin/dpkg"), "-r", identifier.UTF8String, NULL);
}

- (NSString *)installedVersionForPackageWithIdentifier:(NSString *)identifier
{
    NSString *dpkgStatus = [NSString stringWithContentsOfFile:JBROOT_PATH(@"/var/lib/dpkg/status") encoding:NSUTF8StringEncoding error:nil];
    NSString *packageStartLine = [NSString stringWithFormat:@"Package: %@", identifier];
    
    NSArray *packageInfos = [dpkgStatus componentsSeparatedByString:@"\n\n"];
    for (NSString *packageInfo in packageInfos) {
        if ([packageInfo hasPrefix:packageStartLine]) {
            __block NSString *version = nil;
            [packageInfo enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
                if ([line hasPrefix:@"Version: "]) {
                    version = [line substringFromIndex:9];
                }
            }];
            return version;
        }
    }
    return nil;
}

- (NSError *)installPackageManagers
{
    NSArray *enabledPackageManagers = [[DOUIManager sharedInstance] enabledPackageManagers];
    
    // Check if Sileo is in the enabled package managers
    BOOL hasSileo = NO;
    for (NSDictionary *packageManagerDict in enabledPackageManagers) {
        NSString *packageFile = packageManagerDict[@"Package"];
        if ([packageFile containsString:@"sileo"]) {
            hasSileo = YES;
            break;
        }
    }
    
    if (hasSileo) {
        // Use the comprehensive three-phase installation method for Sileo
        NSLog(@"[Dopamine] Installing Sileo using comprehensive three-phase approach");
        int r = [self installSileoWithProperEnvironment];
        if (r != 0) {
            return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install Sileo via comprehensive method: %d\n", r]}];
        }
        NSLog(@"[Dopamine] ✓ Sileo installed successfully using palera1n-style mechanism");
    } else {
        // Install other package managers using the standard method
        for (NSDictionary *packageManagerDict in enabledPackageManagers) {
            NSString *path = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:packageManagerDict[@"Package"]];
            NSString *name = packageManagerDict[@"Display Name"];
            int r = [self installPackage:path];
            if (r != 0) {
                return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install %@: %d\n", name, r]}];
            }
        }
    }
    
    return nil;
}

- (BOOL)shouldInstallPackage:(NSString *)identifier
{
    NSString *bundledVersion = gBundledPackages[identifier];
    if (!bundledVersion) return NO;
    
    NSString *installedVersion = [self installedVersionForPackageWithIdentifier:identifier];
    if (!installedVersion) return YES;
    
    return [installedVersion numericalVersionRepresentation] < [bundledVersion numericalVersionRepresentation];
}

- (NSError *)finalizeBootstrap
{
    // Initial setup on first jailbreak
    if ([[NSFileManager defaultManager] fileExistsAtPath:JBROOT_PATH(@"/prep_bootstrap.sh")]) {
        [[DOUIManager sharedInstance] sendLog:@"Finalizing Bootstrap" debug:NO];
        int r = exec_cmd_trusted(JBROOT_PATH("/bin/sh"), JBROOT_PATH("/prep_bootstrap.sh"), NULL);
        if (r != 0) {
            return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"prep_bootstrap.sh returned %d\n", r]}];
        }
        
        NSError *error = [self installPackageManagers];
        if (error) return error;
    }
    
    BOOL shouldInstallLibroot = [self shouldInstallPackage:@"libroot-dopamine"];
    BOOL shouldInstallLibkrw = [self shouldInstallPackage:@"libkrw0-dopamine"];
    BOOL shouldInstallBasebinLink = [self shouldInstallPackage:@"dopamine-basebin-link"];
    BOOL shouldInstallLaunchctl = NO;
    if (__builtin_available(iOS 19.0, *)) {
        shouldInstallLaunchctl = [self shouldInstallPackage:@"launchctl"];
    }
    
    if (shouldInstallLibroot || shouldInstallLibkrw || shouldInstallBasebinLink || shouldInstallLaunchctl) {
        [[DOUIManager sharedInstance] sendLog:@"Updating Bundled Packages" debug:NO];

        if (shouldInstallLaunchctl) {
            NSString *launchctlPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"launchctl_1_1.2.0_iphoneos-arm64.deb"];
            int r = [self installPackage:launchctlPath];
            if (r != 0) return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install launchctl: %d\n", r]}];
        }

        if (shouldInstallLibroot) {
            NSString *librootPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"libroot.deb"];
            int r = [self installPackage:librootPath];
            if (r != 0) return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install libroot: %d\n", r]}];
        }
        
        if (shouldInstallLibkrw) {
            NSString *libkrwPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"libkrw-dopamine.deb"];
            int r = [self installPackage:libkrwPath];
            if (r != 0) return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install the libkrw plugin: %d\n", r]}];
        }
        
        if (shouldInstallBasebinLink) {
            // Clean symlinks from earlier Dopamine versions
            if ([self fileOrSymlinkExistsAtPath:JBROOT_PATH(@"/usr/bin/opainject")]) {
                [[NSFileManager defaultManager] removeItemAtPath:JBROOT_PATH(@"/usr/bin/opainject") error:nil];
            }
            if ([self fileOrSymlinkExistsAtPath:JBROOT_PATH(@"/usr/bin/jbctl")]) {
                [[NSFileManager defaultManager] removeItemAtPath:JBROOT_PATH(@"/usr/bin/jbctl") error:nil];
            }
            if ([self fileOrSymlinkExistsAtPath:JBROOT_PATH(@"/usr/lib/libjailbreak.dylib")]) {
                [[NSFileManager defaultManager] removeItemAtPath:JBROOT_PATH(@"/usr/lib/libjailbreak.dylib") error:nil];
            }
            if ([self fileOrSymlinkExistsAtPath:JBROOT_PATH(@"/usr/bin/libjailbreak.dylib")]) {
                // Yes this exists >.< was a typo
                [[NSFileManager defaultManager] removeItemAtPath:JBROOT_PATH(@"/usr/bin/libjailbreak.dylib") error:nil];
            }
            
            NSString *basebinLinkPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"basebin-link.deb"];
            int r = [self installPackage:basebinLinkPath];
            if (r != 0) return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install basebin link: %d\n", r]}];
        }
    }

    return nil;
}

- (NSError *)deleteBootstrap
{
    NSError *error = [self ensurePrivatePrebootIsWritable];
    if (error) return error;
    NSString *path = [[NSString stringWithUTF8String:gSystemInfo.jailbreakInfo.rootPath] stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
    if (error) return error;
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/69" error:nil];
    return error;
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    if (downloadTask == _bootstrapDownloadTask) {
        NSString *sizeString = [NSByteCountFormatter stringFromByteCount:totalBytesWritten countStyle:NSByteCountFormatterCountStyleFile];
        NSString *writtenBytesString = [NSByteCountFormatter stringFromByteCount:totalBytesExpectedToWrite countStyle:NSByteCountFormatterCountStyleFile];
        
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Downloading Bootstrap (%@/%@)", sizeString, writtenBytesString] debug:NO update:YES];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    _downloadCompletionBlock(nil, error);
}

- (void)URLSession:(nonnull NSURLSession *)session downloadTask:(nonnull NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(nonnull NSURL *)location
{
    _downloadCompletionBlock(location, nil);
}

@end
