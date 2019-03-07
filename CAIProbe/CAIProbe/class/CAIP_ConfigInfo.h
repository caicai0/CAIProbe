//
//  CAIP_ConfigInfo.h
//  CAIProbe
//
//  Created by liyufeng on 2019/3/7.
//  Copyright © 2019 liyufeng. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CAIP_ConfigInfo : NSObject

@property(nonatomic,strong)NSString *serverUrl;//服务器路径
@property(nonatomic,assign)NSInteger uploadInterval;//上传的时间间隔
@property(nonatomic,assign)NSInteger maxLogCount;//最大的上传条数
@property(nonatomic,strong)NSDictionary *baseInfo;//基本信息 有更新才上传

@end

NS_ASSUME_NONNULL_END
