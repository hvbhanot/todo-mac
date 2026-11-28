// The Today widget: today's and overdue tasks, read from the app's data file.
// build.sh compiles this on its own into Todo.app/Contents/PlugIns/TodayWidget.appex.
import WidgetKit
import SwiftUI

struct Item: Decodable, Identifiable {
    var id: UUID
    var title: String
    var due: Date?
    var hasTime: Bool
    var priority: Int
    var done: Bool
    var completedAt: Date?

    func isOverdue(at now: Date) -> Bool {
        guard let due else { return false }
        return hasTime ? due < now : due < Calendar.current.startOfDay(for: now)
    }
}

struct Entry: TimelineEntry {
    var date: Date
    var tasks: [Item]
    var doneToday: Int
    var readable = true
}

struct Provider: TimelineProvider {
    // The widget is sandboxed, so its own home is a container: find the real one to reach the app's file.
    static let dataURL = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        .appendingPathComponent("Library/Application Support/Todo/data.json")

    static func load(_ now: Date = .now) -> Entry {
        struct File: Decodable { var items: [Item] }
        guard let data = try? Data(contentsOf: dataURL), let file = try? JSONDecoder().decode(File.self, from: data) else {
            return Entry(date: now, tasks: [], doneToday: 0, readable: false)
        }
        let cal = Calendar.current
        let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now)!)
        let tasks = file.items.filter { !$0.done && ($0.due ?? .distantFuture) < tomorrow }
            .sorted { ($0.due!, -$0.priority) < ($1.due!, -$1.priority) }
        let doneToday = file.items.filter { $0.done && $0.completedAt.map(cal.isDateInToday) == true }.count
        return Entry(date: now, tasks: tasks, doneToday: doneToday)
    }

    func placeholder(in context: Context) -> Entry { Entry(date: .now, tasks: [], doneToday: 0) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Self.load()) }

    // One entry now, one at each of today's task times (so they turn overdue on time), and a fresh read at midnight.
    // The app also asks for a reload whenever tasks change.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date()
        let first = Self.load(now)
        let times = Set(first.tasks.compactMap { $0.hasTime ? $0.due : nil }.filter { $0 > now }).sorted()
        let entries = [first] + times.map { var e = first; e.date = $0; return e }
        let midnight = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: now)!)
        completion(Timeline(entries: entries, policy: .after(midnight)))
    }
}

struct TodayView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Entry

    private var rows: Int { family == .systemLarge ? 12 : 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today").font(.headline)
                Spacer()
                Text(entry.date, format: .dateTime.weekday(.abbreviated).day()).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)
            if !entry.readable {
                Spacer()
                Text("Open Todo once to show your tasks here.").font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else if entry.tasks.isEmpty {
                Spacer()
                Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(.tint)
                Text(entry.doneToday > 0 ? "All done. \(entry.doneToday) finished today." : "Nothing due today.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.tasks.prefix(rows)) { row($0) }
                Spacer(minLength: 0)
                if entry.tasks.count > rows {
                    Text("\(entry.tasks.count - rows) more").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ t: Item) -> some View {
        let overdue = t.isOverdue(at: entry.date)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "circle")
                .font(.caption.weight(.light))
                .foregroundStyle([Color.secondary, .blue, .orange, .red][min(max(t.priority, 0), 3)])
            Text(t.title).font(.subheadline).lineLimit(1)
            if family != .systemSmall {
                Spacer(minLength: 4)
                if overdue {
                    Text("Overdue").font(.caption).foregroundStyle(.red)
                } else if t.hasTime, let due = t.due {
                    Text(due, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

@main
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Today", provider: Provider()) { entry in
            TodayView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Tasks due today and anything overdue.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
