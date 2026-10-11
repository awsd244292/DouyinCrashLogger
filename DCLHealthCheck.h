//
//  DCLHealthCheck.h
//  DouyinCrashLogger
//
//  触发式自动体检：证明「这个插件现在到底有没有在工作」。
//
//  为什么必须有：日志里「没有崩溃」有两种可能 —— 真的没崩，或者插件压根没跑起来。
//  没有自检，这两种情况在日志上长得一模一样，会让所有结论失去可信度。
//  体检结果本身就是证据链的一环。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, DCLHealthLevel) {
    DCLHealthLevelPass = 0,  ///< 正常
    DCLHealthLevelWarn = 1,  ///< 有问题但不致命
    DCLHealthLevelFail = 2,  ///< 失效，此插件不可信
};

@interface DCLHealthItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) DCLHealthLevel level;
@property (nonatomic, copy) NSString *evidence;   ///< 判定依据（不是结论，是支撑结论的事实）
@end

@interface DCLHealthCheck : NSObject

/// 执行一次体检。调用方应位于非主线程 / 或主线程均可（内部自行规避阻塞主线程超过阈值）。
+ (NSArray<DCLHealthItem *> *)run;

/// 体检是否整体通过（无 FAIL 项）
+ (BOOL)isHealthy;

@end

NS_ASSUME_NONNULL_END
