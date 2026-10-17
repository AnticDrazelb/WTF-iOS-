import Foundation

/// The Action button's answer, kept ready while you talk: worked out again (at most every 45 s)
/// whenever new speech has been transcribed, and its sound made in advance, so a press only has
/// to play it. Pressing never waits on transcription or a slow AI; see [answerNow].
@MainActor
final class Standby {
    static let shared = Standby()

    private var ready: (text: String, covers: Date, byAI: Bool, made: Date)?
    private var working = false
    private var last = Date.distantPast
    private var queued = false
    /// Bumped by forget(): an answer worked out across a delete may be about what was deleted.
    private var generation = 0
    /// When a press last asked for the answer.
    private static let lastAskedKey = "standbyLastAsked"

    /// New speech has been transcribed: work the answer out again, now or in a little while.
    /// Only for someone who's asked in the last week: otherwise it's an AI call and a voice made
    /// every 45 s all day for nothing (a press still works one out).
    func refresh() async {
        let asked = UserDefaults.standard.object(forKey: Self.lastAskedKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(asked) < 7 * 24 * 3600 else { return }
        let wait = 45 - Date().timeIntervalSince(last)
        guard wait <= 0, !working else {
            if !queued {
                queued = true
                Task {
                    try? await Task.sleep(for: .seconds(max(wait, 5)))
                    queued = false
                    await refresh()
                }
            }
            return
        }
        working = true
        last = Date()
        defer { working = false }
        let before = generation
        guard let made = await AppModel.shared.workOutRecap(live: "", ai: 15), before == generation else { return }
        ready = (made.text, made.covers, made.byAI, Date())
        await ReadAloud.shared.prepare(made.text)
    }

    /// Something was deleted: the answer kept ready (and its sound) may be about it.
    func forget() {
        ready = nil
        generation += 1
        ReadAloud.shared.forget()
    }

    /// For a press: the kept answer if nothing's been said since; otherwise one worked out now
    /// with a 3.5 s limit on the AI, then the kept one, then the last words said, word for word.
    func answerNow() async -> String {
        UserDefaults.standard.set(Date(), forKey: Self.lastAskedKey)
        let model = AppModel.shared
        let live = LiveTranscriber.shared.recentText(seconds: 30).trimmingCharacters(in: .whitespacesAndNewlines)
        let latestEnd = await model.pipeline.latestConversation()?.end
        // Older than 10 minutes, its "just" would no longer be true: worked out again.
        if let ready, ready.byAI, live.isEmpty, ready.covers == latestEnd, Date().timeIntervalSince(ready.made) < 600 {
            Log.info("Action button: the answer kept ready was up to date")
            return ready.text
        }
        if let fresh = await model.workOutRecap(live: live, ai: 3.5) {
            if fresh.byAI || ready == nil || !live.isEmpty { return fresh.text }
        }
        if let ready { return ready.text }
        return model.recording ? "I haven't heard anything yet." : "I'm not listening at the moment. Open WTF to turn listening on."
    }
}
