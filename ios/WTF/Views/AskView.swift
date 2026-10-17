import AVFoundation
import SwiftData
import SwiftUI
import UIKit
import WTFCore

struct AskView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @FocusState private var typing: Bool
    @State private var confirmClear = false
    /// At (or near) the latest message: only then does something new scroll the chat down to it.
    @State private var atBottom = true
    /// Questions sent from here: the tap's bump, not every change to the history.
    @State private var sent = 0
    /// The send button's circle grows with the text size, so its arrow always fits inside it.
    @ScaledMetric(relativeTo: .subheadline) private var sendSize: CGFloat = 32
    @Query(AskView.latest) private var latest: [Conversation]

    static var latest: FetchDescriptor<Conversation> {
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.end, order: .reverse)])
        d.fetchLimit = 1
        return d
    }

    /// The latest conversation's trail, while it's fresh (the last three hours).
    private var trail: (id: UUID, threads: [TopicThread])? {
        guard let c = latest.first, !model.hiding.contains(c.persistentModelID), c.end > Date().addingTimeInterval(-3 * 3600) else { return nil }
        let threads = c.threads
        return threads.isEmpty ? nil : (c.id, threads)
    }

    private let suggestions = [
        AppModel.quickQuestion,
        "What was I talking about with those two earlier?",
        "What did I say I'd do today?",
        "Summarise my day so far",
        "What do I need to buy?",
    ]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if model.messages.isEmpty { welcome }
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { i, m in
                            let previous: ChatMessage? = i > 0 ? model.messages[i - 1] : nil
                            let next: ChatMessage? = i + 1 < model.messages.count ? model.messages[i + 1] : nil
                            let fresh = Self.startsAfresh(m, after: previous)
                            let endsRun = next.map { $0.fromUser != m.fromUser || Self.startsAfresh($0, after: m) } ?? true
                            let turned = !fresh && previous?.fromUser != m.fromUser
                            if fresh {
                                Text("\(Text(dayLabel(m.date)).bold()) \(m.date.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, i > 0 ? 18 : 4).padding(.bottom, 6)
                            }
                            Bubble(message: m, tail: endsRun)
                                .padding(.top, turned ? 8 : 0)
                        }
                        // Only under an answer about one conversation: a list answer, a day's recap or
                        // "Turn on Apple Intelligence" has no one conversation to follow up.
                        if let last = model.messages.last, !last.fromUser, !last.isError, model.status == nil,
                           last.date > Date().addingTimeInterval(-1800), Brain.notReadyReason == nil,
                           let about = last.about, about.count == 1 {
                            // Out to the screen edges, so the chips scroll off the side rather than being cut 16 pt in.
                            FollowUps(conversation: about[0]).padding(.horizontal, -16).padding(.top, 6)
                        }
                        if let s = model.streaming, !s.isEmpty {
                            Bubble(message: ChatMessage(fromUser: false, text: s), tail: true).padding(.top, 8)
                        } else if let status = model.status {
                            HStack(spacing: 10) {
                                TypingBubble().accessibilityHidden(true)
                                Text(status).font(.footnote).foregroundStyle(.secondary)
                            }
                            .padding(.top, 8)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .animation(.snappy, value: model.messages)
                }
                .defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: Bool.self) { g in
                    g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 80
                } action: { _, near in
                    atBottom = near
                }
                // Only for something new, and only if you were at the latest or just asked: deleting
                // an old message, or reading back while an answer comes in, leaves you where you are.
                .onChange(of: model.messages) { old, new in
                    guard new.count > old.count, let last = new.last else { return }
                    if atBottom || last.fromUser { withAnimation { proxy.scrollTo("bottom") } }
                    // VoiceOver doesn't read a new bubble by itself, so the end of "Thinking…" would pass silently.
                    // Only a new last one: a button's question and answer go in above one still being answered.
                    if !last.fromUser, last.id != old.last?.id, UIAccessibility.isVoiceOverRunning {
                        UIAccessibility.post(notification: .announcement, argument: last.text)
                    }
                }
                .onChange(of: (model.streaming?.count ?? 0) / 60) { if atBottom { proxy.scrollTo("bottom") } }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            // Above the chat, not in it: it opens at the latest message, so the first item is out of sight.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if let problem = model.problem {
                        problemBanner(problem)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let trail {
                        ThreadTrail(threads: trail.threads) { model.askAbout($0, in: trail.id) }
                            // Kept modest at the largest text sizes, so the chat has the room.
                            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                            .background(.bar)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            .animation(.snappy, value: trail?.threads.count)
            .animation(.snappy, value: model.problem)
            .navigationTitle("Ask")
            // Inline, as a chat opens at its latest message: a large title would sit as an empty band.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ListeningButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Clear Ask History\u{2026}", systemImage: "trash", role: .destructive) { confirmClear = true }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .disabled(model.messages.isEmpty || model.status != nil)
                }
            }
            .confirmationDialog("Clear Ask\u{2019}s history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { model.clearAsk() }
            } message: {
                Text("Every question and answer in Ask goes. Your conversations stay. This can\u{2019}t be undone.")
            }
        }
    }

    /// Why listening stopped, and a tap to put it right.
    @ViewBuilder
    private func problemBanner(_ problem: String) -> some View {
        let settings = Self.needsSettings(problem)
        // Nothing to tap when the store couldn't open, as listening again saves nothing, or while
        // it's still listening (free space running out): starting again would only hide the note.
        // Paused is the exception: a tap tries to get the microphone back.
        if problem == AppModel.storeLostNote || (model.recording && !model.paused && !settings) {
            problemLabel(problem)
        } else {
            // Starting again can't help when it's a setting that's stopping it.
            Button {
                if settings, let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                } else {
                    model.setListening(true)
                }
            } label: {
                problemLabel(problem)
            }
            .buttonStyle(.plain)
            .accessibilityHint(settings ? "Opens Settings" : "Starts listening again")
        }
    }

    private func problemLabel(_ problem: String) -> some View {
        Label(problem, systemImage: "exclamationmark.triangle.fill")
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.footnote).foregroundStyle(.secondary)
            // Pinned above the chat, so kept short at the largest text sizes; VoiceOver reads it all.
            .lineLimit(4)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityLabel(problem)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.bar)
            .contentShape(Rectangle())
    }

    /// Microphone access or Live Activities turned off: only Settings can put it right.
    static func needsSettings(_ problem: String) -> Bool {
        AVAudioApplication.shared.recordPermission == .denied
            || (problem.contains("Live Activities") && !ListeningActivity.allowed)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Lost the thread?").font(.title2.bold())
                Text("Ask about anything you've said or heard while WTF was listening.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(suggestions, id: \.self) { q in
                    Button { model.ask(q) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles").foregroundStyle(.secondary)
                            Text(q).foregroundStyle(.primary).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 14).padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    if q != suggestions.last { Divider().padding(.leading, 48) }
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 18))
            .disabled(model.status != nil)
        }
        .padding(.top, 16)
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if typing && input.isEmpty && !model.messages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { q in
                            Button(q) {
                                typing = false
                                model.ask(q)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(.primary)
                    .disabled(model.status != nil)
                    .padding(.horizontal, 16)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            field
        }
        .animation(.snappy, value: typing && input.isEmpty)
    }

    private var canSend: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.status == nil }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Ask about anything you heard", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .focused($typing)
                .padding(.leading, 16).padding(.vertical, 12)
                .onChange(of: typing) { if typing { Brain.prewarm() } }
                .onSubmit(send)
            // While an answer's being worked out it's Stop, so a long one needn't be waited out.
            let asking = model.status != nil
            Button {
                if asking { model.stopAsking() } else { send() }
            } label: {
                Image(systemName: asking ? "stop.fill" : "arrow.up")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: sendSize, height: sendSize)
                    .background(Circle().fill(canSend || asking ? Color.primary : Color.secondary.opacity(0.35)))
                    // At least 44 pt to tap, the circle drawn as before.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!canSend && !asking)
            .accessibilityLabel(asking ? "Stop" : "Ask")
            .sensoryFeedback(.impact(weight: .light), trigger: sent)
        }
        .glassEffect(in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 14)
    }

    /// A new day, or an hour since the last message: shown with its day and time, like Messages.
    static func startsAfresh(_ m: ChatMessage, after previous: ChatMessage?) -> Bool {
        guard let previous else { return true }
        return !Calendar.current.isDate(m.date, inSameDayAs: previous.date) || m.date.timeIntervalSince(previous.date) > 3600
    }

    private func send() {
        // Return while an answer's being written: the question stays in the box, not lost.
        guard canSend else { return }
        let q = input
        input = ""
        sent += 1
        model.ask(q)
    }
}

