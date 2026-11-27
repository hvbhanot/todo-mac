import SwiftUI

/// The content background Apple's apps use for lists: white in light mode, near-black in dark mode.
let pageBackground = Color(nsColor: .textBackgroundColor)

// MARK: - Page chrome

struct PageHeader: View {
    @EnvironmentObject var store: Store
    let page: Page
    let search: String
    let sections: [TaskSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(search.isEmpty ? page.title : "Search")
                .font(.largeTitle.bold())
                .foregroundStyle(project.map { store.color(of: $0) } ?? .primary)
            Text(subtitle).foregroundStyle(.secondary)
            if page == .today && search.isEmpty { DailyGoal().padding(.top, 8) }
        }
    }

    private var project: String? { if case .list(let name) = page, search.isEmpty { return name }; return nil }

    private var subtitle: String {
        let count = sections.reduce(0) { $0 + $1.items.count }
        if !search.isEmpty { return "\(plural(count, "task")) matching \u{201C}\(search)\u{201D}" }
        switch page {
        case .today:
            let date = Date().formatted(.dateTime.weekday(.wide).month(.wide).day())
            guard count > 0 else { return date }
            let overdue = sections.first(where: \.overdue)?.items.count ?? 0
            return "\(date), \(plural(count, "task")) to do" + (overdue > 0 ? ", \(overdue) overdue" : "")
        case .upcoming: return count == 0 ? "Nothing scheduled after today" : "\(plural(count, "task")) scheduled after today"
        case .all: return "\(plural(count, "open task")) in \(plural(store.lists.count, "project"))"
        case .completed: return store.streak > 1 ? "\(plural(count, "task")) completed, \(store.streak)-day streak" : "\(plural(count, "task")) completed"
        default: return "\(plural(count, "open task"))"
        }
    }
}

/// Progress toward the daily goal (Settings > General).
struct DailyGoal: View {
    @EnvironmentObject var store: Store
    @AppStorage("dailyGoal") private var goal = 5

    var body: some View {
        let done = store.completedToday
        HStack(spacing: 10) {
            ProgressView(value: Double(min(done, goal)), total: Double(max(goal, 1))).frame(width: 140)
            Text(done >= goal ? "Daily goal reached" : "\(done) of \(goal) done today")
            if store.streak > 1 { Text("\(store.streak)-day streak").foregroundStyle(.tertiary) }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .animation(.snappy, value: done)
        .help("Tasks completed today. Change the goal in Settings.")
    }
}

struct SectionHeader: View {
    @EnvironmentObject var store: Store
    let section: TaskSection
    var showMoveAll = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(section.title).foregroundStyle(section.overdue ? Color.red : Color.primary)
            Text("\(section.items.count)").monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            if section.overdue && showMoveAll {
                Button("Move All to Today") { withAnimation(.snappy) { store.rescheduleOverdue() } }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                    .font(.callout)
            }
        }
        .font(.headline)
        .padding(.top, 6)
    }
}

struct EmptyState: View {
    let page: Page
    let search: String

    var body: some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            ContentUnavailableView(title, systemImage: page == .completed ? "checkmark.circle" : page == .upcoming ? "calendar" : "tray",
                                   description: Text(detail))
        }
    }

    private var title: String {
        switch page {
        case .today: return "Nothing Left for Today"
        case .upcoming: return "Nothing Scheduled"
        case .completed: return "No Completed Tasks"
        default: return "No Open Tasks"
        }
    }

    private var detail: String {
        switch page {
        case .today: return "Add a task above, or pull one forward from Upcoming."
        case .completed: return "Tasks you complete show up here, grouped by the day you finished them."
        default: return "Add a task above. Dates, #projects, @labels and p1 to p4 work as you type."
        }
    }
}

// MARK: - Composer

