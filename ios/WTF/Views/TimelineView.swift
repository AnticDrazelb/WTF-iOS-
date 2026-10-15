import SwiftData
import SwiftUI
import UIKit
import WTFCore

struct TimelineView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Conversation.start, order: .reverse) private var conversations: [Conversation]
    @Query(filter: #Predicate<Chunk> { $0.status == "pending" }) private var pending: [Chunk]
    @State private var query = ""
    @State private var deleting: Conversation?
    @State private var renaming: Conversation?
    @State private var newTitle = ""

    private var shown: [Conversation] {
        // Not ones being deleted: a row left showing one as it goes would crash the app.
        let visible = conversations.filter { !model.hiding.contains($0.persistentModelID) }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return visible }
        return visible.filter { c in
            [c.title, c.summary, c.transcript].contains { $0?.lowercased().contains(q) == true }
        }
    }

    /// The days, newest first, each with its conversations.
    private var byDay: [(day: Date, header: String, list: [Conversation])] {
        var out: [(day: Date, header: String, list: [Conversation])] = []
        for c in shown {
            let day = Calendar.current.startOfDay(for: c.start)
            if out.last?.day == day { out[out.count - 1].list.append(c) } else { out.append((day, dayHeader(c.start), [c])) }
        }
        return out
    }

    private var searching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.timelinePath) {
            List {
                if !pending.isEmpty || model.transcribing != nil {
                    Section { TranscribingRow(pending: pending.count) }
                }
                ForEach(byDay, id: \.day) { day, header, list in
                    Section {
                        // The whole day at a glance, then each conversation. (Not while searching.)
                        if !searching {
                            YourDayRow(day: day, conversations: list)
                                .background { NavigationLink(value: DayRef(day: day)) { EmptyView() }.opacity(0) }
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                        }
                        ForEach(list) { c in
                            TimelineEntry(conversation: c)
                                .background { NavigationLink(value: c) { EmptyView() }.opacity(0) }
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                                .contextMenu {
                                    Button("Ask About This", systemImage: "questionmark.bubble") {
                                        model.tab = 0
                                        model.ask(c.title.map { "What happened in \u{201C}\($0)\u{201D}?" } ?? "What was said then?", focus: c.id)
                                    }
                                    if let summary = c.summary {
                                        Button("Copy Summary", systemImage: "doc.on.doc") {
                                            UIPasteboard.general.string = [c.title, summary].compactMap { $0 }.joined(separator: "\n")
                                        }
                                    }
                                    ShareLink(item: shareText(c)) { Label("Share", systemImage: "square.and.arrow.up") }
                                    Button("Rename\u{2026}", systemImage: "pencil") { newTitle = c.title ?? ""; renaming = c }
                                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = c }
                                }
                        }
                    } header: {
                        Text(header).font(.subheadline).foregroundStyle(.secondary).textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if conversations.isEmpty && pending.isEmpty {
                    ContentUnavailableView("No Conversations", systemImage: "waveform",
                                           description: Text(model.recording ? "Your conversations will appear here once WTF has heard some talking." : "Turn on listening and your conversations will appear here."))
                } else if !query.isEmpty && shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Search everything you've heard")
            .refreshable { await model.pipeline.run() }
            .navigationTitle("Timeline")
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let c = renaming, !t.isEmpty {
                        c.title = t
                        if c.summary == nil { c.summary = "" } // named by you: not summarised over
                        try? c.modelContext?.save()
                    }
                }
            }
            .confirmationDialog("Delete this conversation?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let id = deleting?.id { Task { await model.deleteConversation(id) } }
                    deleting = nil
                }
            } message: {
                Text("Its transcript, recording and suggestions go too. This can\u{2019}t be undone.")
            }
            .navigationDestination(for: Conversation.self) { ConversationView(conversation: $0) }
            .navigationDestination(for: DayRef.self) { DayView(day: $0.day) }
            .toolbar { ToolbarItem(placement: .topBarLeading) { ListeningButton() } }
        }
    }
}