/// An iMessage bubble: blue on the right for you, grey on the left for WTF.
struct Bubble: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let tail: Bool

    var body: some View {
        HStack {
            if message.fromUser { Spacer(minLength: 60) }
            Text(message.text)
                .accessibilityLabel(message.fromUser ? "You: \(message.text)" : "WTF: \(message.text)")
                .padding(.horizontal, 14).padding(.vertical, 9)
                .foregroundStyle(message.fromUser ? Color(.systemBackground) : (message.isError ? Color.secondary : Color.primary))
                .background(
                    message.fromUser ? AnyShapeStyle(Color(.label)) : AnyShapeStyle(Color(.systemGray5)),
                    in: BubbleShape(fromUser: message.fromUser, tail: tail)
                )
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                    if message.fromUser {
                        if !FollowUps.oneOff(message.text) {
                            Button("Ask Again", systemImage: "arrow.clockwise") {
                                model.ask(message.text, focus: message.focus ?? FollowUps.focus(of: message))
                            }
                            .disabled(model.status != nil)
                        }
                    } else {
                        ShareLink(item: message.text) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { model.deleteMessage(message.id) }
                        .disabled(model.status != nil)
                }
                .textSelection(.enabled)
            if !message.fromUser { Spacer(minLength: 60) }
        }
    }
}

