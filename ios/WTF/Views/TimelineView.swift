import SwiftData
import SwiftUI
import UIKit
import WTFCore

struct TimelineView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Conversation.start, order: .reverse) private var conversations: [Conversation]
    @Query(filter: #Predicate<Chunk> { $0.status == "pending" }) private var pending: [Chunk]
    @State private var query = ""
    /// Which conversation the alerts are about, by id: one deleted while they're up (expiry) is
    /// then simply not found, rather than a deleted model being written to.
    @State private var deleting: UUID?
    @State private var renaming: UUID?
    @State private var newTitle = ""
    /// What the search found, worked out once typing pauses: not on every keystroke, as a week
    /// of transcripts runs to megabytes. Nil until the first search has finished.
    @State private var matches: Set<PersistentIdentifier>?

    private var shown: [Conversation] {
        // Not ones being deleted: a row left showing one as it goes would crash the app.
        let visible = conversations.filter { !model.hiding.contains($0.persistentModelID) }
        guard searching, let matches else { return visible }
        return visible.filter { matches.contains($0.persistentModelID) }
    }

    /// Off the main thread, so a week of transcripts doesn't hold up scrolling.
    nonisolated private static func search(_ q: String, in docs: [(key: PersistentIdentifier, text: [String?])]) -> Set<PersistentIdentifier> {
        Set(docs.filter { doc in doc.text.contains { $0?.localizedStandardContains(q) == true } }.map { $0.key })
    }

    /// A conversation still showing (not one being deleted), by id.
    private func find(_ id: UUID?) -> Conversation? {
        conversations.first { $0.id == id && !model.hiding.contains($0.persistentModelID) }
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

    /// While listening, each pause leaves one recording to transcribe for a few seconds: only
    /// shown once there's a queue, so the list doesn't jump after every sentence.
    private var showsTranscribing: Bool {
        (!model.recording && (!pending.isEmpty || model.transcribing != nil))
            || pending.count > 1 || (model.transcribing?.total ?? 0) > 1
    }

    private var searching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.timelinePath) {
            List {
                if showsTranscribing {
                    Section { TranscribingRow(pending: pending.count) }
                }
                ForEach(byDay, id: \.day) { day, header, list in
                    Section {
                        // The whole day at a glance, then each conversation. (Not while searching.)
                        if !searching {
                            YourDayRow(day: day, conversations: list)
                                .background { NavigationLink(value: DayRef(day: day)) { EmptyView() }.opacity(0) }
                                // One stop for VoiceOver, as the hidden link above isn't read.
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityHint("Opens your day")
                                .accessibilityAction { model.timelinePath.append(DayRef(day: day)) }
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                        }
                        ForEach(list) { c in
                            TimelineEntry(conversation: c)
                                .background { NavigationLink(value: c) { EmptyView() }.opacity(0) }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityHint("Opens the conversation")
                                .accessibilityAction { model.timelinePath.append(c) }
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                                .contextMenu {
                                    Button("Ask About This", systemImage: "questionmark.bubble") {
                                        model.tab = 0
                                        model.ask(c.title.map { "What happened in \u{201C}\($0)\u{201D}?" } ?? "What was said then?", focus: c.id)
                                    }
                                    // Not while another answer's being written: the question would be lost.
                                    .disabled(model.status != nil)
                                    if let summary = c.summary {
                                        Button("Copy Summary", systemImage: "doc.on.doc") {
                                            UIPasteboard.general.string = [c.title, summary].compactMap { $0 }.joined(separator: "\n")
                                        }
                                    }
                                    ShareLink(item: shareText(c)) { Label("Share", systemImage: "square.and.arrow.up") }
                                    Button("Rename\u{2026}", systemImage: "pencil") { newTitle = c.title ?? ""; renaming = c.id }
                                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = c.id }
                                }
                                // As in Lists: swipe to delete. Not a destructive role or a full swipe: those
                                // slide the row away before it's confirmed, and back again on Cancel.
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button("Delete", systemImage: "trash") { deleting = c.id }
                                        .tint(.red)
                                }
                        }
                    } header: {
                        Text(header).font(.subheadline).foregroundStyle(.secondary).textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if conversations.isEmpty && !showsTranscribing {
                    ContentUnavailableView("No Conversations", systemImage: "waveform",
                                           description: Text(model.recording ? "Your conversations will appear here once WTF has heard some talking." : "Turn on listening and your conversations will appear here."))
                } else if !query.isEmpty && shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Search everything you've heard")
            // Again as the live conversation grows (the newest), so words just said are found.
            .task(id: "\(query)|\(conversations.count)|\(conversations.first?.transcript.utf8.count ?? 0)") {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { matches = nil; return }
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                let docs = conversations.map { (key: $0.persistentModelID, text: [$0.title, $0.summary, $0.transcript]) }
                let found = await Task.detached(priority: .userInitiated) { Self.search(q, in: docs) }.value
                guard !Task.isCancelled else { return }
                matches = found
            }
            // The latest words, not the summaries and second hearing queued behind them: those
            // carry on afterwards, so the spinner doesn't wait a minute for them.
            .refreshable {
                Recorder.shared.flush()
                await model.pipeline.catchUp(force: true)
                model.processNow()
            }
            .navigationTitle("Timeline")
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Cancel", role: .cancel) {}
                Button("Save") { if let c = find(renaming) { renameConversation(c, to: newTitle) } }
                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog("Delete this conversation?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let id = deleting { Task { await model.deleteConversation(id) } }
                    deleting = nil
                }
            } message: {
                Text("Its transcript, recording and suggestions go too. This can\u{2019}t be undone.")
            }
            // A tap on the listening pill: the stop sheet can't show over these, so they go.
            .onChange(of: model.stopSheet) { _, on in if on { renaming = nil; deleting = nil } }
            .navigationDestination(for: Conversation.self) { ConversationView(conversation: $0) }
            .navigationDestination(for: DayRef.self) { DayView(day: $0.day) }
            .toolbar { ToolbarItem(placement: .topBarLeading) { ListeningButton() } }
        }
    }
}

