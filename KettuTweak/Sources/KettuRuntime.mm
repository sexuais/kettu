#import "KettuRuntime.h"
#import "KettuJSI.h"
#import "Fonts.h"
#import "LoaderConfig.h"
#import "Logger.h"
#import "Themes.h"
#import "Utils.h"

using namespace facebook;

static NSData *downloadKettu(NSURL *directory) {
    LoaderConfig *config = [[LoaderConfig alloc] init];
    [config loadConfig];

    NSURL *url = nil;
    if (config.customLoadUrlEnabled && config.customLoadUrl) {
        url = config.customLoadUrl;
        BunnyLog(@"[KettuRuntime] Using custom load URL: %@", url.absoluteString);
    } else {
        url = [NSURL URLWithString:
            @"https://codeberg.org/cocobo1/Kettu/raw/branch/dist/kettu.min.js"];
    }

    if (!url) return nil;

    NSURL *cached = [directory URLByAppendingPathComponent:@"bundle.js"];
    NSData *old = [NSData dataWithContentsOfURL:cached];

    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:url
                                cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                            timeoutInterval:3.0];

    NSString *etag =
        [NSString stringWithContentsOfURL:
            [directory URLByAppendingPathComponent:@"etag.txt"]
                                  encoding:NSUTF8StringEncoding
                                     error:nil];

    if (etag && old) {
        [request setValue:etag forHTTPHeaderField:@"If-None-Match"];
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *result = nil;
    __block NSString *newEtag = nil;

    NSURLSession *session =
        [NSURLSession sessionWithConfiguration:
            [NSURLSessionConfiguration defaultSessionConfiguration]];

    [[session dataTaskWithRequest:request
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;

            if (http.statusCode == 200 && data.length) {
                result = data;
                newEtag = [http valueForHTTPHeaderField:@"Etag"];
                BunnyLog(@"[KettuRuntime] Bundle download successful");
                cleanupBundleBackup();
            } else if (http.statusCode == 304 && old.length) {
                result = old;
                BunnyLog(@"[KettuRuntime] Bundle not modified (304)");
                cleanupBundleBackup();
            } else {
                BunnyLog(@"[KettuRuntime] Bundle download failed with status: %ld",
                         (long)http.statusCode);
            }
        }

        if (error) {
            BunnyLog(@"[KettuRuntime] download error: %@", error.localizedDescription);
        }

        dispatch_semaphore_signal(sem);
    }] resume];

    dispatch_semaphore_wait(
        sem,
        dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

    if (result) {
        [result writeToURL:cached atomically:YES];
        if (newEtag) {
            [newEtag writeToURL:
                [directory URLByAppendingPathComponent:@"etag.txt"]
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:nil];
        }
        return result;
    }

    if (old.length) return old;

    // Sem download e sem cache: tenta restaurar do backup
    BunnyLog(@"[KettuRuntime] No bundle available, attempting to restore from backup");
    if (restoreBundleFromBackup()) {
        NSData *restored = [NSData dataWithContentsOfURL:cached];
        if (restored.length) {
            BunnyLog(@"[KettuRuntime] Successfully restored bundle from backup");
            return restored;
        }
    } else {
        BunnyLog(@"[KettuRuntime] Failed to restore bundle from backup");
    }

    return nil;
}

static void applyTheme(NSURL *directory, jsi::Runtime &runtime) {
    NSData *themeData =
        [NSData dataWithContentsOfURL:
            [directory URLByAppendingPathComponent:@"current-theme.json"]];

    if (!themeData.length) {
        BunnyLog(@"[KettuRuntime] No theme data found");
        return;
    }

    NSError *jsonError = nil;
    NSDictionary *themeDict =
        [NSJSONSerialization JSONObjectWithData:themeData options:0 error:&jsonError];

    if (jsonError || ![themeDict isKindOfClass:[NSDictionary class]]) {
        BunnyLog(@"[KettuRuntime] Error parsing theme JSON: %@", jsonError);
        return;
    }

    BunnyLog(@"[KettuRuntime] Loading theme data...");

    NSDictionary *data = themeDict[@"data"];
    if ([data isKindOfClass:[NSDictionary class]] &&
        data[@"semanticColors"] && data[@"rawColors"]) {
        BunnyLog(@"[KettuRuntime] Initializing theme colors from theme data");
        initializeThemeColors(data[@"semanticColors"], data[@"rawColors"]);
    }

    NSString *themeJSON =
        [[NSString alloc] initWithData:themeData encoding:NSUTF8StringEncoding];
    if (!themeJSON) return;

    NSString *jsCode =
        [NSString stringWithFormat:@"globalThis.__PYON_LOADER__.storedTheme=%@", themeJSON];

    [KettuJSI evaluate:[jsCode dataUsingEncoding:NSUTF8StringEncoding]
                   tag:@"kettu:theme"
               runtime:runtime];
}

