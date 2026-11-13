#import "AppDelegate.h"
#import "Store.h"
#include <sys/sysctl.h>
#import <Carbon/Carbon.h>
#import <WebKit/WebKit.h>

// WidgetReload.swift 里导出的 C 函数：让桌面小组件立刻重画
extern void DLReloadWidgetTimelines(void);

#pragma mark - helpers

static NSString *DLJSJSON(id object) {
    if (!object) return @"null";
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    if (!data) return @"null";
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    // 防止脚本内容里出现 </script> 之类把注入截断
    return [s stringByReplacingOccurrencesOfString:@"</" withString:@"<\\/"];
}

static NSColor *DLPaperColor(void) {
    return [NSColor colorWithSRGBRed:0.984 green:0.965 blue:0.925 alpha:1.0];
}

static NSString *DLLocalDateString(NSDate *date) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"yyyy-MM-dd";
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [fmt stringFromDate:date];
}

@interface DLFirstMouseWebView : WKWebView
@end

/// 不激活应用的面板：主窗口在前台时，第一下点卡片也要真的点到，
/// 不能只把应用「激活一下」就把点击吞掉。
@interface DLPanel : NSPanel
@end

@implementation DLPanel
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)canBecomeKeyWindow { return NO; }
@end

@implementation DLFirstMouseWebView
// 挂件是「不激活应用」的面板，第一次点击也要能点中
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
@end

#pragma mark - AppDelegate

@interface AppDelegate () <WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, strong) NSWindow *mainWindow;
@property (nonatomic, strong) NSMenu *statusMenu;
@property (nonatomic, strong) NSPanel *popoverPanel;
@property (nonatomic, strong) WKWebView *popoverWeb;
@property (nonatomic, strong) id popoverClickMonitor;
@property (nonatomic, strong) id popoverGlobalMonitor;
@property (nonatomic, strong) WKWebView *mainWeb;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSDictionary *store;
/// 截图模式：不建真实窗口，只渲染一个页面存成 PNG（自动化验证用）
@property (nonatomic, assign) BOOL snapshotMode;
@property (nonatomic, copy) NSString *snapshotPath;
@property (nonatomic, copy) NSString *snapshotPage;
@property (nonatomic, assign) NSSize snapshotSize;
@property (nonatomic, copy) NSString *argDate;
@property (nonatomic, copy) NSString *argNow;
@property (nonatomic, copy) NSString *storeArgumentPath;
@property (nonatomic, copy) NSString *evalScript;
/// 只做小组件自检（--check-widget），不建窗口
@property (nonatomic, assign) BOOL checkMode;
/// 用户选择「先这样用」：不登记小组件，免得留下一条指向临时磁盘的坏记录
@property (nonatomic, assign) BOOL skipWidgetSetup;
@end

/// 连续保存时只发一次刷新请求（拖动结束、改名、打勾都会保存）
static NSInteger DLReloadGeneration = 0;

@implementation AppDelegate

#pragma mark 启动

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self parseArguments];

    if (self.checkMode) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSMutableString *report = [[self widgetDiagnostics] mutableCopy];
        [report appendString:@"\n—— 修复 ——\n"];
        [report appendString:[self repairWidgetRegistration]];
        fputs(report.UTF8String, stdout);
        fflush(stdout);
        exit(0);
    }

    self.store = [self loadStoreFromArgumentIfNeeded];

    // 直接从 DMG（/Volumes/…）或系统临时位置（AppTranslocation）运行时，小组件会登记在
    // 那个随时会消失的路径上：DMG 一退、重启一次，组件库里就找不到了。
    // 与其让用户自己猜，不如在这里帮他装好。
    if (!self.snapshotMode && [self handleImproperInstallIfNeeded]) return;

    // 顺手把镜像写给桌面小组件（它跑在沙盒里，只能读容器里的副本）
    if (!self.snapshotMode) {
        [DLStore save:self.store];
        [self scheduleWidgetReload];
        [self stripQuarantine];
        if (!self.skipWidgetSetup) [self registerWidgetExtensionIfNeeded];
    }

    if (self.snapshotMode) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [self runSnapshot];
        return;
    }

    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        NSDictionary *merged = [DLStore mergeWidgetActions:self.store];
        if (![merged isEqual:self.store]) [self handleSave:merged from:@"widget-action"];
    }];
    [self buildMainMenu];
    [self buildStatusItem];
    [self installGlobalHotKey];
    [self buildMainWindow];

    [self observeWindowFrames];
    [NSApp activateIgnoringOtherApps:YES];
    [self.mainWindow makeKeyAndOrderFront:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self reportStatusItemPlacement];
    });

    // 自测用：--show-popover 直接把菜单栏卡片弹出来
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--show-popover"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self togglePopover];
        });
    }
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO; // 关掉主窗口后仍留在菜单栏
}

// 点桌面小组件时来的 littlebylittle://today —— 打开主窗口并跳回今天
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    BOOL today = NO;
    for (NSURL *url in urls) {
        if ([[url.scheme lowercaseString] isEqualToString:@"littlebylittle"]) today = YES;
    }
    [self showMainWindow:nil];
    if (today) {
        [self.mainWeb evaluateJavaScript:@"window.Little && window.Little.today()" completionHandler:nil];
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self.mainWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    return YES;
}

#pragma mark 参数

