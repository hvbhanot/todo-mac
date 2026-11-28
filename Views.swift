import SwiftUI
import UserNotifications
import ServiceManagement

// MARK: - Window

struct ContentView: View {
    @EnvironmentObject var store: Store
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @State private var page: Page? = .today
    @State private var inspected: UUID?
    @State private var lastInspected: UUID? // what the details button reopens
    @State private var search = ""
    @State private var addingList = false
    @State private var renaming: String?
    @State private var listName = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { ToastView() }
                .animation(.snappy, value: store.toast)
                .inspector(isPresented: Binding(get: { inspected != nil }, set: { if !$0 { inspected = nil } })) {
                    Group {
                        if let id = inspected { Inspector(id: id) { inspected = nil }.id(id) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .onExitCommand { inspected = nil }
                    .inspectorColumnWidth(min: 300, ideal: 350, max: 460)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: newTask) { Label("New Task", systemImage: "plus") }
                            .keyboardShortcut("n")
                            .help("New task (Cmd-N)")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: toggleDetails) {
                            Label(inspected == nil ? "Show Details" : "Hide Details", systemImage: "sidebar.trailing")
                        }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .help(inspected == nil ? "Show details (Option-Cmd-I)" : "Hide details (Esc)")
                        .disabled(inspected == nil && !store.items.contains { $0.id == lastInspected })
                    }
                }
                .onExitCommand { inspected = nil }
                .toolbar(removing: .title)
        }
        .searchable(text: $search, prompt: "Search tasks")
        .alert("New Project", isPresented: $addingList) {
            TextField("Name", text: $listName)
            Button("Add Project") {
                store.addList(listName)
                let n = listName.trimmingCharacters(in: .whitespaces)
                if store.lists.contains(n) { page = .list(n) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $listName)
            Button("Rename") {
                guard let old = renaming else { return }
                store.renameList(old, to: listName)
                if page == .list(old), store.lists.contains(listName) { page = .list(listName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            store.undo = undoManager
            store.openMain = { [openWindow] in openWindow(id: "main") }
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular); NSApp.activate() }
            if let id = store.focusID { inspected = id; store.focusID = nil }
        }
        // Closing the window keeps Todo running in the menu bar, without a Dock icon.
        .onDisappear { if UserDefaults.standard.object(forKey: "menuBar") as? Bool ?? true { NSApp.setActivationPolicy(.accessory) } }
        .onChange(of: store.focusID) {
            guard let id = store.focusID else { return }
            inspected = id
            store.focusID = nil
        }
        .onChange(of: inspected) { if let id = inspected { lastInspected = id } }
        .onChange(of: store.items) {
            if let id = inspected, !store.items.contains(where: { $0.id == id }) { inspected = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refresh() }
    }

    @ViewBuilder private var detail: some View {
        let p = page ?? .today
        if !search.isEmpty {
            TaskListView(page: p, search: search, inspected: $inspected, composerFocused: $composerFocused)
        } else if p == .assistant {
            AssistantView()
        } else if p == .calendar {
            CalendarView(inspected: $inspected, composerFocused: $composerFocused)
        } else {
            TaskListView(page: p, search: "", inspected: $inspected, composerFocused: $composerFocused)
        }
    }

    private func toggleDetails() {
        inspected = inspected == nil ? lastInspected : nil
    }

    private func newTask() {
        search = ""
        if page == .assistant || page == .completed || page == nil { page = .today }
        DispatchQueue.main.async { composerFocused = true }
    }

    private var sidebar: some View {
        List(selection: $page) {
            Section {
                nav(.today, "sun.max", store.todayCount)
                nav(.upcoming, "calendar.day.timeline.left", 0)
                nav(.calendar, "calendar", 0)
                nav(.all, "tray.full", store.openCount)
                nav(.completed, "checkmark.circle", 0)
                nav(.assistant, "sparkles", 0)
            }
            Section("Projects") {
                ForEach(store.lists, id: \.self) { name in
                    Label { Text(name) } icon: {
                        Image(systemName: name == "Inbox" ? "tray" : "number").foregroundStyle(store.color(of: name))
                    }
                    .badge(store.openCount(in: name))
                    .tag(Page.list(name))
                    .dropDestination(for: String.self) { ids, _ in
                        ids.forEach { store.setList(id: $0, name) }
                        return true
                    }
                    .contextMenu { projectMenu(name) }
                }
            }
            if !store.allLabels.isEmpty {
                Section("Labels") {
                    ForEach(store.allLabels, id: \.self) { label in
                        Label(label, systemImage: "tag")
                            .badge(store.openCount(label: label))
                            .tag(Page.label(label))
                            .contextMenu {
                                Button("Remove Label from All Tasks", role: .destructive) {
                                    if page == .label(label) { page = .today }
                                    store.deleteLabel(label)
                                }
                            }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 235)
        .safeAreaInset(edge: .bottom) {
            Button { listName = ""; addingList = true } label: { Label("New Project", systemImage: "plus") }
                .buttonStyle(.borderless)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func projectMenu(_ name: String) -> some View {
        Button("Rename...") { listName = name; renaming = name }.disabled(name == "Inbox")
        Menu("Color") {
            ForEach(palette.indices, id: \.self) { i in Button(paletteNames[i]) { store.colors[name] = i } }
        }
        Divider()
        Button("Delete Project (tasks move to Inbox)", role: .destructive) {
            if page == .list(name) { page = .list("Inbox") }
            store.deleteList(name)
        }
        .disabled(name == "Inbox")
    }

    private func nav(_ p: Page, _ icon: String, _ count: Int) -> some View {
        Label(p.title, systemImage: icon).badge(count).tag(p)
    }
}

struct ToastView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if let toast = store.toast {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                Text(toast.text).lineLimit(1)
                Button("Undo") {
                    store.undo?.undo()
                    store.toast = nil
                }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(.tint)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: toast.id) {
                try? await Task.sleep(for: .seconds(4))
                if store.toast?.id == toast.id { store.toast = nil }
            }
        }
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focused: Bool

    var body: some View {
        let today = store.sections(.today, search: "").flatMap(\.items)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today").font(.title2.bold())
                Spacer()
                Text(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).foregroundStyle(.secondary)
            }
            Composer(defaults: Page.today.template, focused: $focused, allowAI: false)
            if today.isEmpty {
                Text("Nothing left for today.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(today) { t in
                            TaskRow(item: t, inspected: .constant(nil), compact: true) { open(t.id) }
                        }
                    }
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Open Todo") { open(nil) }
                Spacer()
                Button("Quit Todo") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func open(_ id: UUID?) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate()
        if let id { store.focusID = id }
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell") }
            AISettings().tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 520)
    }
}

struct GeneralSettings: View {
    @AppStorage("dailyGoal") private var goal = 5
    @AppStorage("menuBar") private var menuBar = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Stepper("Daily goal: \(plural(goal, "task"))", value: $goal, in: 1...50)
            Toggle("Show today's tasks in the menu bar", isOn: $menuBar)
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { setLoginItem(openAtLogin) }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct NotificationSettings: View {
    @AppStorage("defaultReminder") private var defaultReminder = 0
    @AppStorage("briefing") private var briefing = true
    @AppStorage("briefingTime") private var briefingTime = 8 * 60
    @AppStorage("allDayReminders") private var allDay = false
    @AppStorage("allDayTime") private var allDayTime = 9 * 60
    @State private var status: UNAuthorizationStatus?
    @State private var testSent = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(statusText)
                    Spacer()
                    if status == .notDetermined {
                        Button("Allow Notifications") {
                            Task {
                                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                                await refresh()
                            }
                        }
                    } else if status == .denied {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    } else {
                        Button(testSent ? "Sent" : "Send Test") { sendTest() }.disabled(testSent)
                    }
                }
            }
            Section("Reminders") {
                Picker("New timed tasks remind me", selection: $defaultReminder) {
                    ForEach(reminderOptions(timed: true), id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Remind me about all-day tasks", isOn: $allDay)
                if allDay { DatePicker("At", selection: time($allDayTime), displayedComponents: .hourAndMinute) }
            }
            Section {
                Toggle("Morning summary", isOn: $briefing)
                if briefing { DatePicker("At", selection: time($briefingTime), displayedComponents: .hourAndMinute) }
            } footer: {
                Text("Lists what's due and overdue that day. Reminders have Complete, Snooze and Tomorrow buttons.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task { await refresh() }
        .onChange(of: [defaultReminder, briefingTime, allDayTime, briefing ? 1 : 0, allDay ? 1 : 0]) { Store.shared.rescheduleAll() }
    }

    private var statusText: String {
        switch status {
        case .authorized, .provisional, .ephemeral: return "Notifications are on"
        case .denied: return "Notifications are off for Todo"
        case .notDetermined: return "Todo hasn't asked for permission yet"
        default: return "Checking..."
        }
    }

    private func refresh() async { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }

    private func sendTest() {
        let c = UNMutableNotificationContent()
        c.title = "Reminders are working"
        c.body = "This is how task reminders will look."
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test", content: c,
                                                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))) { _ in }
        testSent = true
    }

    /// Minutes since midnight <-> a Date for DatePicker.
    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: { Calendar.current.date(byAdding: .minute, value: minutes.wrappedValue, to: Calendar.current.startOfDay(for: .now))! },
                set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0) })
    }
}