struct Composer: View {
    @EnvironmentObject var store: Store
    var defaults = TodoItem()
    var prompt = "Add a task"
    var focused: FocusState<Bool>.Binding
    var allowAI = true
    @State private var text = ""
    @State private var aiMode = false
    @State private var busy = false
    @State private var review: [TodoItem]?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("", text: $text, prompt: Text(aiMode ? "Describe what's on your mind and AI drafts the tasks" : prompt))
                    .textFieldStyle(.roundedBorder)
                    .focused(focused)
                    .onSubmit(submit)
                    .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                if allowAI {
                    Toggle(isOn: $aiMode) { Label("AI", systemImage: "sparkles") }
                        .toggleStyle(.button)
                        .help(aiMode ? "AI drafting is on: Return sends your text to Ollama" : "Draft tasks with AI")
                }
            }
            .controlSize(.large)
            if !aiMode { ParsePreview(text: text, showHint: focused.wrappedValue && text.isEmpty) }
        }
        .sheet(isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
            AIReviewSheet(tasks: review ?? [])
        }
        .alert("AI drafting failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !busy else { return }
        guard aiMode else {
            withAnimation(.snappy) { store.quickAdd(t, defaults: defaults) }
            text = ""
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                review = try await AI.extractTasks(t, store: store, defaults: defaults)
                text = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Shows what the quick-add syntax picked up while you type.
struct ParsePreview: View {
    @EnvironmentObject var store: Store
    let text: String
    var showHint = false

    var body: some View {
        let q = parseQuick(text, lists: store.lists)
        let chips = [q.due.map { dueLabel($0, time: q.hasTime) }, q.repeats == .none ? nil : q.repeats.label,
                     q.list.map { "#" + $0 }, q.priority.map(priorityName)].compactMap { $0 } + q.labels.map { "@" + $0 }
        if !text.trimmingCharacters(in: .whitespaces).isEmpty && !chips.isEmpty {
            HStack(spacing: 5) {
                ForEach(chips, id: \.self) { chip in
                    Text(chip)
                        .font(.callout)
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.leading, 2)
        } else if showHint {
            Text("Type naturally: Pay rent every month #Personal @bills p1")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
    }
}

// MARK: - Task list

struct TaskListView: View {
    @EnvironmentObject var store: Store
    let page: Page
    let search: String
    @Binding var inspected: UUID?
    var composerFocused: FocusState<Bool>.Binding
    @State private var confirmClear = false

    var body: some View {
        let sections = store.sections(page, search: search).filter { !$0.items.isEmpty }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    PageHeader(page: page, search: search, sections: sections)
                    Spacer()
                    if page == .completed && !sections.isEmpty && search.isEmpty {
                        Button("Clear Completed...") { confirmClear = true }
                    }
                }
                if page != .completed && search.isEmpty {
                    Composer(defaults: page.template, focused: composerFocused)
                }
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 6)

            List(selection: $inspected) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { TaskRow(item: $0, inspected: $inspected).tag($0.id) }
                    } header: {
                        if !section.title.isEmpty { SectionHeader(section: section, showMoveAll: page == .today) }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay { if sections.isEmpty { EmptyState(page: page, search: search) } }
            .onDeleteCommand {
                if let id = inspected, let t = store.items.first(where: { $0.id == id }) { withAnimation(.snappy) { store.delete(t) } }
            }
        }
        .background(pageBackground)
        .confirmationDialog("Delete all completed tasks?", isPresented: $confirmClear) {
            Button("Delete Completed Tasks", role: .destructive) { store.clearCompleted() }
        } message: {
            Text("You can undo this with Cmd-Z.")
        }
    }
}

/// A round checkbox like Reminders'. Its ring takes the priority colour.
struct Checkbox: View {
    let priority: Int
    let checked: Bool
    var size: CGFloat = 17
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: checked ? "checkmark.circle.fill" : hover ? "checkmark.circle" : "circle")
                .font(.system(size: size, weight: .light))
                .foregroundStyle(checked ? Color.accentColor : priority > 0 ? priorityColor(priority) : Color.secondary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hover = $0 }
        .help(checked ? "Mark as not done" : "Complete")
        .accessibilityLabel(checked ? "Mark as not done" : "Complete")
    }
}

