//
//  DCLConstants.m
//  DouyinCrashLogger
//

#import "DCLConstants.h"

// 与 control 的 Version 同步，改一处必须改另一处
NSString * const DCLPluginVersion = @"1.4-5";

NSString * const DCLCrashLogsRelativeDir = @"Documents/DouyinCrashLogs";
NSUInteger const DCLMaxRetainedLogs = 20;

NSString * const DCLLastExitNormalKey = @"DCL_last_exit_normal";
NSString * const DCLLastNormalExitTimeKey = @"DCL_last_normal_exit_time";
NSString * const DCLLastLaunchTimeKey = @"DCL_last_launch_time";
NSString * const DCLLastExitWasBackgroundedKey = @"DCL_last_exit_was_backgrounded";
NSString * const DCLLastEnterBackgroundTimeKey = @"DCL_last_enter_background_time";
NSString * const DCLRuntimeLogFileName = @"plugin_runtime.log";
NSString * const DCLSnapshotLogFileName = @"latest.log";
NSString * const DCLCaptureModeFileName = @"capture_mode.txt";
NSString * const DCLCaptureModeDefaultsKey = @"DCL_capture_mode";
