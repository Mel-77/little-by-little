// LittleByLittle 桌面小组件（WidgetKit）
// 手搓版：没有 Xcode 的 widget 模板，靠 swiftc 直接编成 .appex。
// 展示数据 —— 主 App 把今天的安排写在 ~/Library/Application Support/Little by Little/store.json。

import WidgetKit
import SwiftUI
import Foundation
import AppIntents

// MARK: - 数据

struct Block: Decodable {
    var id: String
    var date: String
    var start: Int
    var dur: Int
    var title: String
    var done: Bool
    var color: Int?
    var habitId: String?
}

struct Habit: Decodable {
    var id: String
    var title: String
    var minutes: Int
    var period: String
    var target: Int
    var prefer: String?
    var color: Int?
}

struct Store: Decodable {
    var blocks: [Block] = []
    var habits: [Habit] = []
}

struct HabitStatus {
    var title: String
    var done: Int
    var target: Int
    var color: Int
}

struct DaySnapshot {
    var dayText: String        // 11月8日
    var weekdayText: String    // 周六
    var items: [Block]         // 未完成在前
    var doneCount: Int
    var total: Int
    var habits: [HabitStatus]
    var nowText: String
    var empty: Bool
}

// MARK: - 读写 store.json

enum StoreReader {
    static let palette: [Color] = [
        Color(red: 0.953, green: 0.788, blue: 0.714),
        Color(red: 0.812, green: 0.875, blue: 0.769),
        Color(red: 0.776, green: 0.847, blue: 0.914),
        Color(red: 0.922, green: 0.863, blue: 0.698),
        Color(red: 0.855, green: 0.800, blue: 0.906)
    ]

