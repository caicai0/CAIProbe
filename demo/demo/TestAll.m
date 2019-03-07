//
//  TestAll.m
//  demo
//
//  Created by liyufeng on 2019/2/26.
//  Copyright © 2019 liyufeng. All rights reserved.
//

#import "TestAll.h"

#import <UIKit/UIKit.h>
#include <sys/socket.h> // Per msqr
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_dl.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <sys/types.h>
#import <sys/param.h>
#import <sys/mount.h>
#import <mach/processor_info.h>
#include <sys/stat.h>
#import <mach-o/arch.h>
#import <ifaddrs.h>
#import <arpa/inet.h>


@implementation TestAll

NS_ENUM(NSInteger,valueType){
    stringType,
    stringsType,
    intType,
    uint64Type,
    structType,
    numberType
};

- (void)allInfo{
    NSDictionary * allInfo = @{@(CTL_HW):@{
                                       @(HW_MACHINE):@(intType),
                                       @(HW_MODEL):@(intType),
                                       @(HW_NCPU):@(intType),
                                       @(HW_BYTEORDER):@(intType),
                                       @(HW_PHYSMEM):@(intType),
                                       @(HW_USERMEM):@(intType),
                                       @(HW_PAGESIZE):@(intType),
                                       @(HW_DISKNAMES):@(stringsType),
                                       @(HW_DISKSTATS):@(structType),
                                       @(HW_EPOCH):@(intType),
                                       @(HW_FLOATINGPT):@(intType),
                                       @(HW_MACHINE_ARCH):@(intType),
                                       @(HW_VECTORUNIT):@(intType),
                                       @(HW_BUS_FREQ):@(intType),
                                       @(HW_CPU_FREQ):@(intType),
                                       @(HW_CACHELINE):@(intType),
                                       @(HW_L1ICACHESIZE):@(intType),
                                       @(HW_L1DCACHESIZE):@(intType),
                                       @(HW_L2SETTINGS):@(intType),
                                       @(HW_L2CACHESIZE):@(intType),
                                       @(HW_L3SETTINGS):@(intType),
                                       @(HW_L3CACHESIZE):@(intType),
                                       @(HW_TB_FREQ):@(intType),
                                       @(HW_MEMSIZE):@(uint64Type),
                                       @(HW_AVAILCPU):@(intType),
                                       @(HW_MAXID):@(numberType)
                                       }};
    for (NSNumber * key in allInfo.allKeys) {
        NSDictionary * dic = allInfo[key];
        for (NSNumber * key2 in dic.allKeys) {
            enum valueType type = [dic[key2] intValue];
            size_t size = sizeof(int);
            int results;
            int mib[2] = {[key intValue], [key2 intValue]};
            sysctl(mib, 2, &results, &size, NULL, 0);
            if (type == stringType) {
                NSString *str = [NSString stringWithCString:results encoding:NSUTF8StringEncoding];
                NSLog(@"%@",str);
            }else if(type == intType){
                int res = (NSUInteger) results;
                NSLog(@"%d",res);
            }else{
                NSLog(@"%ld",results);
            }
        }
    }
}

- (NSUInteger) getSysInfo: (uint) typeSpecifier
{
    size_t size = sizeof(int);
    int results;
    int mib[2] = {CTL_HW, typeSpecifier};
    sysctl(mib, 2, &results, &size, NULL, 0);
    return (NSUInteger) results;
}

@end
