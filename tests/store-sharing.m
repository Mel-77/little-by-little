#import <Foundation/Foundation.h>
#import "Store.h"
int main() { @autoreleasepool {
 NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 setenv("LITTLEBYLITTLE_HOME", dir.UTF8String, 1);
 NSDictionary *store = @{@"blocks": @[@{@"id":@"one", @"done":@NO, @"title":@"keep"}], @"habits":@[], @"version":@1, @"custom":@"preserve"};
 NSCAssert([DLStore save:store], @"save");
 NSString *actions = [dir stringByAppendingPathComponent:@"actions"];
 [[NSFileManager defaultManager] createDirectoryAtPath:actions withIntermediateDirectories:YES attributes:nil error:NULL];
 [@"{\"id\":\"one\",\"done\":true}" writeToFile:[actions stringByAppendingPathComponent:@"001.json"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
 NSDictionary *merged = [DLStore load];
 NSCAssert([merged[@"blocks"][0][@"done"] boolValue], @"completion merged");
 NSCAssert([merged[@"custom"] isEqual:@"preserve"], @"other fields preserved");
 NSCAssert([[NSFileManager defaultManager] contentsOfDirectoryAtPath:actions error:NULL].count == 0, @"ack after save");
 NSCAssert([[DLStore load] isEqual:merged], @"persisted");
 [@"{\"id\":\"one\",\"done\":false}" writeToFile:[actions stringByAppendingPathComponent:@"002.json"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
 NSCAssert(![[DLStore load][@"blocks"][0][@"done"] boolValue], @"undo");
 [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
 NSLog(@"Store tests passed");
}}
