import SwiftUI
import UserNotifications

struct AIError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Ollama client

@MainActor enum Ollama {
    struct Message: Codable, Equatable {
        var role: String
        var content: String
    }

    static var server: String {
        let s = UserDefaults.standard.string(forKey: "ollamaURL")?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? "http://localhost:11434" : s
    }

    static func endpoint(_ path: String) throws -> URL {
        let base = server.hasSuffix("/") ? server : server + "/"
        guard let url = URL(string: base + path), url.scheme != nil else { throw AIError("Invalid Ollama server address: \(server)") }
        return url
    }

    static func models() async throws -> [String] {
        struct Tags: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
        let data: Data
        do { (data, _) = try await URLSession.shared.data(from: endpoint("api/tags")) }
        catch { throw AIError("Can't reach Ollama at \(server). Is it running?") }
        return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name)
            .filter { !$0.localizedCaseInsensitiveContains("embed") }
    }

    static func model() async throws -> String {
        if let m = UserDefaults.standard.string(forKey: "ollamaModel"), !m.isEmpty { return m }
        let all = try await models()
        // ponytail: fast models that returned clean JSON in testing; otherwise the first installed model
        let preferred = ["mimo-v2.6-flash:cloud", "glm-5.3-flash:cloud", "minimax-m3.1-flash:cloud"]
        if let m = preferred.first(where: all.contains) ?? all.first { return m }
        throw AIError("Ollama has no chat models installed. Run `ollama pull <model>`, then pick it in Settings.")
    }

    /// Streams a chat completion; `onToken` gets each piece of the answer as it arrives, and `onThinking`
    /// each piece of a reasoning model's thinking, which Ollama streams separately before the answer.
    @discardableResult
    static func chat(_ messages: [Message], json: Bool = false, onToken: ((String) -> Void)? = nil,
                     onThinking: ((String) -> Void)? = nil) async throws -> String {
        var req = URLRequest(url: try endpoint("api/chat"), timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": try await model(), "stream": true,
                                   "messages": messages.map { ["role": $0.role, "content": $0.content] }]
        if json { body["format"] = "json" }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await URLSession.shared.bytes(for: req) }
        catch { throw AIError("Can't reach Ollama at \(server). Is it running?") }

        var out = ""
        for try await line in bytes.lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if let err = obj["error"] as? String { throw AIError("Ollama: \(err)") }
            let message = obj["message"] as? [String: Any]
            if let thought = message?["thinking"] as? String, !thought.isEmpty { onThinking?(thought) }
            if let piece = message?["content"] as? String, !piece.isEmpty {
                out += piece
                onToken?(piece)
            }
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw AIError("Ollama returned HTTP \(http.statusCode).") }
        return out
    }

    static func json(system: String, user: String) async throws -> [String: Any] {
        let raw = try await chat([Message(role: "system", content: system), Message(role: "user", content: user)], json: true)
        let text = raw.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        // Some cloud models ignore `format`, so take the outermost {...} from whatever came back.
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let obj = (try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8))) as? [String: Any]
        else { throw AIError("The model didn't return usable JSON. Try a different model in Settings (Cmd-,).") }
        return obj
    }
}

// MARK: - AI features