struct TranscribingRow: View {
    @Environment(AppModel.self) private var model
    let pending: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hourglass").foregroundStyle(.secondary)
                .frame(width: 29, height: 29)
            if let p = model.transcribing {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.total > 1 ? "Transcribing \(p.done + 1) of \(p.total)\u{2026}" : "Transcribing\u{2026}")
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                }
                ProgressView()
            } else {
                Text("\(pending) recording\(pending == 1 ? "" : "s") still to transcribe")
                Spacer()
                Button("Transcribe Now") { model.processNow() }
                    .sensoryFeedback(.selection, trigger: model.transcribing != nil)
            }
        }
    }
}

/// The day as a timeline: a line down the side, each conversation pinned to it at its time,
/// and under it the topics it wandered through; a tangent (after one was left hanging) steps in.
struct TimelineEntry: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    private var live: Bool { !conversation.closed && conversation.summary == nil }

    var body: some View {
        let topics = Threads.layout(conversation.threads)
        HStack(alignment: .top, spacing: 0) {
            Text(conversation.start, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 58, alignment: .trailing)
                .fixedSize()
                .padding(.top, 14).padding(.trailing, 8)
            // The line, and this conversation's place on it.
            VStack(spacing: 0) {
                Rectangle().fill(.quaternary).frame(width: 1.5, height: 16)
                Circle().fill(live ? Color.primary : Color.secondary).frame(width: 9, height: 9)
                Rectangle().fill(.quaternary).frame(width: 1.5).frame(maxHeight: .infinity)
            }
            .frame(width: 12)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(displayTitle(conversation)).font(.headline).lineLimit(2)
                        Spacer(minLength: 4)
                        if live { Text("Live").font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                    }
                    if !preview.isEmpty {
                        Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
                if !topics.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(topics.prefix(6).enumerated()), id: \.offset) { _, item in
                            TopicNode(thread: item.thread, tangent: item.tangent)
                        }
                        if topics.count > 6 {
                            Text("+ \(topics.count - 6) more").font(.caption).foregroundStyle(.secondary).padding(.leading, 14)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
            .padding(.leading, 10).padding(.vertical, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var preview: String {
        if let first = conversation.summary?.split(separator: "\n").first {
            return String(first).trimmingCharacters(in: CharacterSet(charactersIn: "\u{2022}- "))
        }
        return conversation.transcript.split(separator: "\n").last.map { line in
            String(line).components(separatedBy: ": ").dropFirst().joined(separator: ": ")
        } ?? ""
    }
}

/// One topic on the timeline: a small dot, its name and what was settled; dropped part-way, a
/// hollow dot; a tangent, stepped in under a turn arrow.
struct TopicNode: View {
    let thread: TopicThread
    let tangent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if tangent {
                Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary)
            }
            Group {
                if thread.status == .hanging {
                    Circle().strokeBorder(Color.secondary, lineWidth: 1)
                } else {
                    Circle().fill(thread.status == .current ? Color.primary : Color.secondary)
                }
            }
            .frame(width: 6, height: 6)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            VStack(alignment: .leading, spacing: 1) {
                Text(thread.title).font(.subheadline).foregroundStyle(thread.status == .current ? .primary : .secondary)
                if let facts = thread.facts, !facts.isEmpty {
                    Text(facts).font(.caption).foregroundStyle(.secondary)
                } else if thread.status == .hanging {
                    Text("Left hanging").font(.caption).italic().foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, tangent ? 10 : 0)
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(displayTitle(conversation)).font(.headline).lineLimit(1)
                Spacer()
                if !conversation.closed && conversation.summary == nil {
                    Label("Live", systemImage: "circle.fill").font(.subheadline).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                        .imageScale(.small)
                } else {
                    Text(conversation.start, format: .dateTime.hour().minute()).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var preview: String {
        if let first = conversation.summary?.split(separator: "\n").first {
            return String(first).trimmingCharacters(in: CharacterSet(charactersIn: "\u{2022}- "))
        }
        return conversation.transcript.split(separator: "\n").last.map { line in
            String(line).components(separatedBy: ": ").dropFirst().joined(separator: ": ")
        } ?? ""
    }
}

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    @State private var confirmDelete = false
    /// The voice being named, and what's typed.
    @State private var naming: String?
    @State private var typed = ""
    @State private var note: String?
    @State private var saved = 0
    /// The line being fixed, and its words as they're being edited.
    @State private var fixing: String?
    @State private var fixedText = ""
    /// "Is Speaker 2 Sarah?" suggestions turned down, and the ones worked out (off the main path).
    @AppStorage("declinedNames") private var declined = ""
    @State private var hints: [NameHints.Hint] = []

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(displayTitle(conversation)).font(.title2.bold())
                    Text("\(dayLabel(conversation.start)), \(conversation.start.formatted(date: .omitted, time: .shortened))\u{2013}\(conversation.end.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            if let summary = conversation.summary, !summary.isEmpty {
                Section("Summary") { Text(summary) }
            }
            if !conversation.threads.isEmpty {
                Section("Topics") {
                    ThreadList(threads: conversation.threads) { model.askAbout($0, in: conversation.id) }
                }
            }
            if let hint = nameHints.first {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Is \(hint.label) \(hint.name)?").font(.headline)
                        Text("Someone called them \(hint.name)\(hint.times > 1 ? " \(hint.times) times" : "").")
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            Button("Yes") { name(hint.label, as: hint.name) }.buttonStyle(.bordered)
                            Button("No") { declined += "\n" + key(hint) }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                        .buttonBorderShape(.capsule)
                    }
                    .padding(.vertical, 4)
                }
            }
            Section {
                ForEach(Array(conversation.transcript.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                    let parts = parse(String(line))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if let who = parts.speaker {
                                Menu { voiceMenu(who) } label: {
                                    Text(who).font(.subheadline.weight(.semibold)).foregroundStyle(VoiceColor.of(who))
                                }
                            }
                            Text(parts.time).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(parts.text)
                    }
                    .contextMenu {
                        Button("Fix Words\u{2026}", systemImage: "character.cursor.ibeam") {
                            fixedText = parts.text
                            fixing = String(line)
                        }
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = parts.text }
                    }
                }
            } header: {
                Text("Transcript")
            } footer: {
                if let note { Text(note) }
                else if hasUnnamedVoices { Text("Tap a speaker to say who it is. WTF will know their voice from then on.") }
            }
            Section {
                Button("Delete Conversation", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(conversation.start.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ShareLink(item: shareText(conversation)) }
        .sensoryFeedback(.success, trigger: saved)
        .alert(naming.map { Labels.number($0) != nil ? "Who\u{2019}s \($0)?" : "Rename \($0)" } ?? "",
               isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $typed).textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let label = naming { name(label, as: typed) } }
        } message: {
            Text("WTF will recognise their voice from now on, here and in your other conversations.")
        }
        .task(id: conversation.transcript) {
            hints = hasUnnamedVoices ? NameHints.suggest(conversation.transcript, isName: NameCheck.isName) : []
        }
        .sheet(isPresented: Binding(get: { fixing != nil }, set: { if !$0 { fixing = nil } })) {
            FixWordsSheet(text: $fixedText) { save in
                if save, let line = fixing {
                    let id = conversation.id, typed = fixedText
                    Task {
                        if await model.pipeline.fixLine(in: id, original: line, text: typed) {
                            saved += 1
                            note = "Fixed. WTF will catch that next time."
                        } else {
                            note = "That line changed while you were fixing it, so nothing was changed. Try again."
                        }
                    }
                }
                fixing = nil
            }
        }
        .confirmationDialog("Delete this conversation?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let id = conversation.id
                dismiss()
                Task { await model.deleteConversation(id) }
            }
        }
    }

    @ViewBuilder private func voiceMenu(_ who: String) -> some View {
        if who != Labels.me {
            Button("That\u{2019}s Me", systemImage: "person.crop.circle") { name(who, as: Labels.me) }
        }
        Button(Labels.number(who) != nil ? "Name This Voice\u{2026}" : "Rename\u{2026}", systemImage: "pencil") {
            typed = Labels.number(who) == nil && who != Labels.me ? who : ""
            naming = who
        }
    }

    /// Names for unnamed voices from how people were addressed, minus any turned down.
    private var nameHints: [NameHints.Hint] {
        let no = Set(declined.split(separator: "\n").map(String.init))
        return hints.filter { !no.contains(key($0)) && Labels.speakers(in: conversation.transcript).contains($0.label) }
    }

    private func key(_ hint: NameHints.Hint) -> String { "\(conversation.id.uuidString)|\(hint.label)|\(hint.name)" }

    private var hasUnnamedVoices: Bool {
        Labels.speakers(in: conversation.transcript).contains { Labels.number($0) != nil }
    }

    private func name(_ label: String, as typed: String) {
        let id = conversation.id
        Task {
            if Labels.number(label) == nil, label != Labels.me, await model.pipeline.renamePerson(named: label, to: typed) {
                saved += 1
                note = "Renamed in every conversation."
                return
            }
            guard let done = await model.pipeline.nameVoice(in: id, label: label, as: typed) else {
                note = "That name can\u{2019}t be used: try a shorter one, without numbers."
                return
            }
            saved += 1
            let who = done.name == Labels.me ? "you" : done.name
            note = done.elsewhere > 0
                ? "Also found \(who) in \(done.elsewhere) other conversation\(done.elsewhere == 1 ? "" : "s")."
                : "WTF will recognise \(who) from now on."
        }
    }

    private func parse(_ line: String) -> (time: String, speaker: String?, text: String) {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return ("", nil, line) }
        let time = String(line[line.index(after: line.startIndex)..<close].prefix(5))
        let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard let colon = rest.range(of: ": ") else { return (time, nil, rest) }
        let who = String(rest[..<colon.lowerBound])
        let text = String(rest[colon.upperBound...])
        return (time, who == Labels.anonymous ? nil : who, text)
    }
}

