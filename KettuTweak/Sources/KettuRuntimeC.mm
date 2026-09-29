#import "KettuRuntimeC.h"
#import "KettuRuntime.h"

extern "C" void KettuLoadIntoRuntimePtr(void *runtime, NSString *bundlePath, NSURL *pyoncordDir)
{
    if (!runtime) return;
    KettuLoadIntoRuntime(*static_cast<facebook::jsi::Runtime *>(runtime), bundlePath, pyoncordDir);
}