static void applyFonts(NSURL *directory) {
    NSData *fontData =
        [NSData dataWithContentsOfURL:
            [directory URLByAppendingPathComponent:@"fonts.json"]];

    if (!fontData.length) return;

    NSError *jsonError = nil;
    NSDictionary *fontDict =
        [NSJSONSerialization JSONObjectWithData:fontData options:0 error:&jsonError];

    if (!jsonError && [fontDict isKindOfClass:[NSDictionary class]] && fontDict[@"main"]) {
        BunnyLog(@"[KettuRuntime] Found font configuration, applying...");
        patchFonts(fontDict[@"main"], fontDict[@"name"]);
    }
}

void KettuLoadIntoRuntime(jsi::Runtime &runtime,
                          NSString *resourcesBundlePath,
                          NSURL *pyoncordDirectory) {
    static BOOL loaded = NO;
    if (loaded) return;
    loaded = YES;

    NSBundle *resources =
        [NSBundle bundleWithPath:resourcesBundlePath];

    if (!resources) {
        BunnyLog(@"[KettuRuntime] BunnyResources.bundle not found at %@",
                 resourcesBundlePath);
        dispatch_async(dispatch_get_main_queue(), ^{
            showErrorAlert(@"Loader Error",
                           @"Failed to initialize mod loader. Please reinstall the tweak.", nil);
        });
        loaded = NO;
        return;
    }

    NSURL *payload =
        [resources URLForResource:@"payload-base"
                    withExtension:@"js"];

    if (payload) {
        NSData *payloadData = [NSData dataWithContentsOfURL:payload];
        [KettuJSI evaluate:payloadData
                       tag:@"kettu:loader"
                   runtime:runtime];
    } else {
        BunnyLog(@"[KettuRuntime] payload-base.js missing");
        dispatch_async(dispatch_get_main_queue(), ^{
            showErrorAlert(@"Loader Error",
                           @"Failed to initialize mod loader. Please reinstall the tweak.", nil);
        });
    }

    NSData *bundle = downloadKettu(pyoncordDirectory);

    // Tema e fontes precisam ser aplicados ANTES de executar o bundle
    applyTheme(pyoncordDirectory, runtime);
    applyFonts(pyoncordDirectory);

    if (!bundle.length) {
        BunnyLog(@"[KettuRuntime] No Kettu bundle available");
        dispatch_async(dispatch_get_main_queue(), ^{
            showErrorAlert(
                @"Bundle Error",
                @"Failed to load bundle. Please check your internet connection and restart the app.",
                nil);
        });
        return;
    }

    [KettuJSI evaluate:bundle
                   tag:@"kettu:bundle"
               runtime:runtime];

    NSURL *preloads =
        [pyoncordDirectory URLByAppendingPathComponent:@"preloads"];

    NSArray *files =
        [[NSFileManager defaultManager]
            contentsOfDirectoryAtURL:preloads
            includingPropertiesForKeys:nil
                               options:0
                                 error:nil];

    for (NSURL *file in files) {
        if ([[file.pathExtension lowercaseString] isEqualToString:@"js"]) {
            NSData *data = [NSData dataWithContentsOfURL:file];
            if (data.length) {
                BunnyLog(@"[KettuRuntime] Executing preload JS file %@", file.absoluteString);
                [KettuJSI evaluate:data
                               tag:[@"kettu:preload:" stringByAppendingString:file.lastPathComponent]
                           runtime:runtime];
            }
        }
    }

    BunnyLog(@"[KettuRuntime] Kettu bundle executed in new-architecture runtime");
}