struct TranscribingRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let pending: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hourglass").foregroundStyle(.secondary)
                .frame(width: 29, height: 29)
                .accessibilityHidden(true)
            if let p = model.transcribing {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.total > 1 ? "Transcribing \(p.done + 1) of \(p.total)\u{2026}" : "Transcribing\u{2026}")
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                }
            } else if typeSize.isAccessibilitySize {
                // The button under the words at large text sizes, so neither is squeezed.
                VStack(alignment: .leading, spacing: 8) {
                    waiting
                    transcribeNow
                }
            } else {
                waiting
                Spacer()
                transcribeNow
            }
        }
    }

    private var waiting: some View {
        Text("\(pending) recording\(pending == 1 ? "" : "s") still to transcribe")
    }

    // A capsule, so it doesn't read as part of the sentence beside it.
    private var transcribeNow: some View {
        Button("Transcribe Now") { model.processNow(force: true) }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
            .sensoryFeedback(.selection, trigger: model.transcribing != nil)
    }
}

/// The day as a timeline: a line down the side, each conversation pinned to it at its time,
/// and under it the topics it wandered through; a tangent (after one was left hanging) steps in.
struct TimelineEntry: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let conversation: Conversation

    /// Only while it's actually being heard: not while a call has the microphone, or once
    /// listening's stopped and the conversation's waiting to be closed.
    private var live: Bool { !conversation.closed && conversation.summary == nil && model.recording && !model.paused }

    var body: some View {
        let topics = Threads.layout(conversation.threads)
        // At large text sizes the time goes in the card, not a column beside it, so the card
        // has the width and the title isn't cut to a word.
        let large = typeSize.isAccessibilitySize
        HStack(alignment: .top, spacing: 0) {
            if !large {
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
            }
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    if large {
                        HStack(alignment: .firstTextBaseline) {
                            Text(conversation.start, format: .dateTime.hour().minute())
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            if live { Text("Live").font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                        }
                        Text(displayTitle(conversation)).font(.headline)
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            Text(displayTitle(conversation)).font(.headline).lineLimit(2)
                            Spacer(minLength: 4)
                            if live { Text("Live").font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                        }
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
            .padding(.leading, large ? 0 : 10).padding(.vertical, 8)
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
    /// Why naming a voice or fixing words didn't work: an alert, as the footer's below the
    /// whole transcript and out of sight.
    @State private var failure: String?
    @State private var saved = 0
    @State private var renaming = false
    @State private var newTitle = ""
    /// The line being fixed, and its words as they're being edited.
    @State private var fixing: String?
    @State private var fixedText = ""
    /// "Is Speaker 2 Sarah?" suggestions turned down, and the ones worked out (off the main path).
    @State private var declined = DeclinedNames.all
    @State private var hints: [NameHints.Hint] = []

    var body: some View {
        List {
            Section {
                // The title in full: the bar's is cut short between its buttons.
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle(conversation)).font(.title2.bold())
                    Text("\(dayLabel(conversation.start)), \(conversation.start.formatted(date: .omitted, time: .shortened))\u{2013}\(conversation.end.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                // The page's only title (the bar's is blank), so VoiceOver can find it as one.
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .listRowBackground(Color.clear)
            }
            if let summary = conversation.summary, !summary.isEmpty {
                Section("Summary") { Text(summary) }
            }
            if !conversation.threads.isEmpty {
                Section {
                    ThreadList(threads: conversation.threads) { model.askAbout($0, in: conversation.id) }
                } header: {
                    Text("Topics")
                } footer: {
                    Text("Tap a topic to ask where you were with it.")
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
                            Button("No") { declined.insert(key(hint)); DeclinedNames.all = declined }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                        .buttonBorderShape(.capsule)
                    }
                    .padding(.vertical, 4)
                }
            }
            Section {
                // Each line's time in the phone's own format, as everywhere else ("2:03 PM", not "14:03").
                let lines = conversation.transcript.split(separator: "\n")
                let times = TranscriptFormat.times(of: lines, from: conversation.start)
                ForEach(lines.indices, id: \.self) { i in
                    let line = lines[i]
                    let parts = parse(String(line))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if let who = parts.speaker {
                                Menu { voiceMenu(who) } label: {
                                    Text(who).font(.subheadline.weight(.semibold)).foregroundStyle(VoiceColor.of(who))
                                }
                            }
                            if let at = times[i] {
                                Text(at.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
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
        // Kept for the back button's history, but not shown: the heading above has it in full.
        .navigationTitle(displayTitle(conversation))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) } }
        // So a conversation going past keeping closes this page only if it's this one.
        .onAppear { model.onScreen.insert(conversation.id) }
        .onDisappear { model.onScreen.remove(conversation.id) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: shareText(conversation))
                Menu {
                    Button("Ask About This", systemImage: "questionmark.bubble") {
                        model.tab = 0
                        model.ask(conversation.title.map { "What happened in \u{201C}\($0)\u{201D}?" } ?? "What was said then?", focus: conversation.id)
                    }
                    .disabled(model.status != nil)
                    Button("Rename\u{2026}", systemImage: "pencil") { newTitle = conversation.title ?? ""; renaming = true }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .sensoryFeedback(.success, trigger: saved)
        .sensoryFeedback(.error, trigger: failure) { _, now in now != nil }
        .alert("Couldn\u{2019}t Save", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") { renameConversation(conversation, to: newTitle) }
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(naming.map { Labels.number($0) != nil ? "Who\u{2019}s \($0)?" : "Rename \($0)" } ?? "",
               isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $typed).textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let label = naming { name(label, as: typed) } }
                .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                            failure = "That line changed while you were fixing it, so nothing was changed. Try again."
                        }
                    }
                }
                fixing = nil
            }
        }
        // A tap on the listening pill: the stop sheet can't show over these, so they go.
        .onChange(of: model.stopSheet) { _, on in
            if on { fixing = nil; renaming = false; naming = nil; confirmDelete = false }
        }
        .confirmationDialog("Delete this conversation?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let id = conversation.id
                // Its page closes itself: the day it came from stays open behind it, unless this
                // was all of that day, when the Timeline goes back to the top.
                let day = Calendar.current.startOfDay(for: conversation.start)
                let next = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
                // Not counting any already on their way out, as the Timeline doesn't show them.
                let sameDay = ((try? model.container.mainContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { $0.start >= day && $0.start < next }))) ?? [])
                    .filter { !model.hiding.contains($0.persistentModelID) }.count
                dismiss()
                Task { await model.deleteConversation(id, fromItsPage: sameDay > 1) }
            }
        } message: {
            Text("Its transcript, recording and suggestions go too. This can\u{2019}t be undone.")
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
        return hints.filter { !declined.contains(key($0)) && Labels.speakers(in: conversation.transcript).contains($0.label) }
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
                failure = "That name can\u{2019}t be used: try a shorter one, without numbers."
                return
            }
            saved += 1
            let who = done.name == Labels.me ? "you" : done.name
            note = done.elsewhere > 0
                ? "Also found \(who) in \(done.elsewhere) other conversation\(done.elsewhere == 1 ? "" : "s")."
                : "WTF will recognise \(who) from now on."
        }
    }

    private func parse(_ line: String) -> (speaker: String?, text: String) {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return (nil, line) }
        let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard let colon = rest.range(of: ": ") else { return (nil, rest) }
        let who = String(rest[..<colon.lowerBound])
        let text = String(rest[colon.upperBound...])
        return (who == Labels.anonymous ? nil : who, text)
    }
}