- (void)parseArguments {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    for (NSUInteger i = 0; i < args.count; i++) {
        NSString *a = args[i];
        NSString *next = (i + 1 < args.count) ? args[i + 1] : nil;
        if ([a isEqualToString:@"--snapshot"]) {
            self.snapshotMode = YES;
            if (next) { self.snapshotPath = next; i++; }
        } else if ([a isEqualToString:@"--page"]) {
            if (next) { self.snapshotPage = next; i++; }
        } else if ([a isEqualToString:@"--size"]) {
            if (next) {
                NSArray *wh = [next componentsSeparatedByString:@"x"];
                if (wh.count == 2) self.snapshotSize = NSMakeSize([wh[0] doubleValue], [wh[1] doubleValue]);
                i++;
            }
        } else if ([a isEqualToString:@"--date"]) {
            if (next) { self.argDate = next; i++; }
        } else if ([a isEqualToString:@"--now"]) {
            if (next) { self.argNow = next; i++; }
        } else if ([a isEqualToString:@"--store"]) {
            if (next) { self.storeArgumentPath = next; i++; }
        } else if ([a isEqualToString:@"--eval"]) {
            if (next) { self.evalScript = next; i++; }
        } else if ([a isEqualToString:@"--check-widget"]) {
            self.checkMode = YES;
        }
    }
    if (self.snapshotSize.width < 100) self.snapshotSize = NSMakeSize(1100, 780);
    if (!self.snapshotPage) self.snapshotPage = @"main";
}

- (NSDictionary *)loadStoreFromArgumentIfNeeded {
    if (self.storeArgumentPath.length > 0) {
        NSData *d = [NSData dataWithContentsOfFile:self.storeArgumentPath];
        if (d) {
            id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
            if ([o isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *m = [o mutableCopy];
                if (!m[@"blocks"]) m[@"blocks"] = @[];
                if (!m[@"habits"]) m[@"habits"] = @[];
                return m;
            }
        }
    }
    return [DLStore load];
}

#pragma mark 菜单栏图标

// 菜单栏太挤时（这台笔记本的刘海在 x 646–825），新图标会被系统塞到刘海底下而看不见，
// 所以再留一个全局热键：⌃⌥L 直接弹/收今日卡片。
static EventHotKeyRef DLHotKeyRef = NULL;

static OSStatus DLHotKeyHandler(EventHandlerCallRef nextRef, EventRef event, void *userData) {
    [(__bridge AppDelegate *)userData performSelectorOnMainThread:@selector(togglePopover)
                                                       withObject:nil
                                                    waitUntilDone:NO];
    return noErr;
}

- (void)installGlobalHotKey {
    EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallApplicationEventHandler(NewEventHandlerUPP(DLHotKeyHandler), 1, &spec, (__bridge void *)self, NULL);

    EventHotKeyID kid;
    kid.signature = 'DLhk';
    kid.id = 1;
    OSStatus st = RegisterEventHotKey(kVK_ANSI_L, controlKey | optionKey, kid,
                                      GetApplicationEventTarget(), 0, &DLHotKeyRef);
    NSLog(@"hotkey ⌃⌥L -> %@", st == noErr ? @"ok" : [NSString stringWithFormat:@"err %d", (int)st]);
}

- (void)reportStatusItemPlacement {
    NSWindow *bw = self.statusItem.button.window;
    NSRect f = bw.frame;
    CGFloat notchLeft = 0, notchRight = 0;
    if (@available(macOS 12.0, *)) {
        NSScreen *sc = bw.screen ?: [NSScreen mainScreen];
        if (sc.safeAreaInsets.top > 0) {
            notchLeft = NSMaxX(sc.auxiliaryTopLeftArea);
            notchRight = NSMinX(sc.auxiliaryTopRightArea);
        }
    }
    BOOL underNotch = notchRight > notchLeft && NSMidX(f) > notchLeft && NSMidX(f) < notchRight;
    NSLog(@"status item @%.0f (刘海 %.0f–%.0f) %@", NSMinX(f), notchLeft, notchRight,
          underNotch ? @"被挡住，用 ⌃⌥L" : @"正常显示");
}

- (void)buildStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *img = [NSImage imageWithSystemSymbolName:@"checklist" accessibilityDescription:@"Little by Little"];
    img.template = YES;
    self.statusItem.button.image = img;
    self.statusItem.button.toolTip = @"Little by Little · 今天";

    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"打开 Little by Little" action:@selector(showMainWindow:) keyEquivalent:@"o"];
    open.target = self;
    [menu addItem:open];

    NSMenuItem *card = [[NSMenuItem alloc] initWithTitle:@"今日卡片" action:@selector(togglePopover) keyEquivalent:@""];
    card.target = self;
    [menu addItem:card];

    NSMenuItem *login = [[NSMenuItem alloc] initWithTitle:@"开机自动打开" action:@selector(toggleLaunchAtLogin:) keyEquivalent:@""];
    login.target = self;
    login.state = [self launchAtLoginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:login];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出 Little by Little" action:@selector(terminate:) keyEquivalent:@"q"];
    [menu addItem:quit];

    self.statusMenu = menu;
    // 左键点图标弹卡片，右键（或按住 Control 点）弹菜单
    self.statusItem.menu = nil;
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusItemClicked:);
    [self refreshStatusMenu];
}

