import SwiftUI
import UserNotifications
import WidgetKit

let palette: [Color] = [.blue, .red, .orange, .green, .teal, .purple, .pink, .gray]
let paletteNames = ["Blue", "Red", "Orange", "Green", "Teal", "Purple", "Pink", "Gray"]

/// User settings, shared with the @AppStorage views in Settings.
enum Prefs {
    static var defaultReminder: Int { UserDefaults.standard.object(forKey: "defaultReminder") as? Int ?? 0 }
    static var briefing: Bool { UserDefaults.standard.object(forKey: "briefing") as? Bool ?? true }
    static var briefingTime: Int { UserDefaults.standard.object(forKey: "briefingTime") as? Int ?? 8 * 60 }
    static var allDayReminders: Bool { UserDefaults.standard.bool(forKey: "allDayReminders") }
    static var allDayTime: Int { UserDefaults.standard.object(forKey: "allDayTime") as? Int ?? 9 * 60 }
}

/// Minutes before the due time; -1 means no reminder.
func reminderOptions(timed: Bool) -> [(Int, String)] {
    timed ? [(-1, "None"), (0, "At due time"), (5, "5 minutes before"), (15, "15 minutes before"),
             (30, "30 minutes before"), (60, "1 hour before"), (1440, "1 day before")]
          : [(-1, "None"), (0, "On the day"), (1440, "1 day before")]
}

/// Todoist-style priorities: P1 is most urgent. Stored as 3...0 so higher values sort first.
let priorityLevels = [3, 2, 1, 0]
func priorityName(_ p: Int) -> String { "P\(4 - min(max(p, 0), 3))" }
func priorityColor(_ p: Int) -> Color { [Color.secondary, .blue, .orange, .red][min(max(p, 0), 3)] }

// MARK: - Model

enum Recurrence: String, Codable, CaseIterable, Identifiable {
    case none, daily, weekdays, weekly, monthly, yearly
    var id: Self { self }

    var label: String {
        switch self {
        case .none: return "Never"
        case .daily: return "Every day"
        case .weekdays: return "Every weekday"
        case .weekly: return "Every week"
        case .monthly: return "Every month"
        case .yearly: return "Every year"
        }
    }

    func next(after d: Date) -> Date? {
        let cal = Calendar.current
        switch self {
        case .none: return nil
        case .daily: return cal.date(byAdding: .day, value: 1, to: d)
        case .weekdays:
            var n = cal.date(byAdding: .day, value: 1, to: d)!
            while cal.isDateInWeekend(n) { n = cal.date(byAdding: .day, value: 1, to: n)! }
            return n
        case .weekly: return cal.date(byAdding: .weekOfYear, value: 1, to: d)
        case .monthly: return cal.date(byAdding: .month, value: 1, to: d)
        case .yearly: return cal.date(byAdding: .year, value: 1, to: d)
        }
    }
}

struct Subtask: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var done = false
}

struct TodoItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var title = ""
    var notes = ""
    var list = "Inbox" // the project
    var labels: [String] = []
    var subtasks: [Subtask] = []
    var due: Date?
    var hasTime = false
    var reminder = Prefs.defaultReminder
    var priority = 0
    var repeats = Recurrence.none
    var done = false
    var completedAt: Date?
    var created = Date()

    var isOverdue: Bool {
        guard !done, let due else { return false }
        return hasTime ? due < .now : due < Calendar.current.startOfDay(for: .now)
    }
}

extension TodoItem {
    /// Tolerant decoding: fields added in later versions fall back to defaults instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TodoItem()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        id = v(.id, d.id)
        title = v(.title, d.title)
        notes = v(.notes, d.notes)
        list = v(.list, d.list)
        labels = v(.labels, d.labels)
        subtasks = v(.subtasks, d.subtasks)
        due = try? c.decodeIfPresent(Date.self, forKey: .due)
        hasTime = v(.hasTime, d.hasTime)
        reminder = v(.reminder, d.reminder)
        priority = v(.priority, d.priority)
        repeats = v(.repeats, d.repeats)
        done = v(.done, d.done)
        completedAt = try? c.decodeIfPresent(Date.self, forKey: .completedAt)
        created = v(.created, d.created)
    }
}

