import Foundation
import WidgetKit

/// 让桌面小组件立刻重画。
/// 主外壳是 ObjC，这里只导出一个小小的 C 函数，由 AppDelegate 在每次保存后调用。
/// 不去叫它的话，WidgetKit 只会按 timeline 的 15 分钟节奏自己刷。
@_cdecl("DLReloadWidgetTimelines")
public func DLReloadWidgetTimelines() {
    if #available(macOS 11.0, *) {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
