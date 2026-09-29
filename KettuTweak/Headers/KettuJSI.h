#pragma once

#import <Foundation/Foundation.h>
#import <jsi/jsi.h>

@interface KettuJSI : NSObject
+ (void)evaluate:(NSData *)data
             tag:(NSString *)tag
         runtime:(facebook::jsi::Runtime &)runtime;
@end
