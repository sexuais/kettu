#pragma once

#import <Foundation/Foundation.h>
#import <jsi/jsi.h>

void KettuLoadIntoRuntime(facebook::jsi::Runtime &runtime,
                          NSString *resourcesBundlePath,
                          NSURL *pyoncordDirectory);
