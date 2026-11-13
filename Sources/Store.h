#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 本地 JSON 存储。默认落在 ~/Library/Application Support/Little by Little/store.json，
/// 可用环境变量 LITTLEBYLITTLE_HOME 覆盖目录（自动化测试/截图时用，避免污染真实数据）。
@interface DLStore : NSObject
+ (NSString *)directory;
+ (NSString *)path;
+ (NSDictionary *)load;
+ (NSDictionary *)mergeWidgetActions:(NSDictionary *)store;
+ (BOOL)save:(NSDictionary *)store;
@end

NS_ASSUME_NONNULL_END