struct TaskSection: Identifiable {
    let title: String
    let items: [TodoItem]
    var overdue = false
    var id: String { title }
}

struct Toast: Equatable {
    let id = UUID()
    let text: String
}

/// One change the AI made, shown under its reply.
struct AIChange: Identifiable {
    let id = UUID()
    let task: UUID
    let icon: String
    let title: String
    let detail: String
    let reminder: Bool
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

enum Page: Hashable {
    case assistant, today, upcoming, calendar, all, completed, list(String), label(String)

    var title: String {
        switch self {
        case .assistant: return "Assistant"
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .calendar: return "Calendar"
        case .all: return "All Tasks"
        case .completed: return "Completed"
        case .list(let name): return name
        case .label(let name): return "@" + name
        }
    }

    /// Defaults for a task created while this page is open.
    var template: TodoItem {
        var t = TodoItem()
        switch self {
        case .today, .calendar: t.due = Calendar.current.startOfDay(for: .now)
        case .upcoming: t.due = Calendar.current.addDays(1, to: .now)
        case .list(let name): t.list = name
        case .label(let name): t.labels = [name]
        default: break
        }
        return t
    }
}

extension Calendar {
    func addDays(_ n: Int, to d: Date) -> Date { date(byAdding: .day, value: n, to: startOfDay(for: d))! }