struct TaskRow: View {
    @EnvironmentObject var store: Store
    let item: TodoItem
    @Binding var inspected: UUID?
    var compact = false
    var onOpen: (() -> Void)? // set outside a List, where there is no row selection to open the task
    @State private var hovering = false
    @State private var completing = false

    var body: some View {
        let checked = item.done || completing
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Checkbox(priority: item.priority, checked: checked, action: complete)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .foregroundStyle(checked ? .secondary : .primary)
                    .lineLimit(compact ? 1 : 3)
                if !item.notes.isEmpty && !compact {
                    Text(item.notes).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if TaskMeta.has(item) { TaskMeta(item: item) }
            }
            Spacer(minLength: 8)
            if !compact {
                if hovering { actions } else if item.list != "Inbox" { ProjectTag(name: item.list) }
            }
        }
        .padding(.vertical, compact ? 4 : 5)
        .padding(.horizontal, compact ? 8 : 0)
        .background(compact && hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture().onEnded { onOpen?() }, including: onOpen == nil ? .subviews : .all)
        .draggable(item.id.uuidString)
        .contextMenu { menu }
        .opacity(completing ? 0.5 : 1)
    }

    private func complete() {
        guard !item.done else { store.toggle(item); return }
        completing = true // let the check land before the row leaves the list
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.snappy) { store.toggle(item) }
            completing = false
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            icon("sun.max", "Due today") { store.move(id: item.id.uuidString, to: .now) }
            icon("sunrise", "Due tomorrow") { store.move(id: item.id.uuidString, to: Calendar.current.addDays(1, to: .now)) }
            icon("trash", "Delete") { withAnimation(.snappy) { store.delete(item) } }
        }
    }

    private func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).frame(width: 22, height: 18) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(help)
    }

    @ViewBuilder private var menu: some View {
        let id = item.id.uuidString
        Button("Show Details") { if let onOpen { onOpen() } else { inspected = item.id } }
        Button(item.done ? "Mark as Not Done" : "Complete") { store.toggle(item) }
        Divider()
        Button("Due Today") { store.move(id: id, to: .now) }
        Button("Due Tomorrow") { store.move(id: id, to: Calendar.current.addDays(1, to: .now)) }
        Button("Due Next Week") { store.move(id: id, to: Calendar.current.addDays(7, to: .now)) }
        Button("Remove Due Date") { store.update(item.id) { $0.due = nil; $0.hasTime = false } }.disabled(item.due == nil)
        Picker("Priority", selection: Binding(get: { item.priority }, set: { p in store.update(item.id) { $0.priority = p } })) {
            ForEach(priorityLevels, id: \.self) { Text(priorityName($0)).tag($0) }
        }
        Menu("Move to Project") {
            ForEach(store.lists, id: \.self) { name in Button(name) { store.setList(id: id, name) } }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(item) }
    }
}

struct TaskMeta: View {
    let item: TodoItem

    static func has(_ t: TodoItem) -> Bool { t.due != nil || t.repeats != .none || !t.subtasks.isEmpty || !t.labels.isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            if let due = item.due {
                Label(dueLabel(due, time: item.hasTime), systemImage: item.hasTime ? "clock" : "calendar")
                    .foregroundStyle(item.isOverdue ? Color.red : Calendar.current.isDateInToday(due) && !item.done ? Color.accentColor : Color.secondary)
            }
            if item.repeats != .none { Label(item.repeats.label, systemImage: "repeat") }
            if item.due != nil && item.reminder >= 0 && (item.hasTime || Prefs.allDayReminders) && !item.done {
                Image(systemName: "bell").imageScale(.small).help("Reminder set")
            }
            if !item.subtasks.isEmpty {
                Label("\(item.subtasks.filter(\.done).count)/\(item.subtasks.count)", systemImage: "checklist")
            }
            ForEach(item.labels, id: \.self) { Text("@" + $0) }
        }
        .labelStyle(TightLabel())
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon.imageScale(.small); configuration.title }
    }
}

