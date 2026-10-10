//
//  DCLConstants.m
//  DouyinCrashLogger
//

#import "DCLConstants.h"

NSString * const DCLCrashLogsRelativeDir = @"Documents/DouyinCrashLogs";
NSUInteger const DCLMaxRetainedLogs = 20;

NSString * const DCLLastExitNormalKey = @"DCL_last_exit_normal";
NSString * const DCLLastNormalExitTimeKey = @"DCL_last_normal_exit_time";
NSString * const DCLRuntimeLogFileName = @"plugin_runtime.log";
NSUInteger const DCLMaxCrashLogBytesForUI = 32 * 1024;
NSUInteger const DCLMaxRuntimeLogTailBytes = 64 * 1024;