    /// The same due moment moved onto another day: keeps the time of day for timed tasks.
    func moving(_ due: Date, hasTime: Bool, to day: Date) -> Date {
        let start = startOfDay(for: day)
        guard hasTime else { return start }
        let hm = dateComponents([.hour, .minute], from: due)
        return date(bySettingHour: hm.hour ?? 9, minute: hm.minute ?? 0, second: 0, of: start) ?? start
    }
}

func dueLabel(_ d: Date, time: Bool) -> String {
    let cal = Calendar.current
    var s = cal.isDateInToday(d) ? "Today"
        : cal.isDateInTomorrow(d) ? "Tomorrow"
        : cal.isDateInYesterday(d) ? "Yesterday"
        : d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    if time { s += ", " + d.formatted(date: .omitted, time: .shortened) }
    return s
}

// MARK: - Quick add parsing

struct QuickParse: Equatable {
    var title: String
    var due: Date?
    var hasTime = false
    var priority: Int?
    var list: String?
    var labels: [String] = []
    var repeats = Recurrence.none
}

private let dateDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

/// Todoist-style quick add: "Pay rent every month #Personal @bills p1 friday 9am".
func parseQuick(_ input: String, lists: [String]) -> QuickParse {
    var r = QuickParse(title: input)
    var text = " " + input + " "

    func take(_ pattern: String) -> String? {
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let hit = String(text[range])
        text.replaceSubrange(range, with: " ")
        return hit.trimmingCharacters(in: .whitespaces)
    }

    // Recurrence first, so the date detector doesn't swallow "every week".
    let rules: [(String, Recurrence)] = [("every ?weekday", .weekdays), ("every ?day|daily", .daily), ("every ?week|weekly", .weekly),
                                         ("every ?month|monthly", .monthly), ("every ?year|yearly|annually", .yearly)]
    for (pattern, rule) in rules where take(#"\s(\#(pattern))(?=\s)"#) != nil {
        r.repeats = rule
        break
    }
    // Longest project name first so "#Side Project" beats "#Side".
    r.list = lists.sorted { $0.count > $1.count }
        .first { take(#"(?<=\s)#\#(NSRegularExpression.escapedPattern(for: $0))(?=\s)"#) != nil }
    if r.list == nil, let hit = take(#"(?<=\s)#[^\s#@]+"#) { r.list = String(hit.dropFirst()) }
    while let hit = take(#"(?<=\s)@[^\s#@]+"#) {
        let label = String(hit.dropFirst()).lowercased()
        if !r.labels.contains(label) { r.labels.append(label) }
    }
    if let hit = take(#"(?<=\s)p[1-4](?=\s)"#), let n = Int(String(hit.suffix(1))) { r.priority = 4 - n }

    let ns = text as NSString
    if let m = dateDetector.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), let date = m.date {
        let phrase = ns.substring(with: m.range).lowercased()
        // ponytail: NSDataDetector has no public "time was given" flag, so sniff the phrase
        r.hasTime = phrase.range(of: #"\d\s*(am|pm)|\d:\d|noon|midnight|morning|evening|tonight"#, options: .regularExpression) != nil
        r.due = r.hasTime ? date : Calendar.current.startOfDay(for: date)
        text = ns.replacingCharacters(in: m.range, with: " ")
    }
    if r.repeats != .none && r.due == nil { r.due = Calendar.current.startOfDay(for: .now) }

    let title = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        .replacingOccurrences(of: #"\s+(on|at|by|due)$"#, with: "", options: [.regularExpression, .caseInsensitive])
    r.title = title.isEmpty ? input.trimmingCharacters(in: .whitespaces) : title
    return r
}

// MARK: - Store

@MainActor final class Store: ObservableObject {
    static let shared = Store()
    @Published var toast: Toast?
    @Published var focusID: UUID? // set by a notification click; the window opens that task
    @Published var items: [TodoItem] = [] { didSet { itemsChanged(from: oldValue) } }
    @Published var lists = ["Inbox", "Personal", "Work"] { didSet { changed(\.lists, from: oldValue) } }
    @Published var colors: [String: Int] = ["Personal": 3, "Work": 0] { didSet { changed(\.colors, from: oldValue) } }
    weak var undo: UndoManager?
    var openMain: (() -> Void)? // the main window's openWindow, so AppKit code can bring it back after it was closed

    /// Brings back the main window (it may have been closed while Todo kept running) and opens a task in it.
    func showMain(_ id: UUID? = nil) {
        NSApp.setActivationPolicy(.regular)
        openMain?()
        NSApp.activate()
        if let id { focusID = id }
    }
    private let url: URL
    private struct Saved: Codable { var items: [TodoItem]; var lists: [String]; var colors: [String: Int]? }

    nonisolated static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Todo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("data.json")
    }

    init(url: URL = Store.defaultURL) {
        self.url = url
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let saved = try JSONDecoder().decode(Saved.self, from: data)
            items = saved.items
            lists = saved.lists
            if let c = saved.colors { colors = c }
        } catch {
            // Never overwrite a file we couldn't read: set it aside and start fresh.
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))"))
        }
        refreshBadge()
    }

    // MARK: Persistence, undo, reminders

    private func changed<T>(_ key: ReferenceWritableKeyPath<Store, T>, from old: T) {
        undo?.registerUndo(withTarget: self) { $0[keyPath: key] = old }
        save()
    }

    private func itemsChanged(from old: [TodoItem]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for t in items where before[t.id] != t { schedule(t) }
        let ids = Set(items.map(\.id))
        let gone = old.filter { !ids.contains($0.id) }.map(\.id.uuidString)
        if !gone.isEmpty { notifications?.removePendingNotificationRequests(withIdentifiers: gone) }
        changed(\.items, from: old)
    }

    private func save() {
        do { try JSONEncoder().encode(Saved(items: items, lists: lists, colors: colors)).write(to: url, options: .atomic) }
        catch { NSLog("Todo: save failed: \(error)") }
        if url == Store.defaultURL { WidgetCenter.shared.reloadAllTimelines() }
        refreshBadge()
        scheduleBriefings()
    }

    /// Re-render date-relative views (e.g. after midnight) and update the Dock badge.
    func refresh() { objectWillChange.send(); refreshBadge() }

    private func refreshBadge() {
        let n = todayCount
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    /// Only the store behind the real data file schedules notifications; test stores use other files.
    private var notifications: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil || url != Store.defaultURL ? nil : .current()
    }

    /// When a task's reminder should fire, or nil if it has none.
    nonisolated static func reminderDate(_ t: TodoItem) -> Date? {
        guard !t.done, t.reminder >= 0, let due = t.due else { return nil }
        if t.hasTime { return due.addingTimeInterval(-Double(t.reminder) * 60) }
        guard Prefs.allDayReminders else { return nil }
        return Calendar.current.date(byAdding: .minute, value: Prefs.allDayTime - t.reminder, to: Calendar.current.startOfDay(for: due))
    }

    private func content(for t: TodoItem) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = t.title
        var body = t.due.map { "Due " + dueLabel($0, time: t.hasTime) } ?? ""
        if t.list != "Inbox" { body += " in \(t.list)" }
        if !t.notes.isEmpty { body += "\n" + t.notes }
        c.body = body
        c.sound = .default
        c.categoryIdentifier = "TASK"
        c.userInfo = ["id": t.id.uuidString]
        return c
    }

    // ponytail: macOS keeps at most 64 pending notifications per app; past that the latest ones are dropped
    private func schedule(_ t: TodoItem) {
        guard let center = notifications else { return }
        center.removePendingNotificationRequests(withIdentifiers: [t.id.uuidString])
        guard let fire = Store.reminderDate(t), fire > .now else { return }
        let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        center.add(UNNotificationRequest(identifier: t.id.uuidString, content: content(for: t),
                                         trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))) { _ in }
    }