- (void)refreshStatusMenu {
    NSMenu *menu = self.statusMenu;
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action == @selector(toggleLaunchAtLogin:)) {
            item.state = [self launchAtLoginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
}

#pragma mark 菜单栏卡片

- (void)statusItemClicked:(id)sender {
    NSEvent *e = NSApp.currentEvent;
    BOOL wantsMenu = (e.type == NSEventTypeRightMouseUp) ||
                     (e.modifierFlags & NSEventModifierFlagControl) ||
                     (e.modifierFlags & NSEventModifierFlagOption);
    if (wantsMenu) {
        [self.statusItem popUpStatusItemMenu:self.statusMenu];
        return;
    }
    [self togglePopover];
}

- (void)togglePopover {
    if (!self.popoverPanel) [self buildPopoverPanel];
    if (self.popoverPanel.isVisible) {
        [self closePopover];
        return;
    }
    [self positionPopover];
    if (self.store) {
        NSString *js = [NSString stringWithFormat:@"window.Little && window.Little.applyStore(%@);", DLJSJSON(self.store)];
        [self.popoverWeb evaluateJavaScript:js completionHandler:nil];
    }
    [self.popoverPanel orderFrontRegardless];
    NSLog(@"popover: visible=%d frame=%@", self.popoverPanel.isVisible, NSStringFromRect(self.popoverPanel.frame));

    if (!self.popoverClickMonitor) {
        __weak typeof(self) weakSelf = self;
        self.popoverClickMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown)
                                                                        handler:^NSEvent *(NSEvent *ev) {
            __strong typeof(self) self2 = weakSelf;
            if (!self2) return ev;
            if (ev.window == self2.popoverPanel) return ev;
            if (ev.window == self2.statusItem.button.window) return ev;
            [self2 closePopover];
            return ev;
        }];
    }
    if (!self.popoverGlobalMonitor) {
        __weak typeof(self) weakSelf = self;
        // 全局监听：点到别的 App 上也要收起（local monitor 看不到别人的点击）
        self.popoverGlobalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown)
                                                                         handler:^(NSEvent *ev) {
            __strong typeof(self) self2 = weakSelf;
            [self2 closePopover];
        }];
    }
}

- (void)closePopover {
    [self.popoverPanel orderOut:nil];
    if (self.popoverClickMonitor) {
        [NSEvent removeMonitor:self.popoverClickMonitor];
        self.popoverClickMonitor = nil;
    }
    if (self.popoverGlobalMonitor) {
        [NSEvent removeMonitor:self.popoverGlobalMonitor];
        self.popoverGlobalMonitor = nil;
    }
}

- (void)buildPopoverPanel {
    // 初始高度随意，页面画完会自己报一次真实高度
    CGFloat h = 400;
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 336, h)
                                                styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    panel.opaque = NO;
    panel.backgroundColor = [NSColor clearColor];
    panel.hasShadow = YES;
    panel.alphaValue = 1.0;
    panel.level = NSStatusWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorIgnoresCycle;
    panel.hidesOnDeactivate = NO;
    panel.releasedWhenClosed = NO;

    WKWebView *web = [self makeWebView:@"widget" frame:panel.contentView.bounds];
    web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [panel.contentView addSubview:web];

    self.popoverWeb = web;
    self.popoverPanel = panel;
}

- (void)positionPopover {
    NSStatusBarButton *button = self.statusItem.button;
    if (!button || !button.window) return;
    // 注意：button.window 是整条菜单栏，不是图标本身，必须把按钮的 frame 换算到屏幕坐标
    NSRect inWindow = [button convertRect:button.bounds toView:nil];
    NSRect b = [button.window convertRectToScreen:inWindow];
    NSPanel *panel = self.popoverPanel;
    CGFloat w = NSWidth(panel.frame), h = NSHeight(panel.frame);
    NSScreen *screen = button.window.screen ?: NSScreen.mainScreen;
    NSRect vis = screen.visibleFrame;
    CGFloat x = NSMidX(b) - w / 2.0;
    x = MAX(NSMinX(vis) + 8, MIN(x, NSMaxX(vis) - w - 8));
    CGFloat y = NSMinY(b) - h - 4;
    [panel setFrameOrigin:NSMakePoint(round(x), round(y))];
}

- (void)applicationDidResignActive:(NSNotification *)note {
    [self closePopover];
}

#pragma mark 主窗口

- (void)buildMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"关于 Little by Little" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"隐藏 Little by Little" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"隐藏其他" action:@selector(hideOtherApplications:) keyEquivalent:@"h"].keyEquivalentModifierMask =
        NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"退出 Little by Little" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [mainMenu addItem:appItem];

    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    [editMenu addItemWithTitle:@"撤销" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"重做" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"拷贝" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;
    [mainMenu addItem:editItem];

    NSMenuItem *viewItem = [[NSMenuItem alloc] init];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"查看"];
    [viewMenu addItemWithTitle:@"回到今天" action:@selector(goToday:) keyEquivalent:@"t"];
    [viewMenu addItemWithTitle:@"前一天" action:@selector(goPrevDay:) keyEquivalent:@"["];
    [viewMenu addItemWithTitle:@"后一天" action:@selector(goNextDay:) keyEquivalent:@"]"];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [viewMenu addItemWithTitle:@"总结" action:@selector(showSummary:) keyEquivalent:@"e"];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [viewMenu addItemWithTitle:@"今日卡片" action:@selector(togglePopover) keyEquivalent:@"1"];
    viewItem.submenu = viewMenu;
    [mainMenu addItem:viewItem];

    NSMenuItem *helpWidget = [[NSMenuItem alloc] init];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"小组件"];
    NSMenuItem *check = [[NSMenuItem alloc] initWithTitle:@"检查小组件…" action:@selector(checkWidget:) keyEquivalent:@""];
    check.target = self;
    [helpMenu addItem:check];
    NSMenuItem *repair = [[NSMenuItem alloc] initWithTitle:@"重新登记小组件" action:@selector(repairWidget:) keyEquivalent:@""];
    repair.target = self;
    [helpMenu addItem:repair];
    helpWidget.submenu = helpMenu;
    [mainMenu addItem:helpWidget];

    NSMenuItem *winItem = [[NSMenuItem alloc] init];
    NSMenu *winMenu = [[NSMenu alloc] initWithTitle:@"窗口"];
    NSMenuItem *min = [[NSMenuItem alloc] initWithTitle:@"最小化" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    min.target = nil;
    [winMenu addItem:min];
    [winMenu addItemWithTitle:@"关闭" action:@selector(performClose:) keyEquivalent:@"w"];
    winItem.submenu = winMenu;
    [mainMenu addItem:winItem];

    NSApp.mainMenu = mainMenu;
}

