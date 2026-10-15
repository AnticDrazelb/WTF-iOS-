import ActivityKit
import Foundation
import WTFCore

/// Keeps the Live Activity in step with listening and the thread map.
@MainActor
final class ListeningActivity {
    static let shared = ListeningActivity()

    /// Whether the part of WTF that draws the card, the pill and the controls (its widget
    /// extension) is installed: sideloading can leave it out, and then the pill's an empty black bar.
    static var drawable: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let found = try? FileManager.default.contentsOfDirectory(atPath: plugins.path) else { return false }
        return found.contains { $0.hasSuffix(".appex") }
    }

    /// Whether Live Activities are allowed for WTF (Settings › Apps › WTF › Live Activities).
    static var allowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// For Diagnostics: the cards iOS has for WTF right now, and how they stand.
    static var states: String {
        let all = Activity<ListeningAttributes>.activities
        return all.isEmpty ? "none" : all.map { String(describing: $0.activityState) }.joined(separator: ", ")
    }

    private var activity: Activity<ListeningAttributes>?
    private var state = ListeningAttributes.ContentState(topic: nil, trail: [], since: Date(), hanging: 0)

    /// Whether the card and the pill are up (they're where a press of their buttons is answered).
    var showing: Bool { activity?.activityState == .active }

    func start() {
        guard activity == nil, Self.allowed else { return }
        // Any left from before (WTF closed while it was listening) would show as a second pill.
        for old in Activity<ListeningAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        state = ListeningAttributes.ContentState(topic: nil, trail: [], since: Date(), hanging: 0, heard: AppModel.shared.hasHeard)
        do {
            activity = try Activity.request(attributes: ListeningAttributes(), content: ActivityContent(state: state, staleDate: Self.fresh))
            heartbeat?.cancel()
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    guard let self, let current = self.activity else { return }
                    await current.update(ActivityContent(state: self.state, staleDate: Self.fresh))
                }
            }
        } catch {
            Log.error("Lock Screen card didn't start", error)
        }
    }

    /// How long the card counts as up to date: if WTF stops updating it (closed, or crashed), it
    /// stops saying "Recording" after this.
    private static var fresh: Date { Date().addingTimeInterval(15 * 60) }
    private var heartbeat: Task<Void, Never>?

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        activity = nil
        for ending in Activity<ListeningAttributes>.activities {
            Task { await ending.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// The latest conversation's topics.
    func show(_ threads: [TopicThread]) {
        guard AppModel.shared.recording else { return }
        // iOS ends a Live Activity after some hours; start another if so (before the topics go
        // in: starting one starts it empty).
        if let a = activity, a.activityState == .ended || a.activityState == .dismissed { activity = nil }
        if activity == nil { start() }
        state.trail = threads.suffix(4).map {
            ListeningAttributes.Step(title: $0.title, hanging: $0.status == .hanging, current: $0.status == .current)
        }
        state.topic = threads.last(where: { $0.status == .current })?.title
        state.hanging = Threads.hanging(threads).count
        state.earlier = !Threads.backstory(threads).isEmpty
        if !threads.isEmpty { state.heard = true }
        let content = ActivityContent(state: state, staleDate: Self.fresh)
        let current = activity
        Task { await current?.update(content) }
    }

    /// Whether there's anything to answer "what was I saying?" from: until there is, the card
    /// and the pill don't offer it.
    func heard(_ heard: Bool) {
        guard state.heard != heard else { return }
        state.heard = heard
        let content = ActivityContent(state: state, staleDate: Self.fresh)
        let current = activity
        Task { await current?.update(content) }
    }

    /// The answer to a press of the card's or the pill's buttons, shown on them for a minute and
    /// a half: iOS gives those buttons nowhere else to show it. The pill opens out to show it,
    /// and the Lock Screen lights up.
    func showAnswer(_ text: String) {
        guard let current = activity else { return }
        answers += 1
        let mine = answers
        state.answer = String(text.prefix(280))
        let content = ActivityContent(state: state, staleDate: Self.fresh)
        Task {
            await current.update(content, alertConfiguration: AlertConfiguration(title: "WTF", body: "\(text)", sound: .default))
            try? await Task.sleep(for: .seconds(90))
            guard mine == answers, let now = activity else { return }
            state.answer = nil
            await now.update(ActivityContent(state: state, staleDate: Self.fresh))
        }
    }

    /// Each answer shown has a number, so a newer one isn't cleared by an older one's timer.
    private var answers = 0
}