    static func path() -> URL? {
        if let home = ProcessInfo.processInfo.environment["LITTLEBYLITTLE_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("store.json")
        }
        guard let group = Bundle.main.object(forInfoDictionaryKey: "LBLAppGroup") as? String,
              let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        // Only the extension accesses its own legacy container. Move pending 2.6
        // commands once; keep the original on failure and retry next refresh.
        let old = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Little by Little/actions")
        let target = base.appendingPathComponent("actions")
        if let files = try? FileManager.default.contentsOfDirectory(at: old, includingPropertiesForKeys: nil), !files.isEmpty {
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                for file in files where file.pathExtension == "json" {
                    let destination = target.appendingPathComponent(file.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.copyItem(at: file, to: destination)
                    }
                    try FileManager.default.removeItem(at: file)
                }
            } catch { NSLog("Widget command migration deferred: %@", error.localizedDescription) }
        }
        return base.appendingPathComponent("store.json")
    }

    static func load() -> Store {
        guard let url = path(), let data = try? Data(contentsOf: url) else { return Store() }
        let dec = JSONDecoder()
        if var s = try? dec.decode(Store.self, from: data) {
            let dir = url.deletingLastPathComponent().appendingPathComponent("actions")
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let data = try? Data(contentsOf: file),
                   let action = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = action["id"] as? String, let done = action["done"] as? Bool,
                   let index = s.blocks.firstIndex(where: { $0.id == id }) {
                    s.blocks[index].done = done
                }
            }
            return s
        }
        return Store()
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for date: Date) -> String { dayFormatter.string(from: date) }

    static let cnDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    static let cnWeek: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEE"
        return f
    }()

    static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "H:mm"
        return f
    }()

    static func timeText(_ minutes: Int) -> String {
        String(format: "%d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    /// 周期内已完成次数（周从周一起算，月是自然月）
    static func habitDone(_ h: Habit, blocks: [Block], ref: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // 周一算一周开始，跟主 App 一致
        let startOfDay = cal.startOfDay(for: ref)
        let periodStart: Date
        if h.period == "month" {
            let comps = cal.dateComponents([.year, .month], from: ref)
            periodStart = cal.date(from: comps) ?? startOfDay
        } else {
            let weekday = cal.component(.weekday, from: ref) // 1 = 周日
            let back = (weekday + 5) % 7                        // 周日回 6 天，周一回 0 天
            periodStart = cal.date(byAdding: .day, value: -back, to: startOfDay) ?? startOfDay
        }
        let startKey = dayFormatter.string(from: periodStart)
        let endKey = dayFormatter.string(from: ref)
        return blocks.filter { b in
            guard b.habitId == h.id, b.done else { return false }
            return b.date >= startKey && b.date <= endKey
        }.count
    }

    static func snapshot(for ref: Date = Date()) -> DaySnapshot {
        let store = load()
        let key = dayFormatter.string(from: ref)
        let today = store.blocks.filter { $0.date == key }
        let finished = today.filter { $0.done }.sorted { $0.start < $1.start }
        // Keep rows in place when toggling; moving completed rows under the cursor
        // makes successive taps appear to affect a different task.
        let ordered = today.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        var hs: [HabitStatus] = []
        for h in store.habits {
            hs.append(HabitStatus(title: h.title,
                                  done: habitDone(h, blocks: store.blocks, ref: ref),
                                  target: max(h.target, 1),
                                  color: h.color ?? 0))
        }
        return DaySnapshot(dayText: cnDay.string(from: ref),
                           weekdayText: cnWeek.string(from: ref),
                           items: ordered,
                           doneCount: finished.count,
                           total: today.count,
                           habits: hs,
                           nowText: hhmm.string(from: ref),
                           empty: today.isEmpty)
    }
}

// MARK: - Timeline

struct LittleByLittleEntry: TimelineEntry {
    let date: Date
    let snap: DaySnapshot
}

struct LittleByLittleProvider: TimelineProvider {
    func placeholder(in context: Context) -> LittleByLittleEntry {
        LittleByLittleEntry(date: Date(), snap: StoreReader.snapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (LittleByLittleEntry) -> Void) {
        completion(LittleByLittleEntry(date: Date(), snap: StoreReader.snapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LittleByLittleEntry>) -> Void) {
        let now = Date()
        let snap = StoreReader.snapshot(for: now)
        NSLog("lbl: timeline %@ items=%lu done=%lu", snap.dayText, snap.items.count, snap.doneCount)
        let entry = LittleByLittleEntry(date: now, snap: snap)
        // 15 分钟后刷一次；过了零点也顺带换一天
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - 外观

private let paper = Color(red: 0.984, green: 0.965, blue: 0.922)
private let ink = Color(red: 0.200, green: 0.188, blue: 0.165)
private let inkSoft = Color(red: 0.200, green: 0.188, blue: 0.165).opacity(0.45)
private let accent = Color(red: 0.761, green: 0.357, blue: 0.271)

private func handFont(_ size: CGFloat) -> Font {
    .custom("Hannotate SC", size: size)
}

struct CheckCircle: View {
    let done: Bool
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(done ? tint : ink.opacity(0.32), lineWidth: 1.4)
                .frame(width: 13, height: 13)
            if done {
                Circle().fill(tint).frame(width: 13, height: 13)
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }
}

struct CompleteBlockIntent: AppIntent {
    static var title: LocalizedStringResource = "更新日程完成状态"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false
    @Parameter(title: "日程") var blockID: String
    @Parameter(title: "完成") var done: Bool
    init() {}
    init(blockID: String, done: Bool) { self.blockID = blockID; self.done = done }
    func perform() async throws -> some IntentResult {
        // The pending action overlays the snapshot immediately. Only the host
        // writes store.json, avoiding stale full-file writes from two processes.
        guard let url = StoreReader.path() else {
            throw NSError(domain: "LittleByLittle", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "共享目录不可用，请先打开 Little by Little 并允许数据访问"])
        }
        let dir = url.deletingLastPathComponent().appendingPathComponent("actions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["id": blockID, "done": done])
        let name = String(format: "%020.6f", Date().timeIntervalSince1970) + "-" + UUID().uuidString + ".json"
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct RowView: View {
    let block: Block

    var body: some View {
        // 整行都是按钮：点在哪一行就勾哪一行，不会因为圆圈太小点偏到隔壁
        Button(intent: CompleteBlockIntent(blockID: block.id, done: !block.done)) {
            HStack(spacing: 5) {
                CheckCircle(done: block.done, tint: accent).frame(width: 24, height: 21)
                Text(StoreReader.timeText(block.start))
                    .font(handFont(11))
                    .foregroundColor(inkSoft)
                    .monospacedDigit()
                    .frame(width: 31, alignment: .leading)
                Text(block.title.isEmpty ? "一件事" : block.title)
                    .font(handFont(12.5))
                    .foregroundColor(block.done ? inkSoft : ink)
                    .strikethrough(block.done, color: inkSoft)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 字号恒定：放不下就从尾巴省略，绝不缩小
                    .allowsTightening(true)
                    .layoutPriority(1)
                Spacer(minLength: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(block.done ? "标记未完成" : "标记完成")
    }
}

struct ProgressBar: View {
    let done: Int
    let total: Int

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(ink.opacity(0.10))
                Capsule()
                    .fill(accent)
                    .frame(width: max(0, geo.size.width * (total == 0 ? 0 : CGFloat(done) / CGFloat(total))))
            }
        }
        .frame(height: 3)
    }
}

struct HabitPills: View {
    let habits: [HabitStatus]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(habits.prefix(3), id: \.title) { h in
                HStack(spacing: 4) {
                    Circle()
                        .fill(StoreReader.palette[h.color % StoreReader.palette.count])
                        .frame(width: 5, height: 5)
                    Text("\(h.title) \(h.done)/\(h.target)")
                        .font(handFont(10.5))
                        .foregroundColor(ink.opacity(0.8))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(ink.opacity(0.055)))
            }
            Spacer(minLength: 0)
        }
    }
}

struct LittleByLittleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LittleByLittleEntry

    private var snap: DaySnapshot { entry.snap }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
        .containerBackground(for: .widget) { paper }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(snap.dayText).font(handFont(family == .systemSmall ? 17 : 19)).foregroundColor(ink)
            Text(snap.weekdayText).font(handFont(11)).foregroundColor(inkSoft)
            Spacer(minLength: 0)
            Text(snap.total == 0 ? "—" : "\(snap.doneCount)/\(snap.total)")
                .font(handFont(13)).foregroundColor(ink.opacity(0.65))
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ProgressBar(done: snap.doneCount, total: snap.total)
            if snap.empty {
                Text("今天还空着").font(handFont(12)).foregroundColor(inkSoft)
            } else if let next = snap.items.first(where: { !$0.done }) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("接下来").font(handFont(10)).foregroundColor(inkSoft)
                    Text(next.title.isEmpty ? "一件事" : next.title)
                        .font(handFont(13)).foregroundColor(ink).lineLimit(2)
                    Text(StoreReader.timeText(next.start)).font(handFont(11)).foregroundColor(inkSoft)
                }
            } else {
                Text("都做完了").font(handFont(12)).foregroundColor(accent)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            ProgressBar(done: snap.doneCount, total: snap.total)
            if snap.empty {
                Text("今天还空着，在时间轴上拖一条").font(handFont(12)).foregroundColor(inkSoft)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(snap.items.prefix(4), id: \.id) { b in
                        RowView(block: b)
                    }
                }
                Spacer(minLength: 0)
            }
            if !snap.habits.isEmpty {
                HabitPills(habits: snap.habits)
            }
        }
        .padding(13)
    }

    private var large: some View {
        // 只留大号：一屏把一天铺开，底部不再挂定期任务进度（那是 App 里的事）
        let shown = snap.items.count > 11 ? 10 : 11
        return VStack(alignment: .leading, spacing: 8) {
            header
            ProgressBar(done: snap.doneCount, total: snap.total)
            if snap.empty {
                Text("今天还空着，在时间轴上拖一条").font(handFont(13)).foregroundColor(inkSoft)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(snap.items.prefix(shown), id: \.id) { block in
                        RowView(block: block)
                            .frame(height: 21, alignment: .leading)
                    }
                }
                if snap.items.count > shown {
                    Text("还有 \(snap.items.count - shown) 件").font(handFont(11)).foregroundColor(inkSoft)
                }
                Spacer(minLength: 0)
                HStack {
                    Text("还剩 \(max(0, snap.total - snap.doneCount)) 件")
                        .font(handFont(11))
                        .foregroundColor(inkSoft)
                    Spacer()
                    Text("点圆圈勾选")
                        .font(handFont(11))
                        .foregroundColor(inkSoft.opacity(0.75))
                }
            }
        }
        .padding(13)
    }
}

// MARK: - Widget

struct LittleByLittleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LittleByLittleToday", provider: LittleByLittleProvider()) { entry in
            LittleByLittleWidgetView(entry: entry)
                .widgetURL(URL(string: "littlebylittle://today"))
        }
        .configurationDisplayName("Little by Little")
        .description("今天的安排，一眼看完。点圆圈勾选 Little by Little。")
        .supportedFamilies([.systemLarge])
    }
}

@main
struct LittleByLittleWidgetBundle: WidgetBundle {
    var body: some Widget {
        LittleByLittleWidget()
    }
}