struct AISettings: View {
    @AppStorage("ollamaURL") private var server = "http://localhost:11434"
    @AppStorage("ollamaModel") private var model = ""
    @State private var models: [String] = []
    @State private var status = ""

    var body: some View {
        Form {
            Section {
                TextField("Ollama server", text: $server)
                Picker("Model", selection: $model) {
                    Text("Automatic").tag("")
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh Models") { Task { await load() } }
                }
            } footer: {
                Text("Models ending in \"cloud\" run on ollama.com, so task text leaves this Mac when you use AI. Local models keep everything on-device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task { await load() }
    }

    private func load() async {
        status = "Connecting..."
        do {
            models = try await Ollama.models()
            if !model.isEmpty && !models.contains(model) { models.insert(model, at: 0) }
            status = "\(plural(models.count, "model")) available"
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: - App

func setLoginItem(_ on: Bool) {
    do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    catch { print("login item:", error.localizedDescription) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Open at login by default, once, and only for the installed copy (not dev or test builds).
        if Bundle.main.bundlePath.hasPrefix("/Applications/"), !UserDefaults.standard.bool(forKey: "loginItemSet") {
            setLoginItem(true)
            UserDefaults.standard.set(true, forKey: "loginItemSet")
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "TASK", actions: [
                UNNotificationAction(identifier: "complete", title: "Complete"),
                UNNotificationAction(identifier: "snooze", title: "Snooze 10 Minutes"),
                UNNotificationAction(identifier: "tomorrow", title: "Move to Tomorrow"),
            ], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in Store.shared.rescheduleAll() }
        }
    }

    // Keep running in the menu bar after the window closes; Quit Todo (or Cmd-Q) ends it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Clicking the widget, or opening Todo from Spotlight or Launchpad while it runs in the background.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Store.shared.showMain() }
        return true
    }

    // Show banners even while the app is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["id"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            let store = Store.shared
            if let id, let t = store.items.first(where: { $0.id.uuidString == id }) {
                switch action {
                case "complete": if !t.done { store.toggle(t) }
                case "snooze": store.snooze(id: id)
                case "tomorrow": store.move(id: id, to: Calendar.current.addDays(1, to: .now))
                default: store.showMain(t.id)
                }
            } else {
                store.showMain()
            }
            completionHandler()
        }
    }
}

/// The app icon's tally mark as a menu bar template image, so it follows the menu bar's colour.
let menuBarGlyph: NSImage = {
    let img = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
        let w: CGFloat = 1.8, x0: CGFloat = (18 - 7 * w) / 2
        NSColor.black.setFill()
        for i in 0..<4 {
            NSBezierPath(roundedRect: NSRect(x: x0 + CGFloat(i) * 2 * w, y: 2, width: w, height: 12), xRadius: w / 2, yRadius: w / 2).fill()
        }
        let strike = NSBezierPath()
        strike.move(to: NSPoint(x: x0 - 1.2, y: 4.2))
        strike.line(to: NSPoint(x: 18 - x0 + 1.2, y: 11.8))
        strike.lineCapStyle = .round
        NSGraphicsContext.current?.compositingOperation = .clear
        strike.lineWidth = w + 2.2
        strike.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor.black.setStroke()
        strike.lineWidth = w
        strike.stroke()
        return true
    }
    img.isTemplate = true
    return img
}()

struct TodoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store.shared
    @AppStorage("menuBar") private var menuBar = true