- (void)buildMainWindow {
    NSRect frame = NSMakeRect(0, 0, 700, 820);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                              NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    win.title = @"Little by Little";
    win.titleVisibility = NSWindowTitleHidden;
    win.titlebarAppearsTransparent = YES;
    win.backgroundColor = DLPaperColor();
    win.minSize = NSMakeSize(620, 560);
    win.releasedWhenClosed = NO;
    // 位置只认我们自己存的那份，别让系统的窗口恢复（NSWindow state restoration）再插手
    win.restorable = NO;
    [win center];
    // 没有存过位置时，用「居中」后的位置当默认值
    [self restoreFrameForWindow:win key:@"mainFrame" defaultFrame:win.frame];

    WKWebView *web = [self makeWebView:@"main" frame:win.contentView.bounds];
    web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [win.contentView addSubview:web];

    self.mainWeb = web;
    self.mainWindow = win;
}


#pragma mark 装到正确的位置

/// 直接在安装包里运行（/Volumes/…）或被系统关进临时目录（AppTranslocation）时返回 YES。
/// 这两种情况下小组件登记在随时会消失的路径上，DMG 一退就找不到了。
- (BOOL)isImproperInstallLocation {
    NSString *path = NSBundle.mainBundle.bundlePath;
    return [path hasPrefix:@"/Volumes/"] || [path containsString:@"AppTranslocation"];
}

- (NSString *)copySelfToApplications {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *src = NSBundle.mainBundle.bundlePath;
    NSArray<NSString *> *dirs = @[ @"/Applications",
                                   [@"~/Applications" stringByExpandingTildeInPath] ];
    for (NSString *dir in dirs) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *dest = [dir stringByAppendingPathComponent:src.lastPathComponent];
        if ([dest isEqualToString:src]) return dest;
        [self runTool:@"/bin/rm" args:@[@"-rf", dest]];
        NSString *err = [self runTool:@"/usr/bin/ditto" args:@[src, dest]];
        if ([fm fileExistsAtPath:dest] && err.length == 0) {
            [self runTool:@"/usr/bin/xattr" args:@[@"-dr", @"com.apple.quarantine", dest]];
            NSLog(@"lbl: 已复制到 %@", dest);
            return dest;
        }
        NSLog(@"lbl: 复制到 %@ 失败：%@", dest, err);
    }
    return nil;
}

/// 运行位置不对时先问一句；用户同意就搬到「应用程序」并重新打开。
/// 返回 YES 表示已经处理完（调用方直接 return）。
- (BOOL)handleImproperInstallIfNeeded {
    if (![self isImproperInstallLocation]) return NO;
    NSString *path = NSBundle.mainBundle.bundlePath;
    BOOL fromVolume = [path hasPrefix:@"/Volumes/"];
    NSLog(@"lbl: 运行位置不对 %@（%@）", path, fromVolume ? @"安装包里" : @"临时目录");

    // 自动化验证用的后门：跳过弹窗直接装
    BOOL autoFix = [NSProcessInfo.processInfo.arguments containsObject:@"--install-here"];

    if (!autoFix) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"先装进「应用程序」再用";
        alert.informativeText = fromVolume
            ? @"现在是从安装包里直接运行的。小组件会登记在这块临时磁盘上，"
              @"把安装包退出（或者重启）之后就找不到了。\n\n"
              @"点「帮我装好」，我把它复制到「应用程序」再重新打开，日程一条都不会少。"
            : @"现在是从系统的临时位置运行的，小组件没法登记，日程也可能存不长久。\n\n"
              @"点「帮我装好」，我把它复制到「应用程序」再重新打开。";
        [alert addButtonWithTitle:@"帮我装好"];
        [alert addButtonWithTitle:@"先这样用"];
        if ([alert runModal] != NSAlertFirstButtonReturn) {
            self.skipWidgetSetup = YES;
            if (!fromVolume) {
                [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[NSBundle.mainBundle.bundleURL]];
                [NSApp terminate:nil];
            }
            return NO;
        }
    }

    NSString *dest = [self copySelfToApplications];
    if (!dest) {
        NSAlert *fail = [[NSAlert alloc] init];
        fail.messageText = @"没能复制到「应用程序」";
        fail.informativeText = @"可以手动把 Little by Little 拖进「应用程序」文件夹，再从那里打开。";
        [fail addButtonWithTitle:@"好"];
        [fail runModal];
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[NSBundle.mainBundle.bundleURL]];
        [NSApp terminate:nil];
        return YES;
    }

    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    cfg.createsNewApplicationInstance = YES;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL fileURLWithPath:dest]
                                         configuration:cfg
                                     completionHandler:nil];
    [NSApp terminate:nil];
    return YES;
}

#pragma mark 小组件自检