/// Correcting what was misheard in a line: the words, editable.
struct FixWordsSheet: View {
    @Binding var text: String
    let done: (Bool) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What was said", text: $text, axis: .vertical)
                        .lineLimit(3...12)
                        .focused($focused)
                } footer: {
                    Text("Change only what was misheard. WTF learns the correction, so the same mistake is caught next time.")
                }
            }
            .navigationTitle("Fix Words")
            .navigationBarTitleDisplayMode(.inline)
            // Straight to typing, as it's what the sheet is for.
            .onAppear { focused = true }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(false) } }
                ToolbarItem(placement: .topBarTrailing) { Button("Save") { done(true) }.fontWeight(.semibold).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
        // Taller on a drag, for a long line with the keyboard up.
        .presentationDetents([.medium, .large])
    }
}

/// Speakers in quiet type: you in full black (or white), everyone else in grey.
enum VoiceColor {
    static func of(_ label: String) -> Color { label == Labels.me ? .primary : .secondary }
}

/// "Is Speaker 2 Sarah?" suggestions turned down. Kept with WTF's other data (not in the
/// settings, which go in backups).
enum DeclinedNames {
    /// Where earlier versions kept them, one to a line.
    private static let key = "declinedNames"

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("declined.json")
    }

    static var all: Set<String> {
        get {
            if let data = try? Data(contentsOf: file) { return Set((try? JSONDecoder().decode([String].self, from: data)) ?? []) }
            // Moved out of the settings once.
            guard let old = UserDefaults.standard.string(forKey: key) else { return [] }
            let names = Set(old.split(separator: "\n").map(String.init))
            save(names)
            UserDefaults.standard.removeObject(forKey: key)
            return names
        }
        set { save(newValue) }
    }

    static func forget() {
        try? FileManager.default.removeItem(at: file)
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(_ names: Set<String>) {
        guard let data = try? JSONEncoder().encode(names.sorted()) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// Its title, or what's happening until it has one.
func displayTitle(_ c: Conversation) -> String {
    if let title = c.title { return title }
    // Not "Listening": that's the listening control's word, and it may be paused or stopped.
    if !c.closed { return "In Progress" }
    return Brain.notReadyReason == nil ? "Summarising\u{2026}" : "Conversation"
}

/// Your own title for it. Its summary is left alone: one set here would mean it's never
/// summarised, heard again or looked through for list items and facts.
@MainActor func renameConversation(_ c: Conversation, to title: String) {
    let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return }
    // Shown at once here; and saved by the pipeline too, where summaries are written, so one
    // finishing now can't put its own title back over yours.
    c.title = t
    try? c.modelContext?.save()
    let id = c.id
    Task { await AppModel.shared.pipeline.rename(id, to: t) }
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