    /// Clears every pending reminder and schedules them again from the tasks, so none are left for deleted tasks.
    func rescheduleAll() {
        notifications?.removeAllPendingNotificationRequests()
        items.forEach(schedule)
        scheduleBriefings()
    }

    /// Re-sends a task's reminder after a delay without touching the task.
    func snooze(id: String, minutes: Int = 10) {
        guard let center = notifications, let t = items.first(where: { $0.id.uuidString == id }) else { return }
        center.add(UNNotificationRequest(identifier: id + "-snooze", content: content(for: t),
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: Double(minutes * 60), repeats: false))) { _ in }
    }

    /// Morning summary text for a given day, or nil if nothing is due.
    func briefing(on day: Date) -> (title: String, body: String)? {
        let cal = Calendar.current
        let end = cal.addDays(1, to: day)
        let due = items.filter { !$0.done && ($0.due ?? .distantFuture) < end }.sorted(by: Store.order)
        guard !due.isEmpty else { return nil }
        let overdue = due.filter { $0.due! < cal.startOfDay(for: day) }.count
        var body = due.prefix(3).map(\.title).joined(separator: ", ")
        if due.count > 3 { body += ", and \(due.count - 3) more" }
        if overdue > 0 { body += ". \(overdue) overdue." }
        return ("\(plural(due.count, "task")) for today", body)
    }

    /// One summary per day for the next week, each written from that day's tasks. Rebuilt on every change,
    /// ponytail: if the app stays closed for over a week, summaries stop until it's opened again.
    private func scheduleBriefings() {
        guard let center = notifications else { return }
        center.removePendingNotificationRequests(withIdentifiers: (0..<7).map { "briefing-\($0)" })
        guard Prefs.briefing else { return }
        let cal = Calendar.current
        for d in 0..<7 {
            let day = cal.addDays(d, to: .now)
            guard let fire = cal.date(byAdding: .minute, value: Prefs.briefingTime, to: day), fire > .now,
                  let text = briefing(on: day) else { continue }
            let c = UNMutableNotificationContent()
            c.title = text.title
            c.body = text.body
            c.sound = .default
            c.categoryIdentifier = "BRIEFING"
            let when = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            center.add(UNNotificationRequest(identifier: "briefing-\(d)", content: c,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))) { _ in }
        }
    }

    // MARK: Queries

    var todayCount: Int {
        let end = Calendar.current.addDays(1, to: .now)
        return items.filter { !$0.done && ($0.due ?? .distantFuture) < end }.count
    }

    var openCount: Int { items.filter { !$0.done }.count }
    func openCount(in list: String) -> Int { items.filter { !$0.done && $0.list == list }.count }
    func openCount(label: String) -> Int { items.filter { !$0.done && $0.labels.contains(label) }.count }
    var allLabels: [String] { Array(Set(items.flatMap(\.labels))).sorted() }
    func color(of list: String) -> Color { palette[min(max(colors[list] ?? 0, 0), palette.count - 1)] }

    var dailyGoal: Int { let g = UserDefaults.standard.integer(forKey: "dailyGoal"); return g > 0 ? g : 5 }
    var completedToday: Int { items.filter { $0.completedAt.map(Calendar.current.isDateInToday) ?? false }.count }

    /// Consecutive days with at least one completed task. Today not done yet doesn't break it.
    var streak: Int {
        let cal = Calendar.current
        let days = Set(items.compactMap { $0.completedAt.map { cal.startOfDay(for: $0) } })
        var day = cal.startOfDay(for: .now)
        if !days.contains(day) { day = cal.addDays(-1, to: day) }
        var n = 0
        while days.contains(day) { n += 1; day = cal.addDays(-1, to: day) }
        return n
    }

    nonisolated static func order(_ a: TodoItem, _ b: TodoItem) -> Bool {
        if a.done != b.done { return !a.done }
        switch (a.due, b.due) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        if a.priority != b.priority { return a.priority > b.priority }
        return a.created < b.created
    }

    func sections(_ page: Page, search: String) -> [TaskSection] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let hits = items.filter {
                $0.title.localizedCaseInsensitiveContains(q) || $0.notes.localizedCaseInsensitiveContains(q)
                    || $0.labels.contains { $0.localizedCaseInsensitiveContains(q) }
                    || $0.subtasks.contains { $0.title.localizedCaseInsensitiveContains(q) }
            }
            return [TaskSection(title: "", items: hits.sorted(by: Store.order))]
        }
        let cal = Calendar.current
        let tomorrow = cal.addDays(1, to: .now)
        let open = items.filter { !$0.done }.sorted(by: Store.order)
        switch page {
        case .today:
            let due = open.filter { ($0.due ?? .distantFuture) < tomorrow }
            return [TaskSection(title: "Overdue", items: due.filter { $0.due! < cal.startOfDay(for: .now) }, overdue: true),
                    TaskSection(title: "Today", items: due.filter { cal.isDateInToday($0.due!) })]
        case .upcoming:
            let later = open.filter { ($0.due ?? .distantPast) >= tomorrow }
            return Dictionary(grouping: later) { cal.startOfDay(for: $0.due!) }
                .sorted { $0.key < $1.key }
                .map { TaskSection(title: dueLabel($0.key, time: false), items: $0.value) }
        case .all:
            return lists.map { name in TaskSection(title: name, items: open.filter { $0.list == name }) }
        case .completed:
            let done = items.filter(\.done).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            return Dictionary(grouping: done) { $0.completedAt.map { cal.startOfDay(for: $0) } ?? .distantPast }
                .sorted { $0.key > $1.key }
                .map { TaskSection(title: $0.key == .distantPast ? "Earlier" : dueLabel($0.key, time: false), items: $0.value) }
        case .list(let name):
            return [TaskSection(title: "", items: open.filter { $0.list == name })]
        case .label(let name):
            return [TaskSection(title: "", items: open.filter { $0.labels.contains(name) })]
        case .calendar, .assistant:
            return []
        }
    }

    /// Compact text view of open tasks, sent to the AI as context.
    func digest(limit: Int = 150) -> String {
        let open = items.filter { !$0.done }.sorted(by: Store.order)
        var lines = open.prefix(limit).map { t -> String in
            var s = "- \(t.id.uuidString.prefix(8).lowercased()) [\(priorityName(t.priority))] \(t.title)"
            if let d = t.due {
                s += " | due " + d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                if t.hasTime { s += " " + d.formatted(date: .omitted, time: .shortened) }
                if t.isOverdue { s += " (OVERDUE)" }
            }
            if t.repeats != .none { s += " | " + t.repeats.label.lowercased() }
            s += " | #" + t.list
            if !t.labels.isEmpty { s += " " + t.labels.map { "@" + $0 }.joined(separator: " ") }
            if !t.subtasks.isEmpty { s += " | subtasks \(t.subtasks.filter(\.done).count)/\(t.subtasks.count)" }
            if !t.notes.isEmpty { s += " | notes: " + t.notes.prefix(120).replacingOccurrences(of: "\n", with: " ") }
            return s
        }
        if open.isEmpty { lines.append("(no open tasks)") }
        if open.count > limit { lines.append("...and \(open.count - limit) more") }
        lines.append("Completed today: \(completedToday) of a daily goal of \(dailyGoal). Streak: \(streak) days.")
        return lines.joined(separator: "\n")
    }

    // MARK: Task mutations

    func upsert(_ item: TodoItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
    }

    func add(_ new: [TodoItem]) {
        for name in new.map(\.list) where !lists.contains(name) { addList(name) }
        items += new
    }

    func quickAdd(_ text: String, defaults: TodoItem) {
        var t = defaults
        let q = parseQuick(text, lists: lists)
        t.title = q.title
        if let d = q.due { t.due = d; t.hasTime = q.hasTime }
        if let p = q.priority { t.priority = p }
        if let l = q.list { t.list = l }
        t.labels += q.labels.filter { !t.labels.contains($0) }
        if q.repeats != .none { t.repeats = q.repeats }
        add([t])
    }

    func toggle(_ item: TodoItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        var all = items
        var t = all[i]
        t.done.toggle()
        t.completedAt = t.done ? .now : nil
        if t.done, let due = t.due, var next = t.repeats.next(after: due) {
            // Skip occurrences already in the past, so an overdue daily task lands on today, not yesterday.
            let today = Calendar.current.startOfDay(for: .now)
            while next < today, let n = t.repeats.next(after: next) { next = n }
            var n = t
            n.id = UUID(); n.done = false; n.completedAt = nil; n.due = next; n.created = .now
            n.subtasks = n.subtasks.map { var s = $0; s.done = false; return s }
            t.repeats = .none // the finished copy stops repeating; the new one carries it on
            all.append(n)
        }
        all[i] = t
        items = all // one assignment = one undo step, one save
        if t.done { toast = Toast(text: "Completed \u{201C}\(t.title)\u{201D}") }
    }

    /// Edit one task in place; reads the current stored copy, so concurrent edits elsewhere aren't lost.
    func update(_ id: UUID, _ change: (inout TodoItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var t = items[i]
        change(&t)
        if t != items[i] { items[i] = t }
    }

    func rescheduleOverdue() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        items = items.map { t in
            guard !t.done, let due = t.due, due < today else { return t }
            var n = t
            n.due = cal.moving(due, hasTime: t.hasTime, to: today)
            return n
        }
    }

    func toggleSubtask(_ item: TodoItem, _ sub: Subtask) {
        guard var t = items.first(where: { $0.id == item.id }), let j = t.subtasks.firstIndex(where: { $0.id == sub.id }) else { return }
        t.subtasks[j].done.toggle()
        upsert(t)
    }

    func delete(_ item: TodoItem) { items.removeAll { $0.id == item.id } }
    func clearCompleted() { items.removeAll(where: \.done) }

    func move(id: String, to day: Date) {
        guard var t = items.first(where: { $0.id.uuidString == id }) else { return }
        t.due = Calendar.current.moving(t.due ?? day, hasTime: t.hasTime && t.due != nil, to: day)
        upsert(t)
    }

    func setList(id: String, _ name: String) {
        guard var t = items.first(where: { $0.id.uuidString == id }) else { return }
        t.list = name
        upsert(t)
    }

    // MARK: Projects and labels

    func addList(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !lists.contains(n) else { return }
        colors[n] = lists.count % palette.count
        lists.append(n)
    }

    func renameList(_ old: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespaces)
        guard old != "Inbox", !n.isEmpty, !lists.contains(n), let i = lists.firstIndex(of: old) else { return }
        colors[n] = colors[old]
        lists[i] = n
        items = items.map { var t = $0; if t.list == old { t.list = n }; return t }
    }

    func deleteList(_ name: String) {
        guard name != "Inbox" else { return }
        items = items.map { var t = $0; if t.list == name { t.list = "Inbox" }; return t }
        lists.removeAll { $0 == name }
    }

    func deleteLabel(_ label: String) {
        items = items.map { var t = $0; t.labels.removeAll { $0 == label }; return t }
    }
}

