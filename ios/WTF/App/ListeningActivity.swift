import ActivityKit
import Foundation
import UIKit
import UserNotifications
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

    private init() {
        // Swiped away in the app switcher: the card goes too, rather than saying "Listening" for a
        // quarter of an hour over nothing. Waited for (briefly), as WTF's about to be gone; not
        // through stop(), whose tasks need the main thread, which is the one waiting here.
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            // Its end isn't iOS taking the card away, so no notice says WTF's still listening; and
            // one already given would say so after WTF's gone.
            MainActor.assumeIsolated {
                ListeningActivity.shared.stateWatch?.cancel()
                ListeningActivity.withdrawGoneNotice()
            }
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                for card in Activity<ListeningAttributes>.activities { await card.end(nil, dismissalPolicy: .immediate) }
                done.signal()
            }
            _ = done.wait(timeout: .now() + 1)
        }
    }

    private var activity: Activity<ListeningAttributes>?
    private var state = ListeningAttributes.ContentState(topic: nil, trail: [], since: Date(), hanging: 0)

    /// Whether the card and the pill are up (they're where a press of their buttons is answered).
    /// iOS ends them after about 8 hours, and they can be swiped away: then there's a stale handle
    /// to one that's gone.
    var showing: Bool {
        guard let activity else { return false }
        return activity.activityState == .active || activity.activityState == .stale
    }

    /// A new card for a new listening session: no topics yet. Whether it's up: iOS can say no.
    @discardableResult
    func start() -> Bool {
        guard !showing else { return true }
        guard Self.allowed else { return false }
        state = ListeningAttributes.ContentState(topic: nil, trail: [], since: Date(), hanging: 0, heard: AppModel.shared.hasHeard)
        state.paused = AppModel.shared.paused
        return request()
    }

    /// While listening, the card back if iOS ended it or it was swiped away: with the topics it
    /// had and the time listening started, so its timer carries on rather than starting again.
    /// From the app coming forward, and from the card's and the controls' buttons before answering.
    /// [often]: from new topics, which come all the time, so a try at most once a minute.
    func restoreIfNeeded(often: Bool = false) {
        // Live Activities turned off for WTF: no card's coming back, so no notice says it will.
        if !Self.allowed { Self.withdrawGoneNotice() }
        guard AppModel.shared.recording, !showing, Self.allowed else { return }
        // iOS only lets a card start from the app in front (or a button's intent): from the
        // background it says no, so not every new topic tries again.
        if often {
            // Not at all from the background: iOS says no (see watch). The next time WTF comes
            // forward does it.
            guard UIApplication.shared.applicationState != .background,
                  Date().timeIntervalSince(lastRestore) > 60 else { return }
            lastRestore = Date()
        }
        state.since = AppModel.shared.listeningSince ?? state.since
        state.answer = nil
        state.heard = AppModel.shared.hasHeard
        state.paused = AppModel.shared.paused
        Log.info("Lock Screen card had ended while listening; starting it again")
        request()
    }

    private var lastRestore = Date.distantPast

    @discardableResult
    private func request() -> Bool {
        activity = nil
        // Any left from before (WTF closed while it was listening, or one iOS ended) would show
        // as a second pill. Ended only once there's a new one: if iOS says no, they stay.
        let olds = Activity<ListeningAttributes>.activities
        do {
            let card = try Activity.request(attributes: ListeningAttributes(), content: ActivityContent(state: state, staleDate: Self.fresh))
            activity = card
            watch(card)
            Self.withdrawGoneNotice()
            for old in olds {
                Task { await old.end(nil, dismissalPolicy: .immediate) }
            }
            heartbeat?.cancel()
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    guard let self, let current = self.activity else { return }
                    await current.update(ActivityContent(state: self.state, staleDate: Self.fresh))
                }
            }
            return true
        } catch {
            Log.error("Lock Screen card didn't start", error)
            return false
        }
    }

    /// How long the card counts as up to date: if WTF stops updating it (closed, or crashed), it
    /// stops saying "Recording" after this.
    private static var fresh: Date { Date().addingTimeInterval(15 * 60) }
    private var heartbeat: Task<Void, Never>?
    private var stateWatch: Task<Void, Never>?

    /// iOS ends the card after about 8 hours (or it's swiped away) while WTF carries on listening
    /// in the background, where it can't start another. Left up, the ended card freezes and soon
    /// says "Not listening" with the microphone still on: so it goes at once, and from the
    /// background a quiet notice says WTF is still listening. The next time WTF comes forward,
    /// restoreIfNeeded brings the card back.
    private func watch(_ card: Activity<ListeningAttributes>) {
        stateWatch?.cancel()
        stateWatch = Task { [weak self] in
            for await phase in card.activityStateUpdates {
                guard phase == .ended || phase == .dismissed else { continue }
                guard let self, self.activity?.id == card.id, AppModel.shared.recording else { return }
                await card.end(nil, dismissalPolicy: .immediate)
                guard !Task.isCancelled else { return }
                // In front (iOS's 8 hours were up while WTF was open), another can start now: else
                // there'd be none, and no notice, once the iPhone's locked.
                if UIApplication.shared.applicationState == .active {
                    self.restoreIfNeeded()
                    return
                }
                // Not when Live Activities were turned off for WTF: opening it won't bring the card back.
                if Self.allowed, UIApplication.shared.applicationState == .background {
                    let content = UNMutableNotificationContent()
                    content.title = "WTF is still listening"
                    content.body = "The Lock Screen card has gone. Open WTF to bring it back."
                    content.interruptionLevel = .passive
                    try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.goneNotice, content: content, trigger: nil))
                }
                return
            }
        }
    }

    private static let goneNotice = "wtf.card.gone"

    /// The notice that the card's gone: wrong once it's back, or listening's stopped.
    private static func withdrawGoneNotice() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [goneNotice])
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        stateWatch?.cancel()
        stateWatch = nil
        Self.withdrawGoneNotice()
        activity = nil
        for ending in Activity<ListeningAttributes>.activities {
            Task { await ending.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// The latest conversation's topics.
    func show(_ threads: [TopicThread]) {
        guard AppModel.shared.recording else { return }
        // iOS ends a Live Activity after some hours; start another if so.
        restoreIfNeeded(often: true)
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

    /// Listening's on but the microphone isn't running (a call or Siri has it): the card and
    /// the pill say Paused, with no timer, rather than Listening.
    func paused(_ paused: Bool) {
        guard state.paused != paused else { return }
        state.paused = paused
        let content = ActivityContent(state: state, staleDate: Self.fresh)
        let current = activity
        Task { await current?.update(content) }
    }

    /// Short enough for the card's three lines, cut at a word with an ellipsis. The whole answer
    /// is still in Ask and in the notification.
    private static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit - 1)
        var words = cut.lastIndex(where: { $0.isWhitespace }).map { cut[..<$0] } ?? cut
        // Only the end is tidied: an opening quote or bracket stays.
        while let last = words.last, last.isWhitespace || last.isPunctuation { words = words.dropLast() }
        return (words.isEmpty ? String(cut) : String(words)) + "…"
    }

    /// The answer to a press of the card's or the pill's buttons, shown on them for a minute and
    /// a half: iOS gives those buttons nowhere else to show it. The pill opens out to show it,
    /// and the Lock Screen lights up.
    func showAnswer(_ text: String) {
        guard showing, let current = activity else { return }
        answers += 1
        let mine = answers
        state.answer = Self.clipped(text, to: 180)
        let content = ActivityContent(state: state, staleDate: Self.fresh)
        // With headphones in it's being read aloud already: no alert sound over the voice.
        let alert = ReadAloud.headphonesOn ? nil : AlertConfiguration(title: "WTF", body: "\(text)", sound: .default)
        Task {
            await current.update(content, alertConfiguration: alert)
            try? await Task.sleep(for: .seconds(90))
            guard mine == answers, let now = activity else { return }
            state.answer = nil
            await now.update(ActivityContent(state: state, staleDate: Self.fresh))
        }
    }

    /// Each answer shown has a number, so a newer one isn't cleared by an older one's timer.
    private var answers = 0
}
