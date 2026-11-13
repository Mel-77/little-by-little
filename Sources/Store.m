#import "Store.h"

@implementation DLStore

+ (NSString *)directory {
    NSString *env = NSProcessInfo.processInfo.environment[@"LITTLEBYLITTLE_HOME"];
    if (env.length > 0) return env;
    return [@"~/Library/Application Support/Little by Little" stringByExpandingTildeInPath];
}

+ (NSString *)path {
    return [[self directory] stringByAppendingPathComponent:@"store.json"];
}

// Share only the widget snapshot and its commands through the signed App Group.
// The primary store stays at the old path: upgrades never replace the user's data.
+ (NSString *)sharedPath {
    NSString *env = NSProcessInfo.processInfo.environment[@"LITTLEBYLITTLE_HOME"];
    if (env.length > 0) return [env stringByAppendingPathComponent:@"store.json"];
    NSString *group = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"LBLAppGroup"];
    if (!group.length) return nil;
    NSURL *container = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:group];
    return [[container URLByAppendingPathComponent:@"store.json"] path];
}

+ (NSDictionary *)load {
    NSString *p = [self path];
    NSData *data = [NSData dataWithContentsOfFile:p];
    NSMutableDictionary *store = [NSMutableDictionary dictionary];
    if (data.length > 0) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([obj isKindOfClass:[NSDictionary class]]) [store addEntriesFromDictionary:obj];
    }
    if (![store[@"blocks"] isKindOfClass:[NSArray class]]) store[@"blocks"] = @[];
    if (![store[@"habits"] isKindOfClass:[NSArray class]]) store[@"habits"] = @[];
    if (!store[@"version"]) store[@"version"] = @1;
    return [self mergeWidgetActions:store];
}

// Each widget tap is an atomic, independent command; never copy a stale snapshot back.
+ (NSDictionary *)mergeWidgetActions:(NSDictionary *)store {
    NSString *dir = [[[self sharedPath] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"actions"];
    NSArray *files = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL] sortedArrayUsingSelector:@selector(compare:)];
    if (!files.count) return store;
    NSMutableDictionary *merged = [store mutableCopy];
    NSMutableArray *blocks = [NSMutableArray array];
    for (NSDictionary *b in store[@"blocks"]) [blocks addObject:[b mutableCopy]];
    for (NSString *name in files) {
        NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name]];
        NSDictionary *action = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (![action isKindOfClass:[NSDictionary class]]) continue;
        NSMutableArray *hit = [NSMutableArray array];
        for (NSMutableDictionary *b in blocks) {
            if ([b[@"id"] isEqual:action[@"id"]] && [action[@"done"] isKindOfClass:[NSNumber class]]) {
                b[@"done"] = action[@"done"];
                [hit addObject:(b[@"title"] ?: @"?")];
            }
        }
        [self traceAction:name action:action hits:hit];
    }
    merged[@"blocks"] = blocks;
    if ([self save:merged]) {
        for (NSString *name in files)
            [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:name] error:NULL];
    }
    return merged;
}

+ (BOOL)save:(NSDictionary *)store {
    if (![store isKindOfClass:[NSDictionary class]]) return NO;
    NSError *err = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:[self directory]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&err];
    NSData *data = [NSJSONSerialization dataWithJSONObject:store
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (!data) return NO;
    BOOL ok = [data writeToFile:[self path] atomically:YES];
    // 镜像一份给桌面小组件；失败不影响主流程
    NSString *shared = [self sharedPath];
    if (shared.length) {
        NSString *dir = [shared stringByDeletingLastPathComponent];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:NULL];
        }
        BOOL mirrored = [data writeToFile:shared atomically:YES];
        ok = ok && mirrored;
    }
    return ok && shared.length > 0;
}


// 小组件点一下到底改到了谁：留一行现场记录，出问题时能对着看
+ (void)traceAction:(NSString *)name action:(NSDictionary *)action hits:(NSArray *)hits {
    NSString *dir = [[self directory] stringByAppendingPathComponent:@"log"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *line = [NSString stringWithFormat:@"%@ id=%@ done=%@ 命中=%lu %@\n",
                      [NSDate date], action[@"id"] ?: @"?", action[@"done"] ?: @"?",
                      (unsigned long)hits.count, [hits componentsJoinedByString:@","]];
    NSString *file = [dir stringByAppendingPathComponent:@"widget-merge.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:file];
    if (!fh) {
        [line writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

@end