/// Correcting what was misheard in a line: the words, editable.
struct FixWordsSheet: View {
    @Binding var text: String
    let done: (Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What was said", text: $text, axis: .vertical)
                        .lineLimit(3...12)
                } footer: {
                    Text("Change only what was misheard. WTF learns the correction, so the same mistake is caught next time.")
                }
            }
            .navigationTitle("Fix Words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(false) } }
                ToolbarItem(placement: .topBarTrailing) { Button("Save") { done(true) }.fontWeight(.semibold).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Speakers in quiet type: you in full black (or white), everyone else in grey.
enum VoiceColor {
    static func of(_ label: String) -> Color { label == Labels.me ? .primary : .secondary }
}

/// Its title, or what's happening until it has one.
func displayTitle(_ c: Conversation) -> String {
    if let title = c.title { return title }
    if !c.closed { return "Listening\u{2026}" }
    return Brain.notReadyReason == nil ? "Summarising\u{2026}" : "Conversation"
}

/// "Today · 13 Oct", "Yesterday · 12 Oct", "Saturday · 10 Oct".
func dayHeader(_ d: Date) -> String {
    let cal = Calendar.current
    let name = cal.isDateInToday(d) ? "Today" : cal.isDateInYesterday(d) ? "Yesterday" : d.formatted(.dateTime.weekday(.wide))
    return "\(name) \u{00B7} \(d.formatted(.dateTime.day().month(.abbreviated)))"
}

func dayLabel(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    return d.formatted(.dateTime.weekday(.wide).day().month(.wide))
}

func shareText(_ c: Conversation) -> String {
    var s = (c.title ?? "Conversation") + "\n" + "\(dayLabel(c.start)), \(c.start.formatted(date: .omitted, time: .shortened))\n"
    if let summary = c.summary, !summary.isEmpty { s += "\n" + summary + "\n" }
    return s + "\n" + c.transcript
}