- (NSString *)runTool:(NSString *)path args:(NSArray<NSString *> *)args {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = path;
    task.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    @try { [task launch]; } @catch (NSException *e) { return @""; }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

- (NSString *)machineName {
    char buf[64] = {0};
    size_t len = sizeof(buf);
    if (sysctlbyname("hw.machine", buf, &len, NULL, 0) != 0) return @"?";
    return [NSString stringWithUTF8String:buf];
}

- (NSString *)widgetAppexPath {
    return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/PlugIns/LittleByLittleWidget.appex"];
}

/// 把「小组件为什么不出现」需要看的全部证据收集成一段文字。
- (NSString *)widgetDiagnostics {
    NSMutableString *s = [NSMutableString string];
    NSProcessInfo *pi = NSProcessInfo.processInfo;
    NSOperatingSystemVersion v = pi.operatingSystemVersion;
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSFileManager *fm = NSFileManager.defaultManager;

    [s appendString:@"Little by Little · 桌面小组件自检\n"];
    [s appendString:@"（把整段文字发回来，就能判断问题出在哪一步）\n\n"];

    [s appendFormat:@"系统版本      macOS %ld.%ld.%ld\n", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];
    [s appendFormat:@"芯片          %@\n", [self machineName]];
    [s appendFormat:@"App 位置      %@\n", bundlePath];
    [s appendFormat:@"App 版本      %@ (build %@)\n", info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]];
    if (v.majorVersion < 14) {
        [s appendString:@"结论①         系统低于 macOS 14，桌面小组件在这台机器上不存在。\n"];
    } else {
        [s appendString:@"结论①         系统支持桌面小组件（需要 macOS 14 以上）。\n"];
    }

    BOOL translocated = [bundlePath containsString:@"AppTranslocation"];
    [s appendFormat:@"App Translocation  %@\n", translocated
        ? @"是 ← 直接在 DMG 或下载目录里运行了，必须拖进「应用程序」再打开"
        : @"否"];
    NSString *quarantine = [[self runTool:@"/usr/bin/xattr" args:@[@"-p", @"com.apple.quarantine", bundlePath]]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [s appendFormat:@"隔离属性      %@\n", quarantine.length ? quarantine : @"无"];

    NSString *appex = [self widgetAppexPath];
    BOOL hasAppex = [fm fileExistsAtPath:appex];
    [s appendFormat:@"\n小组件包      %@\n", hasAppex ? appex : @"（缺失：这个安装包被我漏打了，属于严重问题）"];

    if (hasAppex) {
        NSDictionary *axInfo = [NSDictionary dictionaryWithContentsOfFile:[appex stringByAppendingPathComponent:@"Contents/Info.plist"]];
        [s appendFormat:@"小组件版本    %@ (build %@)\n", axInfo[@"CFBundleShortVersionString"], axInfo[@"CFBundleVersion"]];
        [s appendFormat:@"扩展类型      %@\n", axInfo[@"NSExtension"][@"NSExtensionPointIdentifier"] ?: @"（缺 NSExtensionPointIdentifier）"];
        NSString *sign = [self runTool:@"/usr/bin/codesign" args:@[@"-dvv", appex]];
        NSMutableArray *lines = [NSMutableArray array];
        for (NSString *line in [sign componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"Authority="] || [line hasPrefix:@"TeamIdentifier="] ||
                [line hasPrefix:@"Signature="] || [line hasPrefix:@"Identifier="]) {
                [lines addObject:line];
            }
        }
        [s appendFormat:@"签名          %@\n", lines.count ? [lines componentsJoinedByString:@" | "] : @"（读不出签名）"];
        NSString *axQ = [[self runTool:@"/usr/bin/xattr" args:@[@"-p", @"com.apple.quarantine", appex]]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (axQ.length) [s appendFormat:@"小组件隔离    %@ ← 这个插件还被 Gatekeeper 挡着，运行「修复小组件」会清掉\n", axQ];
        NSString *ent = [self runTool:@"/usr/bin/codesign" args:[NSArray arrayWithObjects:@"-d", @"--entitlements", @":-", appex, nil]];
        BOOL sandboxed = [ent containsString:@"com.apple.security.app-sandbox"];
        BOOL groupEnt = [ent containsString:@"com.apple.security.application-groups"];
        [s appendFormat:@"沙盒/共享区   沙盒=%@ 共享组=%@\n", sandboxed ? @"是" : @"否（插件会被系统拒绝）", groupEnt ? @"是" : @"否"];
    }

    NSString *listing = [self runPluginkit:@[@"-m", @"-A", @"-D", @"-v", @"-i", @"com.littlebylittle.app.widget"]];
    [s appendFormat:@"\n插件登记\n%@\n", listing.length ? listing : @"（没有登记：App 还没被打开过，或被系统拒绝了）\n"];

    NSString *group = info[@"LBLAppGroup"];
    [s appendFormat:@"共享组标识    %@\n", group.length ? group : @"（Info.plist 里没有 LBLAppGroup）"];
    if (group.length) {
        NSURL *container = [fm containerURLForSecurityApplicationGroupIdentifier:group];
        [s appendFormat:@"共享容器      %@\n", container.path ?: @"（拿不到：签名/权限不被系统认可）"];
        if (container.path) {
            NSString *store = [[container URLByAppendingPathComponent:@"store.json"] path];
            NSDictionary *attrs = [fm attributesOfItemAtPath:store error:NULL];
            NSData *data = [NSData dataWithContentsOfFile:store];
            NSInteger blocks = 0;
            if (data.length) {
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                if ([obj isKindOfClass:[NSDictionary class]] && [obj[@"blocks"] isKindOfClass:[NSArray class]]) {
                    blocks = [obj[@"blocks"] count];
                }
            }
            [s appendFormat:@"给小组件的副本 %@（%llu 字节，%ld 条日程）\n", store,
                attrs ? [attrs[NSFileSize] unsignedLongLongValue] : 0ULL, (long)blocks];
            if (blocks == 0) [s appendString:@"结论②         副本是空的：小组件会显示「今天还空着」，打开 App 加一条就会写进去。\n"];
        }
    }

    NSString *probeGroup = NSProcessInfo.processInfo.environment[@"LBL_PROBE_GROUP"];
    if (probeGroup.length) {
        NSURL *pu = [fm containerURLForSecurityApplicationGroupIdentifier:probeGroup];
        [s appendFormat:@"\n[探针] 新建共享组 %@ → %@\n", probeGroup, pu.path ?: @"(nil，说明这台机器不允许为新的组新建容器)"];
        if (pu.path) {
            NSString *f = [[pu URLByAppendingPathComponent:@"probe.txt"] path];
            BOOL ok = [@"x" writeToFile:f atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            [s appendFormat:@"[探针] 写入 %@\n", ok ? @"成功" : @"被拒绝"];
        }
    }
    NSString *chronod = [[self runTool:@"/usr/bin/pgrep" args:@[@"-x", @"chronod"]]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [s appendFormat:@"chronod       %@\n", chronod.length ? [NSString stringWithFormat:@"在跑（pid %@）", [chronod componentsSeparatedByString:@"\n"].firstObject] : @"没在跑（被系统关掉了，可以 killall chronod 叫回来）"];
    return s;
}

/// 按顺序做一遍能做的修复，返回做了什么的记录。
- (NSString *)repairWidgetRegistration {
    NSMutableString *s = [NSMutableString string];
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    NSString *appex = [self widgetAppexPath];
    NSFileManager *fm = NSFileManager.defaultManager;

    NSString *xattr = [self runTool:@"/usr/bin/xattr" args:@[@"-dr", @"com.apple.quarantine", bundlePath]];
    [s appendString:xattr.length ? xattr : @"去掉隔离属性：完成\n"];

    if (![fm fileExistsAtPath:appex]) {
        [s appendString:@"小组件包不存在，无法登记。\n"];
        return s;
    }

    NSString *listing = [self runPluginkit:@[@"-m", @"-A", @"-D", @"-v", @"-i", @"com.littlebylittle.app.widget"]];
    for (NSString *line in [listing componentsSeparatedByString:@"\n"]) {
        NSRange slash = [line rangeOfString:@"/"];
        if (slash.location == NSNotFound) continue;
        NSString *path = [[line substringFromIndex:slash.location]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (path.length == 0 || [path isEqualToString:appex]) continue;
        if ([fm fileExistsAtPath:path]) continue;
        [self runPluginkit:@[@"-r", path]];
        [s appendFormat:@"清掉失效登记：%@\n", path];
    }

    [self runPluginkit:@[@"-a", appex]];
    [s appendFormat:@"重新登记：%@\n", appex];

    [self runTool:@"/usr/bin/killall" args:@[@"chronod"]];
    [self runTool:@"/usr/bin/killall" args:@[@"NotificationCenter"]];
    [s appendString:@"重启 chronod / 通知中心：完成\n"];
    [s appendString:@"\n现在打开「编辑小组件」，搜 little 或「Little by Little」，应该能看到了。\n"];
    return s;
}

- (void)repairWidget:(id)sender {
    NSString *log = [self repairWidgetRegistration];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"小组件已重新登记";
    alert.informativeText = [log stringByAppendingString:@"\n如果没有出现，把「小组件 → 检查小组件…」生成的文件发我。"];
    [alert addButtonWithTitle:@"好"];
    [alert runModal];
}

- (void)checkWidget:(id)sender {
    NSString *report = [[self widgetDiagnostics] stringByAppendingString:@"\n—— 修复 ——\n"];
    report = [report stringByAppendingString:[self repairWidgetRegistration]];
    NSString *path = [@"~/Desktop/Little by Little 小组件检查.txt" stringByExpandingTildeInPath];
    [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [NSWorkspace.sharedWorkspace openFile:path];
}

#pragma mark 位置恢复

- (void)restoreFrameForWindow:(NSWindow *)window key:(NSString *)key defaultFrame:(NSRect)fallback {
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:key];
    if (saved.length) {
        NSRect r = NSRectFromString(saved);
        if (r.size.width > 200 && r.size.height > 200) {
            [window setFrame:[self clampFrame:r] display:NO];
            return;
        }
    }
    [window setFrame:fallback display:NO];
}

- (NSRect)clampFrame:(NSRect)frame {
    // 整个窗口都要留在可见区域里，别让卡片一半跑到屏幕外
    NSRect screen = [NSScreen mainScreen].visibleFrame;
    NSRect f = frame;
    CGFloat maxX = NSMaxX(screen) - f.size.width - 8;
    CGFloat maxY = NSMaxY(screen) - f.size.height - 8;
    f.origin.x = MAX(NSMinX(screen) + 8, MIN(f.origin.x, MAX(maxX, NSMinX(screen) + 8)));
    f.origin.y = MAX(NSMinY(screen) + 8, MIN(f.origin.y, MAX(maxY, NSMinY(screen) + 8)));
    return f;
}

#pragma mark WebView

- (NSURL *)webDirectory {
    NSString *env = NSProcessInfo.processInfo.environment[@"DAYLINE_WEB"];
    if (env.length) return [NSURL fileURLWithPath:env isDirectory:YES];
    NSURL *res = NSBundle.mainBundle.resourceURL;
    return [res URLByAppendingPathComponent:@"web" isDirectory:YES];
}

- (WKWebView *)makeWebView:(NSString *)page frame:(NSRect)frame {
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    [cfg.preferences setValue:@YES forKey:@"developerExtrasEnabled"];

    NSMutableDictionary *env = [NSMutableDictionary dictionary];
    env[@"page"] = page;
    env[@"store"] = self.store ?: @{@"blocks": @[], @"habits": @[]};
    if (self.argDate.length) env[@"date"] = self.argDate;
    if (self.argNow.length) env[@"now"] = self.argNow;

    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    [ucc addScriptMessageHandler:self name:@"lbl"];
    NSString *boot = [NSString stringWithFormat:
        @"window.__DAYLINE_ENV__ = %@;"
         "window.addEventListener('error', function(e){"
         "  try { window.webkit.messageHandlers.lbl.postMessage({cmd:'log', message:'JS ERROR: '+e.message+' @'+e.filename+':'+e.lineno}); } catch(_) {}"
         "});"
         "window.addEventListener('unhandledrejection', function(e){"
         "  try { window.webkit.messageHandlers.lbl.postMessage({cmd:'log', message:'JS REJECT: '+e.reason}); } catch(_) {}"
         "});", DLJSJSON(env)];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:boot
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:YES]];
    cfg.userContentController = ucc;

    WKWebView *web = [[DLFirstMouseWebView alloc] initWithFrame:frame configuration:cfg];
    web.navigationDelegate = self;
    web.UIDelegate = self;
    web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    web.allowsMagnification = NO;
    web.allowsBackForwardNavigationGestures = NO;
    if (@available(macOS 12.0, *)) {
        web.underPageBackgroundColor = [NSColor clearColor];
    }
    if ([page isEqualToString:@"widget"]) {
        // 挂件要真透明：光设 underPageBackgroundColor 不够，WebView 自己还会刷一层白底，
        // 在圆角纸卡外面就露出一圈白边。
        @try {
            [web setValue:@NO forKey:@"drawsBackground"];
        } @catch (NSException *e) {
        }
        web.wantsLayer = YES;
        web.layer.backgroundColor = NSColor.clearColor.CGColor;
    }

    NSURL *url = [[self webDirectory] URLByAppendingPathComponent:[page stringByAppendingString:@".html"]];
    [web loadFileURL:url allowingReadAccessToURL:[self webDirectory]];
    return web;
}

- (void)webView:(WKWebView *)webView runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSArray<NSURL *> *))completionHandler {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedFileTypes = @[@"png", @"jpg", @"jpeg", @"heic", @"webp"];
    [panel beginSheetModalForWindow:webView.window completionHandler:^(NSModalResponse response) {
        completionHandler(response == NSModalResponseOK ? panel.URLs : nil);
    }];
}