struct ProjectTag: View {
    @EnvironmentObject var store: Store
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(store.color(of: name)).frame(width: 7, height: 7)
            Text(name)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

func parseLabels(_ s: String) -> [String] {
    var out: [String] = []
    for raw in s.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
        let l = raw.trimmingCharacters(in: CharacterSet(charactersIn: "@#")).lowercased()
        if !l.isEmpty && !out.contains(l) { out.append(l) }
    }
    return out
}

// MARK: - Inspector (edits save as you go)

/// A text field that saves when you press Return, leave the field, or close the panel.
struct CommitField: View {
    var label = ""
    let value: String
    var prompt = ""
    var axis: Axis = .horizontal
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text, prompt: Text(prompt), axis: axis)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { if !focused { text = value } }
            .onChange(of: focused) { if !focused { save() } }
            .onSubmit(save)
            .onDisappear(perform: save)
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != value { commit(t) }
    }
}

struct Inspector: View {
    @EnvironmentObject var store: Store
    let id: UUID
    let close: () -> Void
    @State private var newSubtask = ""
    @State private var breaking = false
    @State private var pickingDate = false
    @State private var error: String?

    var body: some View {
        if let t = store.items.first(where: { $0.id == id }) {
            Form {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Checkbox(priority: t.priority, checked: t.done) { store.toggle(t) }
                        CommitField(value: t.title, prompt: "Title", axis: .vertical) { new in
                            if !new.isEmpty { store.update(id) { $0.title = new } }
                        }
                        .font(.title3.weight(.semibold))
                    }
                    CommitField(value: t.notes, prompt: "Notes", axis: .vertical) { new in store.update(id) { $0.notes = new } }
                }
                .textFieldStyle(.plain)
                .labelsHidden() // a hidden label lets grouped-form fields run full width, left aligned

                Section {
                    Picker("Project", selection: bind(t, \.list)) { ForEach(store.lists, id: \.self) { Text($0).tag($0) } }
                    Picker("Priority", selection: bind(t, \.priority)) {
                        ForEach(priorityLevels, id: \.self) { Text(priorityName($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    LabeledContent("Date") { dateControl(t) }
                    if let due = t.due {
                        LabeledContent("Time") {
                            HStack(spacing: 8) {
                                if t.hasTime {
                                    DatePicker("Time", selection: Binding(get: { due }, set: { d in store.update(id) { $0.due = d } }),
                                               displayedComponents: .hourAndMinute)
                                        .labelsHidden()
                                }
                                Toggle("Time", isOn: timeBinding(t)).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            }
                        }
                        Picker("Reminder", selection: bind(t, \.reminder)) {
                            ForEach(reminderOptions(timed: t.hasTime), id: \.0) { Text($0.1).tag($0.0) }
                        }
                        Picker("Repeat", selection: bind(t, \.repeats)) { ForEach(Recurrence.allCases) { Text($0.label).tag($0) } }
                    }
                } footer: {
                    if t.due != nil && !t.hasTime && t.reminder >= 0 && !Prefs.allDayReminders {
                        Text("All-day reminders are off. Turn them on in Settings.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    CommitField(label: "Labels", value: t.labels.joined(separator: ", "), prompt: "Comma separated") { new in
                        store.update(id) { $0.labels = parseLabels(new) }
                    }
                }

                Section {
                    ForEach(t.subtasks) { s in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Checkbox(priority: 0, checked: s.done, size: 15) { store.toggleSubtask(t, s) }
                            Text(s.title).foregroundStyle(s.done ? .secondary : .primary)
                            Spacer()
                            Button { store.update(id) { x in x.subtasks.removeAll { $0.id == s.id } } } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Remove subtask")
                        }
                    }
                    TextField("Add a subtask", text: $newSubtask, prompt: Text("Add a subtask"))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .onSubmit {
                            let title = newSubtask.trimmingCharacters(in: .whitespaces)
                            if !title.isEmpty { store.update(id) { $0.subtasks.append(Subtask(title: title)) } }
                            newSubtask = ""
                        }
                    Button { breakDown(t) } label: { Label(breaking ? "Breaking down..." : "Break Down with AI", systemImage: "sparkles") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                        .disabled(breaking)
                } header: {
                    HStack {
                        Text("Subtasks")
                        Spacer()
                        if !t.subtasks.isEmpty { Text("\(t.subtasks.filter(\.done).count) of \(t.subtasks.count)").foregroundStyle(.secondary) }
                    }
                }

                Section {
                    LabeledContent("Created", value: t.created.formatted(date: .abbreviated, time: .omitted))
                    if let c = t.completedAt { LabeledContent("Completed", value: c.formatted(date: .abbreviated, time: .shortened)) }
                    Button("Delete Task", role: .destructive) { store.delete(t); close() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .alert("AI request failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") {}
            } message: { Text(error ?? "") }
        } else {
            ContentUnavailableView("No Task Selected", systemImage: "checklist")
        }
    }

    @ViewBuilder private func dateControl(_ t: TodoItem) -> some View {
        if let due = t.due {
            HStack(spacing: 6) {
                Button(dueLabel(due, time: false)) { pickingDate = true }
                    .popover(isPresented: $pickingDate, arrowEdge: .bottom) {
                        DatePicker("Date", selection: Binding(get: { due }, set: { d in store.update(id) { $0.due = Self.day(d, keepingTimeOf: $0) } }),
                                   displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .padding(12)
                    }
                Button { store.update(id) { $0.due = nil; $0.hasTime = false } } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove date")
            }
        } else {
            Menu("None") {
                Button("Today") { setDue(0) }
                Button("Tomorrow") { setDue(1) }
                Button("Next Week") { setDue(7) }
                Divider()
                Button("Choose a Date...") { setDue(0); DispatchQueue.main.async { pickingDate = true } }
            }
            .fixedSize()
        }
    }

    private func setDue(_ days: Int) { store.update(id) { $0.due = Calendar.current.startOfDay(for: Calendar.current.addDays(days, to: .now)) } }

    /// The picked day, keeping a timed task's time of day.
    private static func day(_ d: Date, keepingTimeOf t: TodoItem) -> Date {
        let cal = Calendar.current, day = cal.startOfDay(for: d)
        guard t.hasTime, let old = t.due else { return day }
        let c = cal.dateComponents([.hour, .minute], from: old)
        return cal.date(bySettingHour: c.hour ?? 9, minute: c.minute ?? 0, second: 0, of: day) ?? day
    }

    private func bind<T>(_ t: TodoItem, _ key: WritableKeyPath<TodoItem, T>) -> Binding<T> {
        Binding(get: { t[keyPath: key] }, set: { v in store.update(id) { $0[keyPath: key] = v } })
    }

    private func timeBinding(_ t: TodoItem) -> Binding<Bool> {
        Binding(get: { t.hasTime }, set: { on in
            store.update(id) { x in
                let day = Calendar.current.startOfDay(for: x.due ?? .now)
                x.hasTime = on
                x.due = on ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) : day
            }
        })
    }

    private func breakDown(_ t: TodoItem) {
        breaking = true
        Task {
            defer { breaking = false }
            do {
                let steps = try await AI.subtasks(for: t)
                store.update(id) { $0.subtasks += steps.map { Subtask(title: $0) } }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Calendar

struct CalendarView: View {
    @EnvironmentObject var store: Store
    @Binding var inspected: UUID?
    var composerFocused: FocusState<Bool>.Binding
    @State private var month = Calendar.current.dateInterval(of: .month, for: .now)!.start
    @State private var selected = Calendar.current.startOfDay(for: .now)
    private let cal = Calendar.current

    var body: some View {
        let byDay = Dictionary(grouping: store.items.filter { $0.due != nil }) { cal.startOfDay(for: $0.due!) }
            .mapValues { $0.sorted(by: Store.order) }
        let offset = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let weeks = (offset + cal.range(of: .day, in: .month, for: month)!.count + 6) / 7
        let days = (0..<weeks * 7).map { cal.addDays($0 - offset, to: month) }

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                HStack(spacing: 1) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(cal.shortWeekdaySymbols[(i + cal.firstWeekday - 1) % 7])
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(spacing: 1) {
                    ForEach(0..<weeks, id: \.self) { w in
                        HStack(spacing: 1) {
                            ForEach(0..<7, id: \.self) { d in
                                let day = days[w * 7 + d]
                                cell(day, byDay[day] ?? [])
                            }
                        }
                    }
                }
                .background(Color(nsColor: .separatorColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 20)

            if inspected == nil { // the details panel takes this column while it is open
                Divider()
                DayPanel(day: selected, items: byDay[selected] ?? [], inspected: $inspected, composerFocused: composerFocused)
                    .frame(width: 320)
            }
        }
        .background(pageBackground)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(month.formatted(.dateTime.month(.wide))).font(.largeTitle.bold()).lineLimit(1).fixedSize()
            Text(month.formatted(.dateTime.year())).font(.largeTitle).foregroundStyle(.secondary)
            Spacer()
            ControlGroup {
                Button { shift(-1) } label: { Label("Previous Month", systemImage: "chevron.left") }
                Button("Today") {
                    month = cal.dateInterval(of: .month, for: .now)!.start
                    selected = cal.startOfDay(for: .now)
                }
                Button { shift(1) } label: { Label("Next Month", systemImage: "chevron.right") }
            }
            .labelStyle(.iconOnly)
            .fixedSize()
        }
    }

    private func shift(_ n: Int) { month = cal.date(byAdding: .month, value: n, to: month)! }

    private func cell(_ day: Date, _ tasks: [TodoItem]) -> some View {
        let isToday = cal.isDateInToday(day)
        let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(cal.component(.day, from: day))")
                .font(.callout.weight(isToday ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(isToday ? Color.white : inMonth ? Color.primary : Color.secondary)
                .frame(minWidth: 22, minHeight: 22)
                .background(isToday ? Color.accentColor : .clear, in: Circle())
                .padding(.bottom, 1)
            ForEach(tasks.prefix(3)) { chip($0) }
            if tasks.count > 3 {
                Text("\(tasks.count - 3) more").font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                inMonth ? pageBackground : Color(nsColor: .windowBackgroundColor)
                if day == selected { Color.accentColor.opacity(0.1) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selected = day
            DispatchQueue.main.async { composerFocused.wrappedValue = true }
        }
        .onTapGesture { selected = day }
        .dropDestination(for: String.self) { ids, _ in
            ids.forEach { store.move(id: $0, to: day) }
            selected = day
            return true
        }
    }

    private func chip(_ t: TodoItem) -> some View {
        HStack(spacing: 4) {
            Circle().fill(t.done ? Color.secondary : store.color(of: t.list)).frame(width: 6, height: 6)
            if t.hasTime, let due = t.due {
                Text(due.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary).fixedSize()
            }
            Text(t.title).foregroundStyle(t.done ? .secondary : .primary)
        }
        .font(.subheadline)
        .lineLimit(1)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(inspected == t.id ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { inspected = t.id }
        .draggable(t.id.uuidString)
    }
}

struct DayPanel: View {
    @EnvironmentObject var store: Store
    let day: Date
    let items: [TodoItem]
    @Binding var inspected: UUID?
    var composerFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.formatted(.dateTime.weekday(.wide))).font(.title.bold())
                Text(day.formatted(.dateTime.month(.wide).day().year())).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.top, 24)
            Composer(defaults: { var t = TodoItem(); t.due = day; return t }(), prompt: "Add a task for this day", focused: composerFocused)
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 6)
            List(selection: $inspected) {
                ForEach(items) { TaskRow(item: $0, inspected: $inspected).tag($0.id) }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("Nothing Planned", systemImage: "calendar",
                                           description: Text("Double-click a day to add a task, or drag one onto it."))
                }
            }
        }
    }
}