    var body: some Scene {
        Window("Todo", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 940, minHeight: 600)
        }
        .defaultSize(width: 1240, height: 800)
        Settings { SettingsView() }
        MenuBarExtra(isInserted: $menuBar) {
            MenuBarView().environmentObject(store)
        } label: {
            Image(nsImage: menuBarGlyph).accessibilityLabel("Todo")
        }
        .menuBarExtraStyle(.window)
    }
}

@main
struct Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { selfTest(); return }
        if args.contains("--notiftest") { // sends one test banner in 2 seconds
            let c = UNMutableNotificationContent()
            c.title = "Reminders are working"
            c.body = "This is a test from Todo."
            c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test", content: c,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))) { err in
                print(err.map { "failed: \($0.localizedDescription)" } ?? "test scheduled")
                exit(err == nil ? 0 : 1)
            }
            dispatchMain()
        }
        if args.contains("--notifstatus") { // prints whether macOS lets Todo notify, and what is queued
            print("open at login:", ["notRegistered", "enabled", "requiresApproval", "notFound"][min(SMAppService.mainApp.status.rawValue, 3)])
            UNUserNotificationCenter.current().getNotificationSettings { s in
                print(["notDetermined", "denied", "authorized", "provisional", "ephemeral"][min(s.authorizationStatus.rawValue, 4)])
                UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
                    let f = DateFormatter(); f.dateFormat = "EEE MMM d, HH:mm"
                    for r in reqs.sorted(by: { ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
                                               < ($1.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture }) {
                        let when = (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate().map(f.string) ?? "?"
                        print("  \(when)  \(r.content.title)")
                    }
                    print("\(reqs.count) queued")
                    exit(0)
                }
            }
            dispatchMain()
        }
        if args.contains("--aitest") {
            Task { await aiTest(); exit(0) }
            dispatchMain()
        }
        TodoApp.main()
    }
}