/// webview 拿到第一响应者后，输入框才吃得到键盘。WKWebView 在某些无边框面板里需要手动补这一下。
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (self.snapshotMode && webView == self.mainWeb) {
        // 等页面自己说「画完了」
    }
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"lbl"]) return;
    NSDictionary *body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;
    NSString *cmd = body[@"cmd"];
    if (![cmd isKindOfClass:[NSString class]]) return;

    if ([cmd isEqualToString:@"save"]) {
        [self handleSave:body[@"store"] from:(message.webView == self.mainWeb ? @"main" : @"widget")];
    } else if ([cmd isEqualToString:@"rendered"]) {
        if (self.snapshotMode) {
            if (self.evalScript.length) [self runEvalThenSnapshot];
            else [self captureSnapshot];
        }
    } else if ([cmd isEqualToString:@"show-main"]) {
        [self showMainWindow:nil];
    } else if ([cmd isEqualToString:@"widget-height"]) {
        [self applyHeight:[body[@"height"] doubleValue] from:message.webView];
    } else if ([cmd isEqualToString:@"hide-widget"]) {
        [self closePopover];
    } else if ([cmd isEqualToString:@"log"]) {
        NSLog(@"[web] %@", body[@"message"]);
    }
}

- (void)goToday:(id)sender {
    [self.mainWeb evaluateJavaScript:@"window.Little && window.Little.today()" completionHandler:nil];
}

