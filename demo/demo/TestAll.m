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
    typeInt,
    typeString
}

- (void)allInfo{
    NSDictionary * allInfo = @{@(CTL_HW):[
                                            {@(HW_MACHINE):@(string)},
                                            {@(HW_MODEL):@(string)},
                                            {@(HW_NCPU):@(NSInteger)},
                                            {@(HW_BYTEORDER):@(int)},
                                            {@(HW_PHYSMEM):@(int)},
                                            {@(HW_USERMEM):@(int)},
                                            {@(HW_PAGESIZE):@(int)},
                                            {@(HW_DISKNAMES):@(strings)},
                                            {@(HW_DISKSTATS):@(struct)},
                                            {@(HW_EPOCH):@(int)},
                                            {@(HW_FLOATINGPT):@(int)},
                                            {@(HW_MACHINE_ARCH):@(string)},
                                            {@(HW_VECTORUNIT):@(int)},
                                            {@(HW_BUS_FREQ):@(int)},
                                            {@(HW_CPU_FREQ):@(int)},
                                            {@(HW_CACHELINE):@(int)},
                                            {@(HW_L1ICACHESIZE):@(int)},
                                            {@(HW_L1DCACHESIZE):@(int)},
                                            {@(HW_L2SETTINGS):@(int)},
                                            {@(HW_L2CACHESIZE):@(int)},
                                            {@(HW_L3SETTINGS):@(int)},
                                            {@(HW_L3CACHESIZE):@(int)},
                                            {@(HW_TB_FREQ):@(int)},
                                            {@(HW_MEMSIZE):@(uint64_t)},
                                            {@(HW_AVAILCPU):@(int)},
                                            {@(HW_MAXID):@(number)}
                                          ]}
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