// MARK: - Self-test (run: Todo.app/Contents/MacOS/Todo --selftest)

@MainActor func selfTest() {
    func check(_ ok: Bool, _ msg: @autoclosure () -> String) { if !ok { print("FAIL: \(msg())"); exit(1) } }
    let cal = Calendar.current
    let today = cal.startOfDay(for: .now)
    let tomorrow = cal.addDays(1, to: .now)
    let lists = ["Inbox", "Personal", "Work", "Side Project"]
    let tmp = FileManager.default.temporaryDirectory

    var q = parseQuick("Call Sam tomorrow at 5pm", lists: lists)
    check(q.title == "Call Sam" && q.hasTime && q.due.map { cal.isDate($0, inSameDayAs: tomorrow) && cal.component(.hour, from: $0) == 17 } == true, "\(q)")
    q = parseQuick("Pay rent every month #personal p1 @Bills", lists: lists)
    check(q.title == "Pay rent" && q.repeats == .monthly && q.list == "Personal" && q.priority == 3 && q.labels == ["bills"] && q.due == today, "\(q)")
    q = parseQuick("Ship v2 #side project friday", lists: lists)
    check(q.title == "Ship v2" && q.list == "Side Project" && q.due != nil && !q.hasTime, "\(q)")
    q = parseQuick("Standup every weekday at 9am #Garden", lists: lists)
    check(q.title == "Standup" && q.repeats == .weekdays && q.hasTime && q.list == "Garden", "\(q)")
    q = parseQuick("Email bob@example.com about p2p", lists: lists)
    check(q.title == "Email bob@example.com about p2p" && q.labels.isEmpty && q.priority == nil, "\(q)")
    q = parseQuick("Buy milk", lists: lists)
    check(q == QuickParse(title: "Buy milk"), "\(q)")

    let friday = cal.nextDate(after: today, matching: DateComponents(weekday: 6), matchingPolicy: .nextTime)!
    check(Recurrence.weekdays.next(after: friday).map { cal.component(.weekday, from: $0) } == 2, "weekday after Friday is Monday")

    // A file written by v1 (no labels/subtasks/colors) still loads.
    let v1 = tmp.appendingPathComponent("todo-v1-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: v1) }
    try? #"{"items":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","notes":"","list":"Work","hasTime":false,"priority":2,"repeats":"weekly","done":false,"created":0}],"lists":["Inbox","Work"]}"#
        .write(to: v1, atomically: true, encoding: .utf8)
    let old = Store(url: v1)
    check(old.items.count == 1 && old.items[0].list == "Work" && old.items[0].labels.isEmpty && old.lists == ["Inbox", "Work"], "v1 migration")

    let url = tmp.appendingPathComponent("todo-selftest-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let s = Store(url: url)
    var t = TodoItem(title: "Water plants")
    t.due = cal.addDays(-10, to: .now); t.repeats = .weekly; t.subtasks = [Subtask(title: "Fern", done: true)]
    s.upsert(t)
    s.toggle(t)
    let next = s.items.first { !$0.done }
    check(s.items.count == 2 && next.map { $0.due! >= today && $0.due! < cal.addDays(7, to: today) } == true, "overdue weekly repeat lands in the coming week")
    check(next?.subtasks.first?.done == false, "repeat resets subtasks")
    check(s.completedToday == 1 && s.streak == 1, "productivity counts")
    s.toggle(t); s.toggle(t)
    check(s.items.count == 2, "re-completing a finished repeat must not spawn again")
    s.move(id: t.id.uuidString, to: tomorrow)
    check(Store(url: url).items.first { $0.id == t.id }?.due == tomorrow, "move persists")
    s.addList("Errands"); s.setList(id: t.id.uuidString, "Errands"); s.deleteList("Errands")
    check(s.items.first { $0.id == t.id }?.list == "Inbox" && !s.lists.contains("Errands"), "deleted project's tasks go to Inbox")

    let um = UndoManager()
    um.groupsByEvent = false
    s.undo = um
    let before = s.items.count
    um.beginUndoGrouping(); s.quickAdd("Undo me #NewProj", defaults: TodoItem()); um.endUndoGrouping()
    check(s.items.count == before + 1 && s.lists.contains("NewProj"), "quick add created task and project")
    um.undo()
    check(s.items.count == before && !s.lists.contains("NewProj"), "undo reverts task and project together")
    s.undo = nil

    // Reminders: timed tasks fire before the due time; all-day ones only when that setting is on.
    var r = TodoItem(title: "Dentist")
    r.due = cal.date(bySettingHour: 15, minute: 0, second: 0, of: tomorrow); r.hasTime = true; r.reminder = 30
    check(Store.reminderDate(r) == cal.date(bySettingHour: 14, minute: 30, second: 0, of: tomorrow), "30 min before")
    r.reminder = -1
    check(Store.reminderDate(r) == nil, "reminder off")
    r.hasTime = false; r.reminder = 0
    check(Store.reminderDate(r) == (Prefs.allDayReminders ? cal.date(byAdding: .minute, value: Prefs.allDayTime, to: tomorrow) : nil), "all-day reminder follows setting")

    // Morning summary and moving overdue work to today.
    let b = Store(url: tmp.appendingPathComponent("todo-brief-\(UUID()).json"))
    var late = TodoItem(title: "Late report"); late.due = cal.addDays(-2, to: .now); late.priority = 3
    var now = TodoItem(title: "Call bank"); now.due = cal.date(bySettingHour: 16, minute: 30, second: 0, of: today); now.hasTime = true
    b.add([late, now, TodoItem(title: "Someday")])
    let brief = b.briefing(on: today)
    check(brief?.title == "2 tasks for today" && brief?.body == "Late report, Call bank. 1 overdue.", "briefing: \(String(describing: brief))")
    check(b.briefing(on: cal.addDays(-5, to: today)) == nil, "no briefing on a day with nothing due")
    b.rescheduleOverdue()
    check(b.items.first { $0.title == "Late report" }?.due == today, "overdue moved to today")
    b.update(now.id) { $0.title = "Call the bank" }
    check(b.items.first { $0.id == now.id }?.title == "Call the bank" && b.items.first { $0.id == now.id }?.due == now.due, "update edits in place")
    b.toggle(now)
    check(b.toast?.text.contains("Call the bank") == true, "completion toast")
    // Assistant actions: a new task with a reminder plus a reminder on an existing task, applied as one undo step.
    let acURL = tmp.appendingPathComponent("todo-actions-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: acURL) }
    let ac = Store(url: acURL)
    var dentist = TodoItem(title: "Dentist"); dentist.due = tomorrow
    ac.add([dentist])
    let um2 = UndoManager(); um2.groupsByEvent = false; ac.undo = um2
    let reply = """
    Done.
    <actions>{"add":[{"title":"Call bank","due":"\(AI.ymd.string(from: tomorrow))","time":"10:00","remind":30}],\
    "remind":[{"id":"\(dentist.id.uuidString.prefix(8).lowercased())","time":"15:00","minutes_before":60}]}</actions>
    """
    um2.beginUndoGrouping(); let applied = AI.applyActions(in: reply, store: ac); um2.endUndoGrouping()
    check(applied?.count == 2, "two AI changes: \(String(describing: applied))")
    let bank = ac.items.first { $0.title == "Call bank" }
    check(bank.flatMap(Store.reminderDate) == cal.date(bySettingHour: 9, minute: 30, second: 0, of: tomorrow), "AI-added task reminds 30 min before")
    let dent = ac.items.first { $0.id == dentist.id }
    check(dent.flatMap(Store.reminderDate) == cal.date(bySettingHour: 14, minute: 0, second: 0, of: tomorrow), "AI reminder on existing task")
    um2.undo()
    check(ac.items.count == 1 && ac.items[0] == dentist, "AI changes undo as one step")
    check(AI.applyActions(in: "Just chatting.", store: ac) == nil && AI.applyActions(in: "<actions>oops", store: ac)?.isEmpty == true, "no or bad block")
    check(AI.visibleText(reply) == "Done." && AI.visibleText("Okay <acti") == "Okay", "action block hidden from chat")
    var noTime = TodoItem(title: "Stretch"); AI.setReminder(45, on: &noTime)
    check(noTime.hasTime && noTime.reminder == 30, "reminder snaps to an offered option and gets a time")
    print("selftest passed")
}