- (void)goPrevDay:(id)sender {
    [self.mainWeb evaluateJavaScript:@"window.Little && window.Little.goto(-1)" completionHandler:nil];
}

- (void)showSummary:(id)sender {
    [self.mainWeb evaluateJavaScript:@"window.Little && window.Little.openSummary()" completionHandler:nil];
}

- (void)goNextDay:(id)sender {
    [self.mainWeb evaluateJavaScript:@"window.Little && window.Little.goto(1)" completionHandler:nil];
}

#pragma mark 数据

- (void)handleSave:(id)store from:(NSString *)origin {
    if (![store isKindOfClass:[NSDictionary class]]) return;
    store = [DLStore mergeWidgetActions:store];
    self.store = store;
    [DLStore save:store];

    NSString *js = [NSString stringWithFormat:@"window.Little && window.Little.applyStore(%@);", DLJSJSON(store)];
    if ([origin isEqualToString:@"widget-action"]) {
        [self.mainWeb evaluateJavaScript:js completionHandler:nil];
        [self.popoverWeb evaluateJavaScript:js completionHandler:nil];
    } else if ([origin isEqualToString:@"main"]) {
        if (self.popoverWeb) [self.popoverWeb evaluateJavaScript:js completionHandler:nil];
    } else {
        [self.mainWeb evaluateJavaScript:js completionHandler:nil];
    }

    // 桌面小组件是另一个进程，自己每 15 分钟才刷一次；这里主动叫它立刻重画
    [self scheduleWidgetReload];
}

// 换了台机器、或者从 zip 装进来时，系统不一定会自己发现 app 里的小组件；
// 启动时静默登记一次，省得用户去终端敲 pluginkit。
- (NSString *)runPluginkit:(NSArray<NSString *> *)args {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/pluginkit";
    task.arguments = args;
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = [NSPipe pipe];
    @try { [task launch]; } @catch (NSException *e) { return @""; }
    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

// 装到新位置后，系统里可能还留着指向已删除路径的旧登记，
// 会让组件库显示出已经打不开的条目。这里把失效的登记清掉，再重新登记一次。
/// 从网上下载的包会带 com.apple.quarantine；外层 App 被「仍要打开」放行后，
/// 里层的小组件插件不一定跟着放行，表现为组件库里根本看不到它。启动时顺手清掉。
- (void)stripQuarantine {
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    NSString *q = [self runTool:@"/usr/bin/xattr" args:@[@"-p", @"com.apple.quarantine", bundlePath]];
    if (q.length == 0) return;
    NSString *out = [self runTool:@"/usr/bin/xattr" args:@[@"-dr", @"com.apple.quarantine", bundlePath]];
    NSLog(@"widget: 清隔离属性 %@", out.length ? out : @"ok");
}

- (void)registerWidgetExtensionIfNeeded {
    NSString *appex = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Contents/PlugIns/LittleByLittleWidget.appex"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:appex]) return;

    static NSInteger tries = 0;
    if (tries++ > 1) return;

    NSString *listing = [self runPluginkit:@[@"-m", @"-A", @"-D", @"-v", @"-i", @"com.littlebylittle.app.widget"]];
    BOOL purged = NO;
    for (NSString *line in [listing componentsSeparatedByString:@"\n"]) {
        NSRange slash = [line rangeOfString:@"/"];
        if (slash.location == NSNotFound) continue;
        NSString *path = [[line substringFromIndex:slash.location]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (path.length == 0 || [path isEqualToString:appex]) continue;
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        [self runPluginkit:@[@"-r", path]];
        NSLog(@"widget: 清掉失效登记 %@", path);
        purged = YES;
    }

    [self runPluginkit:@[@"-a", appex]];
    NSLog(@"widget: 已登记 %@", appex);

    if (purged) {
        NSTask *kill = [[NSTask alloc] init];
        kill.launchPath = @"/usr/bin/killall";
        kill.arguments = @[@"chronod"];
        @try { [kill launch]; } @catch (NSException *e) {}
    }
}

- (void)scheduleWidgetReload {
    NSInteger generation = ++DLReloadGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != DLReloadGeneration) return; // 后面还会保存，等最后一次
        DLReloadWidgetTimelines();
        NSLog(@"widget: reloadAllTimelines");
    });
}