@MainActor enum AI {
    static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The next two weeks spelled out, so models don't miscount weekdays ("next Monday").
    static var upcomingDays: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE yyyy-MM-dd"
        return (0..<14).map { f.string(from: Calendar.current.addDays($0, to: .now)) }.joined(separator: ", ")
    }

    static var now: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE yyyy-MM-dd, HH:mm"
        return f.string(from: .now)
    }

    /// Free text ("brain dump") to tasks. Nothing is added until the user reviews them.
    static func extractTasks(_ text: String, store: Store, defaults: TodoItem = TodoItem()) async throws -> [TodoItem] {
        let labels = store.allLabels.isEmpty ? "none yet" : store.allLabels.joined(separator: ", ")
        let system = """
        You turn the user's text into todo tasks. Now: \(now). Today and the next 13 days: \(upcomingDays).
        Projects: \(store.lists.joined(separator: ", ")). Existing labels: \(labels).
        Rules: one task per distinct action, with a short imperative title. Resolve relative dates to YYYY-MM-DD. \
        Set "time" (24h HH:MM) only if the user gave a time. priority: 1 urgent, 2 high, 3 medium, 4 none (default 4). \
        "project" must be one of the projects or null. At most 2 labels, prefer existing ones. \
        "subtasks" only when the user listed items or steps. \
        Set "remind" (minutes before the due time, 0 = at the due time) only when the user asks to be reminded; \
        a reminder needs a time, so use 09:00 if they gave none.
        Reply with JSON only: {"tasks":[{"title":string,"notes":string,"due":"YYYY-MM-DD" or null,"time":"HH:MM" or null,\
        "priority":1-4,"project":string or null,"labels":[string],"repeat":"none|daily|weekdays|weekly|monthly|yearly","subtasks":[string],\
        "remind":number or null}]}
        """
        let obj = try await Ollama.json(system: system, user: text)
        guard let raw = obj["tasks"] as? [[String: Any]] else { throw AIError("The model's reply had no tasks in it.") }
        let tasks = raw.compactMap { task(from: $0, lists: store.lists, defaults: defaults) }
        if tasks.isEmpty { throw AIError("No tasks found in that text.") }
        return tasks
    }

    /// Validates every field: models get creative with types and values.
    static func task(from o: [String: Any], lists: [String], defaults: TodoItem) -> TodoItem? {
        guard let title = (o["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        var t = defaults
        t.id = UUID()
        t.created = .now
        t.title = String(title.prefix(200))
        t.notes = (o["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        applyDate(o, to: &t)
        let p = (o["priority"] as? NSNumber)?.intValue ?? Int(o["priority"] as? String ?? "")
        if let p, (1...4).contains(p) { t.priority = 4 - p }
        if let name = o["project"] as? String, let match = lists.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            t.list = match
        }
        for raw in (o["labels"] as? [Any] ?? []).compactMap({ $0 as? String }).prefix(3) {
            let l = raw.trimmingCharacters(in: CharacterSet(charactersIn: "@# ")).lowercased()
            if !l.isEmpty && !t.labels.contains(l) { t.labels.append(l) }
        }
        if let r = (o["repeat"] as? String).flatMap({ Recurrence(rawValue: $0.lowercased()) }), r != .none {
            t.repeats = r
            if t.due == nil { t.due = Calendar.current.startOfDay(for: .now) }
        }
        let subs = (o["subtasks"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        t.subtasks = subs.prefix(20).map { Subtask(title: $0) }
        if let r = int(o["remind"]), r >= 0 { setReminder(r, on: &t) }
        return t
    }

    static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue ?? (v as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    /// Reads "due" (YYYY-MM-DD) and "time" (HH:MM) from the model's JSON. A time alone moves the task's current day.
    static func applyDate(_ o: [String: Any], to t: inout TodoItem) {
        let cal = Calendar.current
        let day = (o["due"] as? String).flatMap { ymd.date(from: $0) }
        let hm = (o["time"] as? String)?.split(separator: ":").compactMap { Int($0) } ?? []
        let time = hm.count >= 2 && (0..<24).contains(hm[0]) && (0..<60).contains(hm[1]) ? (hm[0], hm[1]) : nil
        guard day != nil || time != nil else { return }
        let base = cal.startOfDay(for: day ?? t.due ?? .now)
        if let (h, m) = time {
            t.due = cal.date(bySettingHour: h, minute: m, second: 0, of: base)
            t.hasTime = true
        } else if t.hasTime, let old = t.due {
            let c = cal.dateComponents([.hour, .minute], from: old)
            t.due = cal.date(bySettingHour: c.hour ?? 9, minute: c.minute ?? 0, second: 0, of: base)
        } else {
            t.due = base
        }
    }

    /// Snaps to an option the inspector offers, and gives the task a time (the all-day reminder time) if it
    /// has none, so the reminder fires even when all-day reminders are off.
    static func setReminder(_ minutes: Int, on t: inout TodoItem) {
        let options = reminderOptions(timed: true).map(\.0).filter { $0 >= 0 }
        t.reminder = options.min { abs($0 - minutes) < abs($1 - minutes) } ?? 0
        if t.due == nil || !t.hasTime {
            t.due = Calendar.current.date(byAdding: .minute, value: Prefs.allDayTime, to: Calendar.current.startOfDay(for: t.due ?? .now))
            t.hasTime = true
        }
    }

    static func reminderText(_ t: TodoItem) -> String? {
        guard let fire = Store.reminderDate(t) else { return nil }
        return fire < .now ? "Reminder time has already passed" : "Reminder " + dueLabel(fire, time: true)
    }

    /// Applies the `<actions>{...}</actions>` block at the end of an assistant reply, as one undo step.
    /// Returns what changed, or nil when the reply has no block.
    static func applyActions(in reply: String, store: Store) -> [AIChange]? {
        guard let start = reply.range(of: "<actions>") else { return nil }
        var body = reply[start.upperBound...]
        if let end = body.range(of: "</actions>") { body = body[..<end.lowerBound] }
        guard let a = body.firstIndex(of: "{"), let b = body.lastIndex(of: "}"), a < b,
              let obj = (try? JSONSerialization.jsonObject(with: Data(body[a...b].utf8))) as? [String: Any] else { return [] }

        var all = store.items
        var changes: [AIChange] = []
        for o in obj["remind"] as? [[String: Any]] ?? [] {
            let key = (o["id"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let title = o["title"] as? String ?? ""
            guard let minutes = int(o["minutes_before"]) ?? int(o["remind"]),
                  let i = all.firstIndex(where: { !$0.done && key.count >= 4 && $0.id.uuidString.lowercased().hasPrefix(key) })
                      ?? all.firstIndex(where: { !$0.done && $0.title.caseInsensitiveCompare(title) == .orderedSame })
            else { continue }
            applyDate(o, to: &all[i])
            setReminder(max(minutes, 0), on: &all[i])
            changes.append(AIChange(task: all[i].id, icon: "bell", title: all[i].title, detail: reminderText(all[i]) ?? "", reminder: true))
        }
        let new = (obj["add"] as? [[String: Any]] ?? []).compactMap { task(from: $0, lists: store.lists, defaults: TodoItem()) }
        for t in new {
            let parts = [t.due.map { "Due " + dueLabel($0, time: t.hasTime) }, reminderText(t), t.list == "Inbox" ? nil : "#" + t.list]
            changes.append(AIChange(task: t.id, icon: "plus.circle", title: t.title, detail: parts.compactMap { $0 }.joined(separator: ". "),
                                    reminder: Store.reminderDate(t) != nil))
        }
        guard !changes.isEmpty else { return [] }
        store.items = all + new // one assignment: one undo step, one save
        let reminders = changes.filter { $0.icon == "bell" }.count
        store.toast = Toast(text: [new.isEmpty ? nil : "Added " + plural(new.count, "task"),
                                   reminders == 0 ? nil : "set " + plural(reminders, "reminder")]
            .compactMap { $0 }.joined(separator: ", ").capitalizedFirst)
        return changes
    }

    /// The part of a reply to show in the chat: no action block (even half-streamed) and no <think> section.
    static func visibleText(_ s: String) -> String {
        var t = s
        if let r = t.range(of: "<actions>") { t = String(t[..<r.lowerBound]) }
        else if let lt = t.lastIndex(of: "<"), "<actions>".hasPrefix(t[lt...]) { t = String(t[..<lt]) }
        return t.replacingOccurrences(of: #"(?s)<think>.*?(</think>|$)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"```[a-z]*\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func subtasks(for item: TodoItem) async throws -> [String] {
        let system = """
        You break a todo task into 3 to 7 concrete next actions, in order, each under 8 words. \
        Skip steps that are already listed. Reply with JSON only: {"subtasks":[string]}
        """
        var user = "Task: \(item.title)"
        if !item.notes.isEmpty { user += "\nNotes: \(item.notes)" }
        if !item.subtasks.isEmpty { user += "\nAlready listed: " + item.subtasks.map(\.title).joined(separator: "; ") }
        let obj = try await Ollama.json(system: system, user: user)
        let steps = (obj["subtasks"] as? [Any] ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if steps.isEmpty { throw AIError("The model didn't suggest any subtasks.") }
        return Array(steps.prefix(10))
    }

    static func assistantSystem(_ store: Store) -> String {
        """
        You are the assistant inside the user's todo app. Now: \(now). Today and the next 13 days: \(upcomingDays).
        Be concise and practical: short paragraphs or short bullet lists, no tables, no emoji.
        Ground answers in the tasks below and say when something isn't there. Priorities: P1 is most urgent, P4 is none.
        You can add tasks and set reminders, but only when the user asks (for example "add", "remind me", "don't let me forget"). \
        Then reply with one short sentence saying what you did, followed by one block in exactly this form:
        <actions>{"add":[{"title":string,"notes":string,"due":"YYYY-MM-DD" or null,"time":"HH:MM" or null,"priority":1-4,\
        "project":string or null,"labels":[string],"repeat":"none|daily|weekdays|weekly|monthly|yearly","subtasks":[string],\
        "remind":minutes before due or null}],"remind":[{"id":string,"due":"YYYY-MM-DD" or null,"time":"HH:MM" or null,"minutes_before":number}]}</actions>
        Use "remind" for tasks already in the list, with the id shown at the start of the task's line. Use "add" for new tasks, \
        setting its "remind" when the user wants a reminder. A reminder needs a time: use the one the user gave, and if they gave none, \
        ask instead of guessing. "In 20 minutes" means now plus 20 minutes with 0 minutes before. Leave out keys you don't need. \
        Never say you changed something without the block. Projects: \(store.lists.joined(separator: ", ")).
        Open tasks (id first):
        \(store.digest())
        """
    }
}

// MARK: - Assistant chat

struct AssistantView: View {
    @EnvironmentObject var store: Store
    @AppStorage("ollamaModel") private var model = ""
    @State private var messages: [Ollama.Message] = []
    @State private var input = ""
    @State private var running: Task<Void, Never>?
    @State private var converting = false
    @State private var review: [TodoItem]?
    @State private var error: String?
    @State private var changes: [Int: [AIChange]] = [:] // keyed by message index
    @State private var notices: [Int: String] = [:]
    @State private var thinking = "" // tail of the model's reasoning while it hasn't answered yet
    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "Plan my day",
        "What's overdue, and what should I do about it?",
        "Summarize my week ahead",
        "Which tasks could I drop, delegate or batch together?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if messages.isEmpty { intro }
                        ForEach(Array(messages.enumerated()), id: \.offset) { i, m in
                            bubble(m, index: i, streaming: running != nil && i == messages.count - 1)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 28)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: messages) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: thinking.isEmpty) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            inputBar
        }
        .background(pageBackground)
        .toolbar {
            ToolbarItem {
                Button("Clear Chat") { running?.cancel(); messages = []; changes = [:]; notices = [:] }.disabled(messages.isEmpty)
            }
        }
        .sheet(isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
            AIReviewSheet(tasks: review ?? [])
        }
        .alert("AI request failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about your tasks").font(.largeTitle.bold())
            Text("Answers come from \(model.isEmpty ? "your Ollama models" : model), with your open tasks as context. Models ending in \"cloud\" run on ollama.com, so your task text leaves this Mac. Change the model in Settings.\n\nIt can also add tasks and set reminders for you. Try \u{201C}remind me to call the bank tomorrow at 10\u{201D}.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(suggestions, id: \.self) { s in Button(s) { send(s) } }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.top, 10)
        }
    }

    @ViewBuilder private func bubble(_ m: Ollama.Message, index: Int, streaming: Bool) -> some View {
        if m.role == "user" {
            Text(m.content)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 80)
        } else {
            let text = AI.visibleText(m.content)
            VStack(alignment: .leading, spacing: 12) {
                if text.isEmpty && streaming {
                    ThinkingBox(text: thinking)
                } else if !text.isEmpty {
                    Text(markdown(text)).textSelection(.enabled).lineSpacing(3)
                }
                if changes[index] != nil || notices[index] != nil {
                    receipt(changes[index] ?? [], notice: notices[index])
                } else if !streaming && !text.isEmpty {
                    Button { convert(text) } label: { Label(converting ? "Drafting tasks..." : "Turn into tasks", systemImage: "sparkles") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                        .disabled(converting)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What the assistant changed. Each line opens that task; the toast offers Undo.
    private func receipt(_ list: [AIChange], notice: String?) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(list) { c in
                    Button { store.focusID = c.task } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: c.icon).foregroundStyle(.tint).frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).fontWeight(.medium)
                                if !c.detail.isEmpty { Text(c.detail).font(.callout).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show task details")
                }
                if let notice {
                    Text(notice).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 460, alignment: .leading)
    }

    private var inputBar: some View {
        let empty = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 6) {
            TextField("Message", text: $input, prompt: Text("Ask about your tasks, or say \u{201C}remind me to...\u{201D}"), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($inputFocused)
                .onAppear { inputFocused = true }
                .padding(.vertical, 6)
                .onSubmit { send(input) }
            Button { if running != nil { running?.cancel() } else { send(input) } } label: {
                Image(systemName: running != nil ? "stop.circle.fill" : "arrow.up.circle.fill").font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .foregroundStyle(running == nil && empty ? Color.secondary : Color.accentColor)
            .disabled(running == nil && empty)
            .help(running != nil ? "Stop" : "Send")
        }
        .padding(.leading, 14).padding(.trailing, 5).padding(.vertical, 3)
        .background(pageBackground, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(nsColor: .separatorColor)))
        .padding(.horizontal, 40).padding(.bottom, 18).padding(.top, 8)
        .frame(maxWidth: 780)
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, running == nil else { return }
        input = ""
        messages.append(Ollama.Message(role: "user", content: q))
        let history = [Ollama.Message(role: "system", content: AI.assistantSystem(store))] + messages
        messages.append(Ollama.Message(role: "assistant", content: ""))
        thinking = ""
        running = Task {
            do {
                try await Ollama.chat(history, onToken: { piece in
                    if !Task.isCancelled && !messages.isEmpty { messages[messages.count - 1].content += piece }
                }, onThinking: { thought in
                    thinking = String((thinking + thought).suffix(4000))
                })
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            if messages.last?.role == "assistant" && messages.last?.content.isEmpty == true { messages.removeLast() }
            if !Task.isCancelled, let i = messages.indices.last, messages[i].role == "assistant",
               let applied = AI.applyActions(in: messages[i].content, store: store) {
                if applied.isEmpty {
                    notices[i] = "The assistant tried to change your tasks, but its change list couldn't be read. Nothing was changed."
                } else {
                    changes[i] = applied
                    if applied.contains(where: \.reminder),
                       await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied {
                        notices[i] = "Notifications are off for Todo, so these reminders won't appear. Turn them on in System Settings."
                    }
                }
            }
            running = nil
        }
    }

    private func convert(_ text: String) {
        converting = true
        Task {
            defer { converting = false }
            do { review = try await AI.extractTasks(text, store: store) }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// A reasoning model's thinking, streamed into a short window that keeps scrolling to the newest text.
struct ThinkingBox: View {
    let text: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking").foregroundStyle(.secondary)
                }
                if !text.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Color.clear.frame(height: 1).id("end")
                            }
                        }
                        .scrollIndicators(.never)
                        .frame(height: 104)
                        // Older lines fade out at the top as new ones push them up.
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.35)],
                                             startPoint: .top, endPoint: .bottom))
                        .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                        .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

// MARK: - Review AI-proposed tasks before adding

struct AIReviewSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let tasks: [TodoItem]
    @State private var skipped: Set<UUID> = []

    var body: some View {
        let count = tasks.count - skipped.count
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(plural(tasks.count, "suggested task")).font(.title2.bold())
                Text("Untick anything you don't want. You can edit tasks after adding them.").foregroundStyle(.secondary)
            }
            List {
                ForEach(tasks) { t in
                    Toggle(isOn: Binding(get: { !skipped.contains(t.id) },
                                         set: { on in if on { skipped.remove(t.id) } else { skipped.insert(t.id) } })) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.title)
                                if !t.notes.isEmpty { Text(t.notes).font(.callout).foregroundStyle(.secondary) }
                                if TaskMeta.has(t) { TaskMeta(item: t) }
                                if !t.subtasks.isEmpty {
                                    Text(t.subtasks.map(\.title).joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 12)
                            if t.list != "Inbox" { ProjectTag(name: t.list) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.bordered)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(plural(count, "Task"))") {
                    store.add(tasks.filter { !skipped.contains($0.id) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
            }
        }
        .padding(20)
        .frame(width: 560, height: 470)
    }
}

// MARK: - Live check against Ollama (run: Todo.app/Contents/MacOS/Todo --aitest)

@MainActor func aiTest() async {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("todo-aitest-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = Store(url: url)
    do {
        print("model:", try await Ollama.model())
        let tasks = try await AI.extractTasks("finish the q4 deck for work by tuesday, super urgent. call mom sunday at 7pm and remind me an hour before. gym every weekday. buy eggs, milk and bread", store: store)
        for t in tasks {
            print("-", t.title, "|", t.due.map { dueLabel($0, time: t.hasTime) } ?? "no date", "|", priorityName(t.priority),
                  "| #\(t.list)", t.labels.map { "@" + $0 }.joined(separator: " "), "|", t.repeats.label, "|", t.subtasks.map(\.title),
                  "|", AI.reminderText(t) ?? "no reminder")
        }
        guard !tasks.isEmpty else { print("FAIL: no tasks"); exit(1) }
        print("subtasks:", try await AI.subtasks(for: tasks[0]))
        store.add(tasks)
        var answer = ""
        try await Ollama.chat([Ollama.Message(role: "system", content: AI.assistantSystem(store)),
                               Ollama.Message(role: "user", content: "Plan my day in 3 bullets")], onToken: { answer += $0 })
        print("assistant:", answer)
        var reply = ""
        try await Ollama.chat([Ollama.Message(role: "system", content: AI.assistantSystem(store)),
                               Ollama.Message(role: "user", content: "Add a task to book the dentist tomorrow at 3pm and remind me 30 minutes before. Also remind me about the Q4 deck at 9am on the day it's due.")], onToken: { reply += $0 })
        print("assistant reply:", AI.visibleText(reply))
        guard let changed = AI.applyActions(in: reply, store: store), !changed.isEmpty else { print("FAIL: no changes applied. Raw reply:", reply); exit(1) }
        for c in changed { print("changed:", c.icon, "|", c.title, "|", c.detail) }
        print("aitest passed")
    } catch {
        print("FAIL:", error.localizedDescription)
        exit(1)
    }
}