/// A rounded bubble, with the little curled tail on the last bubble of a run.
struct BubbleShape: Shape {
    let fromUser: Bool
    let tail: Bool

    func path(in r: CGRect) -> Path {
        let p = Path(roundedRect: r, cornerRadius: 18, style: .continuous)
        guard tail else { return p }
        let x = fromUser ? r.maxX : r.minX
        let dir: CGFloat = fromUser ? 1 : -1
        var t = Path()
        t.move(to: CGPoint(x: x - dir * 14, y: r.maxY))
        t.addQuadCurve(to: CGPoint(x: x + dir * 5, y: r.maxY), control: CGPoint(x: x - dir * 2, y: r.maxY))
        t.addQuadCurve(to: CGPoint(x: x - dir * 2, y: r.maxY - 16), control: CGPoint(x: x - dir * 2, y: r.maxY - 4))
        t.closeSubpath()
        // Joined, not just added: drawn the other way round (your side), an added tail punches a hole.
        return p.union(t)
    }
}

/// The grey "…" bubble while WTF is thinking.
struct TypingBubble: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.title3.bold())
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Color(.systemGray5), in: BubbleShape(fromUser: false, tail: true))
    }
}

/// After an answer, the obvious next steps, one tap each.
struct FollowUps: View {
    @Environment(AppModel.self) private var model
    let conversation: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button("Summarise this", systemImage: "text.alignleft") {
                    model.ask(Self.summarise, focus: conversation)
                }
                Button("What did I say I\u{2019}d do?", systemImage: "checklist") {
                    model.ask(Self.promised, focus: conversation)
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(.primary)
            .font(.subheadline)
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
    }

    static let summarise = "Summarise this conversation"
    static let promised = "What did I say I'd do?"

    /// Asked again, these mean the one conversation they were asked about, not the latest.
    static func focus(of question: ChatMessage) -> UUID? {
        guard question.text == summarise || question.text == promised, let about = question.about, about.count == 1 else { return nil }
        return about[0]
    }

    /// A topic tapped on the trail, or the Action button's "What came before that?": the words
    /// alone don't say what they were about, so they aren't asked again.
    static func oneOff(_ question: String) -> Bool {
        question.hasPrefix("Where was I with \u{201C}") || question == "What came before that?"
    }
}

extension AppModel {
    /// A question goes with the answers that followed it; an answer goes on its own.
    func deleteMessage(_ id: UUID) {
        guard status == nil, let i = messages.firstIndex(where: { $0.id == id }) else { return }
        var end = i + 1
        if messages[i].fromUser {
            while end < messages.count, !messages[end].fromUser { end += 1 }
        }
        messages.removeSubrange(i..<end)
        ChatLog.save(messages)
    }

    /// Ask's history, all of it; the conversations themselves stay.
    func clearAsk() {
        guard status == nil else { return }
        messages = []
        ChatLog.save(messages)
    }
}
