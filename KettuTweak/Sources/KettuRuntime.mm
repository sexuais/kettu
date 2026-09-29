#import "KettuRuntime.h"
#import "KettuJSI.h"
#import "LoaderConfig.h"
#import "Logger.h"
#import "Utils.h"

using namespace facebook;

static NSData *downloadKettu(NSURL *directory) {
    LoaderConfig *config = [[LoaderConfig alloc] init];
    [config loadConfig];

    NSURL *url = nil;
    if (config.customLoadUrlEnabled && config.customLoadUrl) {
        url = config.customLoadUrl;
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
                            timeoutInterval:5.0];

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
            } else if (http.statusCode == 304 && old.length) {
                result = old;
            }
        }

        if (error) {
            BunnyLog(@"[KettuRuntime] download error: %@", error.localizedDescription);
        }

        dispatch_semaphore_signal(sem);
    }] resume];

    dispatch_semaphore_wait(
        sem,
        dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC));

    if (result) {
        [result writeToURL:cached atomically:YES];
        if (newEtag) {
            [newEtag writeToURL:
                [directory URLByAppendingPathComponent:@"etag.txt"]
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:nil];
        }
    }

    return result ?: old;
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
    }

    NSData *bundle = downloadKettu(pyoncordDirectory);

    if (!bundle.length) {
        BunnyLog(@"[KettuRuntime] No Kettu bundle available");
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
                [KettuJSI evaluate:data
                               tag:[@"kettu:preload:" stringByAppendingString:file.lastPathComponent]
                           runtime:runtime];
            }
        }
    }

    BunnyLog(@"[KettuRuntime] Kettu bundle executed in new-architecture runtime");
}
