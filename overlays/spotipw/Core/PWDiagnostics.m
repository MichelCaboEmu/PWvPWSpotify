#import "PWDiagnostics.h"
#import "PWBuildVersion.h"
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <MetricKit/MetricKit.h>
#import <math.h>

static dispatch_queue_t queue;
static NSString *directory;
static NSUncaughtExceptionHandler *previousHandler;
static void *queueKey = &queueKey;
static NSString *path(NSString *name) { return [directory stringByAppendingPathComponent:name]; }
static void diagnosticSync(dispatch_block_t block) {
    if (dispatch_get_specific(queueKey)) block(); else dispatch_sync(queue, block);
}
static void writeEvent(NSString *category, NSString *code, NSInteger status, NSDictionary *details) {
    NSString *file = path(@"events.jsonl");
    unsigned long long size = [[NSFileManager.defaultManager attributesOfItemAtPath:file error:nil] fileSize];
    if (size > 512 * 1024) {
        [NSFileManager.defaultManager removeItemAtPath:path(@"previous.jsonl") error:nil];
        [NSFileManager.defaultManager moveItemAtPath:file toPath:path(@"previous.jsonl") error:nil];
    }
    NSMutableDictionary *event = [@{@"time": @([NSDate.date timeIntervalSince1970]), @"category":category,
                            @"event":code, @"status":@(status)} mutableCopy];
    if (details.count) event[@"details"] = details;
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:event options:0 error:nil] mutableCopy];
    [data appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    if (![NSFileManager.defaultManager fileExistsAtPath:file]) [NSData.data writeToFile:file atomically:YES];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:file];
    @try { [handle seekToEndOfFile]; [handle writeData:data]; [handle closeFile]; }
    @catch (NSException *exception) { /* Logging must never crash playback. */ }
}
void PWEvent(NSString *category, NSString *code, NSInteger status) {
    PWEventDetails(category, code, status, nil);
}
void PWEventDetails(NSString *category, NSString *code, NSInteger status, NSDictionary *details) {
    if (!queue) return;
    // Only bounded scalar fields reach the JSON writer. Never serialize arbitrary objects.
    NSMutableDictionary *safe = [NSMutableDictionary dictionary];
    for (id key in details) {
        if (safe.count >= 40) break;
        if (![key isKindOfClass:NSString.class] || [key length] > 64) continue;
        id value = details[key];
        if ([value isKindOfClass:NSString.class]) safe[key] = [value substringWithRange:[value rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, MIN([value length], 800u))]];
        else if ([value isKindOfClass:NSNumber.class] && isfinite([value doubleValue])) safe[key] = value;
    }
    NSDictionary *snapshot = [safe copy];
    dispatch_async(queue, ^{ writeEvent(category, code, status, snapshot); });
}
static void uncaught(NSException *exception) {
    // No exception reason: it can contain URLs, account details or response bodies.
    NSDictionary *report = @{@"event":@"uncaught_exception", @"build":@PW_BUILD_SHA,
        @"addresses": exception.callStackReturnAddresses ?: @[]};
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:path(@"exception.json") atomically:YES];
    if (previousHandler) previousHandler(exception);
}
NSString *PWDiagnosticSnapshot(void) {
    if (!queue) return @"Diagnostics unavailable";
    __block NSMutableString *result;
    diagnosticSync(^{
        NSDictionary *bundle = NSBundle.mainBundle.infoDictionary;
        result = [NSMutableString stringWithFormat:@"PWvPWSpotify diagnostics\nDiagnostics schema: 2\nBuild: %s\nSpotify: %@ (%@)\niOS: %@\nLow power: %d\nReduce motion: %d\n\n",
            PW_BUILD_SHA, bundle[@"CFBundleShortVersionString"], bundle[@"CFBundleVersion"],
            UIDevice.currentDevice.systemVersion, NSProcessInfo.processInfo.lowPowerModeEnabled,
            UIAccessibilityIsReduceMotionEnabled()];
        for (NSString *name in @[@"previous.jsonl", @"events.jsonl", @"exception.json", @"metric-crash.json"]) {
            NSString *content = [NSString stringWithContentsOfFile:path(name) encoding:NSUTF8StringEncoding error:nil];
            if (content) [result appendFormat:@"--- %@ ---\n%@\n", name, content];
        }
    });
    return result;
}
void PWClearDiagnostics(void) {
    if (!queue) return;
    diagnosticSync(^{ for (NSString *name in @[@"previous.jsonl", @"events.jsonl", @"exception.json", @"metric-crash.json"])
        [NSFileManager.defaultManager removeItemAtPath:path(name) error:nil]; });
    PWEvent(@"diagnostics", @"cleared", 0);
}
static NSMutableDictionary *secretQuery(NSString *name) {
    return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService:@"PWvPWSpotify.providers",
              (__bridge id)kSecAttrAccount:name} mutableCopy];
}
NSString *PWSecret(NSString *name) {
    NSMutableDictionary *query = secretQuery(name);
    query[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) return nil;
    return [[NSString alloc] initWithData:CFBridgingRelease(result) encoding:NSUTF8StringEncoding];
}
BOOL PWSetSecret(NSString *name, NSString *value) {
    NSMutableDictionary *query = secretQuery(name);
    if (!value.length) { OSStatus s = SecItemDelete((__bridge CFDictionaryRef)query); return s == errSecSuccess || s == errSecItemNotFound; }
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *attributes = @{(__bridge id)kSecValueData:data,
        (__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        [query addEntriesFromDictionary:attributes]; status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    }
    PWEvent(@"credentials", @"save_status", status);
    return status == errSecSuccess;
}
@interface PWMetricSubscriber : NSObject <MXMetricManagerSubscriber>
@end
@implementation PWMetricSubscriber
- (void)didReceiveDiagnosticPayloads:(NSArray<MXDiagnosticPayload *> *)payloads {
    for (MXDiagnosticPayload *payload in payloads) {
        if (!payload.crashDiagnostics.count) continue;
        NSData *data = payload.JSONRepresentation;
        if (data.length > 512 * 1024) { PWEvent(@"crash", @"metric_report_too_large", 0); continue; }
        dispatch_async(queue, ^{ [data writeToFile:path(@"metric-crash.json") atomically:YES]; });
        PWEvent(@"crash", @"metrickit_received", payload.crashDiagnostics.count);
    }
}
@end
static PWMetricSubscriber *subscriber;
__attribute__((constructor)) static void setupDiagnostics(void) {
    queue = dispatch_queue_create("pw.diagnostics", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(queue, queueKey, queueKey, NULL);
    directory = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"PWDiagnostics"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
        attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
    [[NSURL fileURLWithPath:directory] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    previousHandler = NSGetUncaughtExceptionHandler(); NSSetUncaughtExceptionHandler(uncaught);
    PWEvent(@"app", @"launch", 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        subscriber = [PWMetricSubscriber new]; [MXMetricManager.sharedManager addSubscriber:subscriber];
        for (NSString *name in @[UIApplicationDidBecomeActiveNotification, UIApplicationDidEnterBackgroundNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                PWEvent(@"app", [note.name isEqualToString:UIApplicationDidBecomeActiveNotification] ? @"foreground" : @"background", 0);
            }];
        }
    });
}