- (void)applyHeight:(CGFloat)h from:(WKWebView *)web {
    if (self.snapshotMode) return;
    if (web != self.popoverWeb) return;
    NSPanel *panel = self.popoverPanel;
    if (!panel) return;
    if (h < 180) h = 180;
    if (h > 760) h = 760;
    NSRect f = panel.frame;
    if (fabs(NSHeight(f) - h) < 1.5) return;
    CGFloat top = NSMaxY(f);
    f.size.height = h;
    f.origin.y = top - h;
    [panel setFrame:f display:YES animate:NO];
    NSLog(@"WIDGET HEIGHT -> %.0f", h);
}

#pragma mark 窗口动作

- (void)showMainWindow:(id)sender {
    [self.mainWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (NSString *)launchAgentPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/com.littlebylittle.app.plist"];
}

- (BOOL)launchAtLoginEnabled {
    return [NSFileManager.defaultManager fileExistsAtPath:[self launchAgentPath]];
}

- (void)toggleLaunchAtLogin:(id)sender {
    NSString *path = [self launchAgentPath];
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([self launchAtLoginEnabled]) {
        [fm removeItemAtPath:path error:NULL];
        [self refreshStatusMenu];
        return;
    }
    NSString *dir = [path stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];

    NSString *exe = NSBundle.mainBundle.executablePath ?: @"";
    NSDictionary *plist = @{
        @"Label": @"com.littlebylittle.app",
        @"ProgramArguments": @[ exe ],
        @"RunAtLoad": @YES,
        @"ProcessType": @"Interactive",
    };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:NULL];
    [data writeToFile:path atomically:YES];
    // LaunchAgent 在下次登录时生效，不再调 launchctl
    [self refreshStatusMenu];
}

- (void)observeWindowFrames {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(windowDidMove:) name:NSWindowDidMoveNotification object:nil];
    [nc addObserver:self selector:@selector(windowDidMove:) name:NSWindowDidEndLiveResizeNotification object:nil];
}

- (void)windowDidMove:(NSNotification *)note {
    NSWindow *w = note.object;
    if (w == self.mainWindow) {
        [NSUserDefaults.standardUserDefaults setObject:NSStringFromRect(w.frame) forKey:@"mainFrame"];
    }
}

- (void)windowDidResize:(NSNotification *)note {
    [self windowDidMove:note];
}

#pragma mark 截图（自动化验证）

- (void)runSnapshot {
    NSRect frame = NSMakeRect(0, 0, self.snapshotSize.width, self.snapshotSize.height);
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.backgroundColor = [NSColor clearColor];
    win.opaque = NO;
    WKWebView *web = [self makeWebView:self.snapshotPage frame:frame];
    win.contentView = web;
    self.mainWeb = web;
    [win setFrameOrigin:NSMakePoint(0, 0)];
    [win orderFrontRegardless];

    // 兜底：页面没报 rendered 也要出图
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.snapshotMode) [self captureSnapshot];
    });
}

- (void)runEvalThenSnapshot {
    __weak typeof(self) weakSelf = self;
    [self.mainWeb evaluateJavaScript:self.evalScript completionHandler:^(id result, NSError *error) {
        if (error) {
            NSLog(@"EVAL ERROR: %@", error.localizedDescription);
        } else {
            NSString *text = [result isKindOfClass:[NSString class]] ? result : [NSString stringWithFormat:@"%@", result];
            NSLog(@"EVAL RESULT: %@", text);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf captureSnapshot];
        });
    }];
}

- (void)captureSnapshot {
    if (!self.snapshotMode || self.snapshotPath.length == 0) return;
    static BOOL captured = NO;
    if (captured) return;
    captured = YES;

    NSWindow *win = self.mainWeb.window;
    [win displayIfNeeded];

    WKSnapshotConfiguration *cfg = [[WKSnapshotConfiguration alloc] init];
    cfg.rect = self.mainWeb.bounds;
    [self.mainWeb takeSnapshotWithConfiguration:cfg completionHandler:^(NSImage *image, NSError *error) {
        if (!image) {
            NSLog(@"snapshot failed: %@", error);
            exit(2);
        }
        CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        BOOL ok = [png writeToFile:self.snapshotPath atomically:YES];
        NSLog(@"snapshot %@ -> %@ (%@ bytes)", ok ? @"ok" : @"failed", self.snapshotPath, @(png.length));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(ok ? 0 : 3);
        });
    }];
}

@end
