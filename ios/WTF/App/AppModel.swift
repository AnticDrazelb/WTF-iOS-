import AVFoundation
import Foundation
import Observation
import SwiftData
import SwiftUI
import UIKit
import UserNotifications
import WTFCore

/// The app's shared state: listening, the chat, and the pipeline.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let container: ModelContainer
    let pipeline: Pipeline

    var recording = false
    /// Ask's questions and answers, kept from one day to the next (see ChatLog).
    var messages: [ChatMessage] = ChatLog.load()
    /// What's happening while you wait ("Catching up…"), or nil.
    var status: String?
    /// The answer being written, word by word.
    var streaming: String?
    var tab = 0
    /// What's open on top of the Timeline and Settings tabs (for swiping between tabs).
    var timelinePath = NavigationPath()
    var settingsPath = NavigationPath()

    func pathIsEmpty(for tab: Int) -> Bool {
        switch tab {
        case 1: return timelinePath.isEmpty
        case 3: return settingsPath.isEmpty
        default: return true
        }
    }
    var problem: String?
    /// Tapping the listening pill in the Dynamic Island: the sheet to stop listening.
    var stopSheet = false
    /// When listening last started, for that sheet.
    var listeningSince: Date?
    /// How far a transcription pass has got, while one's running.
    var transcribing: (done: Int, total: Int)?
    /// When the Action button (or another WTF shortcut or control) was last pressed: for the
    /// setup page's "It works".
    var buttonPressedAt: Date?
    /// A start is under way (the first can include downloading the speech model).
    var isStarting = false
    /// Why a start you asked for in the app didn't work, for an alert wherever you are.
    var startFailed: String?
    /// Whether anything's been heard to answer "what was I saying?" from. Until it has, there's
    /// nothing to say, so the card, the pill and the stop sheet don't offer it.
    var hasHeard = false

    static let quickQuestion = "WTF was I just on about?"

    private init() {
        container = try! ModelContainer(for: Chunk.self, Conversation.self, ActionItem.self, Person.self, Fact.self)
        pipeline = Pipeline(modelContainer: container)
        // Everything WTF keeps stays on this iPhone: not in iCloud or computer backups either.
        var support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? support.setResourceValues(values)
        let pipeline = pipeline
        Recorder.shared.onChunk = { url, start, end in
            Task { @MainActor in
                AppModel.shared.heardSomething(true)
                // Keep Transcripts applies while WTF listens in the background too, not only on opening.
                if Date().timeIntervalSince(AppModel.shared.lastExpiry) > 3600 {
                    AppModel.shared.lastExpiry = Date()
                    await AppModel.shared.expireOld()
                }
            }
            Task {
                await pipeline.addChunk(url: url, start: start, end: end)
                await pipeline.run()
                await Standby.shared.refresh()
            }
        }
        Recorder.shared.onSpeech = { samples, chunk, offset in LiveTranscriber.shared.feed(samples, chunk: chunk, offset: offset) }
        // iOS doesn't always say when a call's over, so if listening hasn't come back in a few
        // minutes, a notification says so (and is withdrawn if it does come back).
        Recorder.shared.onInterrupted = {
            let content = UNMutableNotificationContent()
            content.title = "WTF has paused listening"
            content.body = "Something took the microphone. Open WTF to carry on."
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 180, repeats: false)
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: AppModel.pausedNotice, content: content, trigger: trigger))
        }
        Recorder.shared.onResumed = {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [AppModel.pausedNotice])
        }
        Recorder.shared.onStopped = { [weak self] in
            Log.error("Listening stopped: couldn't get the microphone back")
            let content = UNMutableNotificationContent()
            content.title = "WTF stopped listening"
            content.body = "Something else took the microphone. Open WTF to carry on."
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [AppModel.pausedNotice])
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: AppModel.pausedNotice, content: content, trigger: nil))
            Task { @MainActor in
                self?.recording = false
                ListeningActivity.shared.stop()
                self?.problem = "Listening stopped: something else took the microphone. Tap to carry on."
            }
        }
    }

    func setListening(_ on: Bool) {
        if on {
            Task {
                if !(await startListening()), let problem { startFailed = problem }
            }
        } else {
            Recorder.shared.stop()
            recording = false
            ListeningActivity.shared.stop()
            UserDefaults.standard.set(false, forKey: "listening")
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [AppModel.pausedNotice])
            stops += 1
            let stop = stops
            // The last recording's words are taken from the live transcript before it stops.
            // Pausing ends the conversation: it gets its title and summary now, not in five minutes.
            // Unless listening's started again meanwhile: then the live transcriber and the
            // conversation belong to the new session and are left alone.
            Task {
                await pipeline.catchUp()
                guard stop == stops, !recording, starting == nil else { return }
                await LiveTranscriber.shared.stop()
                await pipeline.closeLatest()
                await pipeline.run()
            }
        }
    }

    /// Starts listening and returns once it has (or couldn't): for the app, and for the Action
    /// button and controls, which start it without opening the app. A second ask while a start is
    /// under way (the app coming forward as a press starts it) waits for that one.
    @discardableResult
    func startListening() async -> Bool {
        if let starting { return await starting.value }
        let start = Task { await startListeningNow() }
        starting = start
        isStarting = true
        let started = await start.value
        starting = nil
        isStarting = false
        return started
    }

    @ObservationIgnored private var starting: Task<Bool, Never>?
    /// Counts stops, so a stop's tidying up doesn't run into a listening session started since.
    @ObservationIgnored private var stops = 0

    private func startListeningNow() async -> Bool {
        if recording && Recorder.shared.running { return true }
        guard await AVPermissions.microphone() else {
            problem = "WTF needs the microphone: Settings › Privacy & Security › Microphone."
            return false
        }
        var microphone = false
        do {
            // Only the first time does the speech model need fetching; after that, no network at all.
            if !(await SpeechEngine.shared.isReady()) { try await SpeechEngine.shared.prepare() }
            // The voice models download once (about 22 MB) while you talk.
            if VoiceEngine.enabled, !VoiceEngine.downloaded {
                Task.detached(priority: .utility) { try? await VoiceEngine.shared.prepare() } // failures are logged inside
            }
            heardSomething(await pipeline.conversationCount() > 0)
            // Now it's clear why: WTF says when it stops listening, and what it heard to act on.
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            // The Lock Screen card first: iOS only lets an app start the microphone from the Lock
            // Screen or the Action button if its card is showing.
            ListeningActivity.shared.start()
            await LiveTranscriber.shared.start()
            microphone = true
            let stopsBefore = stops
            try await switchMicrophoneOn()
            if stops != stopsBefore {
                // Stopped while it was starting: stays stopped.
                Recorder.shared.stop()
                ListeningActivity.shared.stop()
                return false
            }
            recording = true
            listeningSince = Date()
            problem = nil
            UserDefaults.standard.set(true, forKey: "listening")
            return true
        } catch {
            Log.error("Couldn't start listening", error)
            ListeningActivity.shared.stop()
            await LiveTranscriber.shared.stop()
            if !microphone {
                problem = "Couldn\u{2019}t get speech recognition ready. Check Wi-Fi and free space, then try again."
            } else if UIApplication.shared.applicationState != .background {
                problem = "Couldn\u{2019}t switch the microphone on: \(Self.why(error)). Try again in a moment."
            } else {
                problem = "iOS didn\u{2019}t let WTF switch the microphone on from here. Open WTF to start listening."
            }
            return false
        }
    }

    /// What iOS said when the microphone wouldn't come on, in a few plain words.
    private static func why(_ error: Error) -> String {
        if error is NoMicrophone { return "it wasn\u{2019}t ready" }
        let e = error as NSError
        return MicTrouble.reason(e.code) ?? "iOS said no (\(e.code))"
    }

    /// The microphone on, with a few quick tries: from the Lock Screen or the Action button, iOS
    /// can be holding the audio for a moment (its own panel) and say no to the first ask.
    private func switchMicrophoneOn() async throws {
        var lastError: Error?
        for attempt in 1...4 {
            do {
                try Recorder.shared.start()
                if attempt > 1 { Log.info("The microphone came on at try \(attempt)") }
                return
            } catch {
                lastError = error
                Log.error("The microphone didn't come on (try \(attempt) of 4)", error)
                if attempt < 4 { try? await Task.sleep(for: .milliseconds(400 * attempt)) }
            }
        }
        if let lastError { throw lastError }
    }

    /// From an App Intent: brings WTF forward, for when iOS won't let it switch the microphone on
    /// from the background. True if WTF's now in front.
    typealias ComeForward = @MainActor () async -> Bool

    /// Listening on, from the Action button or a Shortcut. iOS doesn't let apps other than its own
    /// switch the microphone on from the background, so from there [forward] brings WTF forward
    /// first and it starts there: nothing's tried in the background, where a try only fails, and
    /// with WTF already open it just starts. Without [forward] (a control) it tries where it is.
    func startListeningFromShortcut(forward: ComeForward? = nil) async -> Bool {
        // Apple's rule for recording shortcuts: listening started from one needs its Lock Screen
        // card, and with Live Activities turned off there isn't one.
        guard ListeningActivity.allowed else {
            problem = "To start listening from here, turn on Live Activities for WTF (Settings \u{203A} Apps \u{203A} WTF). Or open WTF and tap Listen."
            return false
        }
        if let forward, UIApplication.shared.applicationState == .background, !Recorder.shared.running {
            guard await forward() else {
                problem = "iOS didn\u{2019}t let WTF switch the microphone on from here. Open WTF to start listening."
                return false
            }
        }
        return await startListening()
    }

    static let pausedNotice = "wtf.listening.paused"

    /// On opening the app: if listening should be on but the mic isn't running, start it again.
    func resumeIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "listening") else { return }
        if !recording || !Recorder.shared.running {
            setListening(true)
        } else if Recorder.shared.stalled {
            Recorder.shared.resume(why: "on opening the app")
            if Recorder.shared.stalled {
                problem = "Listening stopped: something else has the microphone. Tap to carry on."
            } else {
                problem = nil
            }
        }
    }

    func processNow() {
        Task { await pipeline.run() }
    }

    /// A question or answer in Ask, kept.
    func add(_ message: ChatMessage) {
        messages.append(message)
        ChatLog.save(messages)
    }

    /// Settings › Delete All Recordings: everything heard, and everything asked and written about it.
    func deleteEverything() async {
        let wasListening = recording
        // The screens step aside first: one left showing a conversation as it's deleted would read
        // it after it's gone, and that crashes the app.
        wiping = true
        stopSheet = false
        timelinePath = NavigationPath()
        settingsPath = NavigationPath()
        if wasListening { setListening(false) }
        messages = []
        ChatLog.save([])
        DayDigests.shared.forget()
        Standby.shared.forget()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        try? await Task.sleep(for: .milliseconds(300))
        await pipeline.deleteEverything()
        container.mainContext.rollback()
        heardSomething(false)
        try? await Task.sleep(for: .milliseconds(300))
        wiping = false
        if wasListening { setListening(true) }
    }

    /// While everything's being deleted: the screens are swapped for a "Deleting" note.
    var wiping = false

    /// One conversation deleted (from the Timeline or its own page): it, its suggestions and
    /// what was asked about it go. Deleted here, where the screens' copies are, so none is left
    /// pointing at it; the pipeline lets go of it first.
    func deleteConversation(_ id: UUID) async {
        let found = (try? container.mainContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id }))) ?? []
        await remove(found)
    }

    /// Conversations older than Settings › Keep Transcripts go, with what was asked about them.
    func expireOld() async {
        // One at a time: at launch it's asked for twice, and both would delete the same ones.
        guard !expiring else { return }
        expiring = true
        defer { expiring = false }
        let days = UserDefaults.standard.integer(forKey: "keepDays")
        let cutoff = Date().addingTimeInterval(-Double(days == 0 ? 7 : days) * 86_400)
        let old = (try? container.mainContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.end < cutoff }))) ?? []
        guard !old.isEmpty else { return }
        await remove(old, keepFacts: true)
        Log.info("\(old.count) conversation\(old.count == 1 ? "" : "s") past keeping went")
    }

    @ObservationIgnored private var expiring = false
    @ObservationIgnored var lastExpiry = Date()

    /// Conversations that are being deleted, kept off the screens meanwhile.
    var hiding: Set<PersistentIdentifier> = []

    /// Deletes [conversations] with their suggestions, facts and recordings, and what Ask said
    /// about them. Safely: off the screens first (and off any page showing one), the pipeline lets
    /// go of them, then they're deleted where the screens' copies are, so none is left pointing at one.
    private func remove(_ conversations: [Conversation], keepFacts: Bool = false) async {
        guard !conversations.isEmpty else { return }
        let context = container.mainContext
        let keys = conversations.map(\.persistentModelID)
        let ids = conversations.map(\.id)
        let days = conversations.map(\.start)
        hiding.formUnion(keys)
        timelinePath = NavigationPath()
        try? await Task.sleep(for: .milliseconds(350))
        if conversations.contains(where: { !$0.closed }) { await pipeline.cutOff() }
        for id in ids { await pipeline.forget(id) }
        for day in days { DayDigests.shared.forget(day: day) }
        for c in conversations { context.delete(c) }
        for id in ids {
            let cid: UUID? = id
            for item in (try? context.fetch(FetchDescriptor<ActionItem>(predicate: #Predicate { $0.conversationID == cid && $0.status == "suggested" }))) ?? [] {
                context.delete(item)
            }
            for fact in (try? context.fetch(FetchDescriptor<Fact>(predicate: #Predicate { $0.conversationID == cid }))) ?? [] {
                if keepFacts { fact.conversationID = nil } else { context.delete(fact) }
            }
            for chunk in (try? context.fetch(FetchDescriptor<Chunk>(predicate: #Predicate { $0.conversationID == cid }))) ?? [] {
                context.delete(chunk)
            }
        }
        try? context.save()
        forgetAsked(about: Set(ids))
        backstory = []
        if recording { ListeningActivity.shared.show(await pipeline.latestThreads()) }
        heardSomething(((try? context.fetchCount(FetchDescriptor<Conversation>())) ?? 0) > 0)
        try? await Task.sleep(for: .milliseconds(500))
        hiding.subtract(keys)
    }

    /// Ask's questions and answers about these conversations go; and with no conversations left
    /// at all, nothing Ask said can stand, so all of it goes.
    func forgetAsked(about ids: Set<UUID>) {
        Standby.shared.forget()
        messages.removeAll { m in (m.about ?? []).contains { ids.contains($0) } }
        if (try? container.mainContext.fetchCount(FetchDescriptor<Conversation>())) == 0 { messages = [] }
        ChatLog.save(messages)
    }

    /// On opening: what earlier versions got wrong put right, old conversations gone, and Ask
    /// cleared if everything it was about has gone.
    func tidyUp() async {
        await pipeline.repairOnce()
        await expireOld()
        forgetAsked(about: [])
    }

    /// The question [from] and the answers after it: what they drew on.
    private func tag(from id: UUID, about: Set<UUID>) {
        guard !about.isEmpty, let i = messages.firstIndex(where: { $0.id == id }) else { return }
        for j in i..<messages.count where messages[j].about == nil { messages[j].about = Array(about) }
        ChatLog.save(messages)
    }

    /// From the Action button, a shortcut or Siri: go to Ask and ask the quick question.
    func askFromShortcut() {
        tab = 0
        ask(Self.quickQuestion)
    }

    func ask(_ question: String, focus: UUID? = nil) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, status == nil else { return }
        let asked = ChatMessage(fromUser: true, text: q)
        add(asked)
        Brain.prewarm()
        status = "Catching up on the last few seconds\u{2026}"
        Task {
            // The conversations the answer draws on: deleting one deletes the question and answer too.
            var about = Set(focus.map { [$0] } ?? [])
            defer { status = nil; streaming = nil; tag(from: asked.id, about: about) }
            // Close the chunk being recorded and transcribe it, so "just now" includes it (30 s at most).
            Recorder.shared.flush()
            let pipeline = pipeline
            if await withDeadline(20, { await pipeline.catchUp() }) == nil {
                Log.error("Catching up took over 20 s; answering from what's transcribed so far")
                add(ChatMessage(fromUser: false, text: "The last few seconds are still being transcribed, so this may miss them."))
            }
            // Questions about the list are answered straight from it.
            if focus == nil, let direct = ListAnswers.answer(q, open: openItems()) {
                add(ChatMessage(fromUser: false, text: direct))
                return
            }
            let intent = Prompts.intent(q)
            let now = Date()
            if focus == nil, intent == .digest, Brain.notReadyReason == nil, q.lowercased().contains("day") {
                let today = Calendar.current.startOfDay(for: now)
                let all = (try? container.mainContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.start >= today }, sortBy: [SortDescriptor(\.start)]))) ?? []
                let notes = all.filter { $0.title != nil && $0.title != "" }.map(\.dayNote)
                if !notes.isEmpty, let recap = await DayDigests.shared.recap(for: today, notes: notes) {
                    about.formUnion(all.map(\.id))
                    add(ChatMessage(fromUser: false, text: recap))
                    return
                }
            }
            let latest = await pipeline.latestConversation()
            if focus == nil, intent == .latest {
                guard let latest else {
                    add(ChatMessage(fromUser: false, text: recording ? "I haven't heard anything yet. Keep talking and I'll keep track." : "I haven't heard anything yet. Turn on listening and I'll keep track."))
                    return
                }
                about.insert(latest.id)
                // Word for word, straight away; the AI's gist follows.
                if let recap = QuickRecap.of(latest.transcript, start: latest.start, now: now) {
                    add(ChatMessage(fromUser: false, text: recap))
                }
                guard Brain.notReadyReason == nil else { return }
                let background = await pipeline.latestBackground()
                await answer(Prompts.latest(question: q, transcript: latest.transcript, topic: latest.title, now: now, background: background, start: latest.start))
                return
            }
            if let why = Brain.notReadyReason {
                add(ChatMessage(fromUser: false, text: why))
                return
            }
            let found = await pipeline.notes(for: q, focus: focus)
            about.formUnion(found.used)
            guard !found.notes.isEmpty else {
                add(ChatMessage(fromUser: false, text: recording ? "I haven't heard anything yet. Keep talking and I'll keep track." : "I haven't heard anything yet. Turn on listening and I'll keep track."))
                return
            }
            await answer(Prompts.focused(question: q, notes: found.notes, best: found.best, now: now, background: found.background))
        }
    }

    /// Settings › People › Forget: deleted where the People list's copies are (deleting it from the
    /// pipeline's own context while the list showed it could crash).
    func forgetPerson(_ person: Person) {
        container.mainContext.delete(person)
        try? container.mainContext.save()
    }

    /// Whether there's anything to answer "what was I saying?" from (see hasHeard).
    func heardSomething(_ heard: Bool) {
        guard hasHeard != heard else { return }
        hasHeard = heard
        ListeningActivity.shared.heard(heard)
    }

    /// An answer from a button with nowhere of its own to show it (the pill's, the Lock Screen
    /// card's, a control's): it shows on the card and the pill while listening, or as a
    /// notification if not. It's in Ask too, and read out if headphones are in.
    func showAnswer(_ answer: String) {
        if ListeningActivity.shared.showing {
            ListeningActivity.shared.showAnswer(answer)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "WTF"
        content.body = answer
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wtf.answer", content: content, trigger: nil))
    }

    /// The Action button's (or Siri's, or a control's) answer: kept in Ask, read into your ears if
    /// AirPods or headphones are in, and returned to show on screen. Always back within a few
    /// seconds: it uses the answer kept ready while you talked if nothing's been said since,
    /// otherwise works one out with a short limit, and falls back to what was said word for word.
    ///
    /// It always answers, listening or not (starting listening is its own button): from what was
    /// heard before if it's off. Pressed again within 20 seconds of an answer, it goes a step
    /// further back: the topic left hanging before that, then the one before. After that it starts over.
    func answerFromShortcut() async -> String {
        buttonPressedAt = Date()
        let pressed = Date()
        // Listening was meant to be on, but something (a call, iOS closing WTF) stopped it: the
        // answer says so, as it only covers what was heard before then.
        let stopped = !recording && UserDefaults.standard.bool(forKey: "listening")
        var answer: String
        let again = pressed.timeIntervalSince(lastPress) < 20
        var stepped = true
        if again, backstory.indices.contains(step) {
            answer = backstory[step]
            step += 1
        } else if again, backstory.isEmpty, step == 0 {
            answer = "Nothing before that: it's all been one topic so far."
            step = 1
        } else {
            stepped = false
            answer = await Standby.shared.answerNow()
            let threads = await pipeline.latestThreads()
            backstory = Threads.backstory(threads)
            step = 0
        }
        if step == backstory.count, step > 0, pressed.timeIntervalSince(lastPress) < 20 {
            answer += " That's as far back as I've got."
            step += 1
        }
        if stopped, !answer.contains("listening") { answer += " WTF stopped listening, so open it to start again." }
        lastPress = Date()
        let about = await pipeline.latestConversation().map { [$0.id] }
        add(ChatMessage(fromUser: true, text: stepped ? "What came before that?" : Self.quickQuestion, about: about))
        add(ChatMessage(fromUser: false, text: answer, about: about))
        // Waits only until it's started playing: the sound keeps the app awake to the end.
        let reading = await ReadAloud.shared.startIntoHeadphones(answer)
        Log.info("Action button: answered in \(String(format: "%.1f", Date().timeIntervalSince(pressed))) s, \(reading ? "reading it out" : "shown only")")
        return answer
    }

    /// "What came before that?" on its own (from the WTF Menu): the next step back each time.
    func beforeThatFromShortcut() async -> String {
        buttonPressedAt = Date()
        if backstory.isEmpty || Date().timeIntervalSince(lastPress) >= 20 {
            let threads = await pipeline.latestThreads()
            backstory = Threads.backstory(threads)
            step = 0
        }
        let answer: String
        if backstory.indices.contains(step) {
            answer = backstory[step]
            step += 1
        } else {
            answer = backstory.isEmpty ? "Nothing before that: it's all been one topic so far." : "That's as far back as I've got."
            step = 0
        }
        lastPress = Date()
        let about = await pipeline.latestConversation().map { [$0.id] }
        add(ChatMessage(fromUser: true, text: "What came before that?", about: about))
        add(ChatMessage(fromUser: false, text: answer, about: about))
        _ = await ReadAloud.shared.startIntoHeadphones(answer)
        return answer
    }

    /// Where pressing again goes: the topics before what you were just saying, and how far it's got.
    private var backstory: [String] = []
    private var step = 0
    private var lastPress = Date.distantPast

    /// Listening on or off, from a control or a Shortcut, without opening the app.
    func toggleListeningFromShortcut(forward: ComeForward? = nil) async -> String {
        buttonPressedAt = Date()
        if recording {
            setListening(false)
            return "WTF has stopped listening."
        }
        return await startListeningFromShortcut(forward: forward) ? "WTF is listening." : (problem ?? "Couldn't start listening.")
    }

    /// Your list, read out (or shown): what's coming up, what to do, what to buy.
    func listFromShortcut() async -> String {
        buttonPressedAt = Date()
        let open = openItems()
        var parts: [String] = []
        let now = Date()
        let events = open.filter { $0.type == .event && ($0.start ?? .distantFuture) >= now.addingTimeInterval(-3600) }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }.prefix(3)
        if !events.isEmpty {
            parts.append("Coming up: " + events.map { e in
                e.title + (e.start.map { " " + (($0.timeIntervalSinceNow < 6 * 86_400 ? $0.formatted(.dateTime.weekday(.wide)) : $0.formatted(.dateTime.weekday(.wide).day().month(.wide))) + (e.allDay ? "" : " at " + $0.formatted(date: .omitted, time: .shortened))) } ?? "")
            }.joined(separator: ", ") + ".")
        }
        let todos = open.filter { $0.type == .todo }.prefix(5).map(\.title)
        if !todos.isEmpty { parts.append("To do: " + todos.joined(separator: ", ") + ".") }
        let buy = open.filter { $0.type == .buy }.prefix(8).map(\.title)
        if !buy.isEmpty { parts.append("To buy: " + buy.joined(separator: ", ") + ".") }
        let answer = parts.isEmpty ? "Your list's empty." : parts.joined(separator: " ")
        _ = await ReadAloud.shared.startIntoHeadphones(answer)
        return answer
    }

    /// The answer to "what was I saying?", short enough to be read out in your ear, from what's
    /// been transcribed so far plus [live] (words heard in the last few seconds, not yet sorted
    /// by speaker). Nil if nothing's been heard. [ai]: seconds to give Apple Intelligence (0: none).
    func workOutRecap(live: String, ai: Double) async -> (text: String, covers: Date, byAI: Bool)? {
        let latest = await pipeline.latestConversation()
        let now = Date()
        var transcript = latest?.transcript ?? ""
        if !live.isEmpty {
            let line = TranscriptFormat.lines([Utterance(start: now, speaker: Labels.anonymous, text: live)])
            transcript += (transcript.isEmpty ? "" : "\n") + line
        }
        guard !transcript.isEmpty else { return nil }
        let start = latest?.start ?? now
        let covers = latest?.end ?? .distantPast
        if ai > 0, Brain.notReadyReason == nil {
            let threads = await pipeline.latestThreads()
            let hanging = Threads.hanging(threads).first.map { "\($0.title): \($0.leftAt ?? "")" }
            let topic = threads.last(where: { $0.status == .current })?.title ?? latest?.title
            let background = await pipeline.latestBackground()
            if let gist = await Brain.quick(Prompts.spoken(transcript: transcript, topic: topic, leftAt: hanging, now: now, background: background, start: latest?.start), seconds: ai)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !gist.isEmpty {
                return (gist, covers, true)
            }
        }
        guard let plain = QuickRecap.spoken(transcript, start: start, now: now) else { return nil }
        return (plain, covers, false)
    }

    /// Tapping a topic on the trail: where you'd got to with it.
    func askAbout(_ thread: TopicThread, in conversation: UUID) {
        guard status == nil else { return }
        tab = 0
        let asked = ChatMessage(fromUser: true, text: "Where was I with \u{201C}\(thread.title)\u{201D}?")
        add(asked)
        status = "Looking back\u{2026}"
        Task {
            defer { status = nil; streaming = nil; tag(from: asked.id, about: [conversation]) }
            let lines = await pipeline.lines(of: thread, in: conversation)
            guard !lines.isEmpty else {
                add(ChatMessage(fromUser: false, text: "I can't find what was said about that."))
                return
            }
            if Brain.notReadyReason == nil {
                await answer(Prompts.thread(thread.title, leftAt: thread.leftAt, lines: lines))
            } else {
                // No AI: the sentences that mention it, word for word.
                let quotes = Prompts.sentences(about: thread.title, in: lines)
                add(ChatMessage(fromUser: false, text: quotes.isEmpty ? "I can't find what was said about that."
                    : "What was said about it:\n" + quotes.map { "\u{201C}\($0)\u{201D}" }.joined(separator: "\n")))
            }
        }
    }

    private func answer(_ prompt: String) async {
        status = "Thinking\u{2026}"
        // Written in a task of its own, given up on after a minute: Apple's AI can stall, and
        // Ask would be stuck on "Thinking…" until WTF was closed.
        let writing = Task { @MainActor () -> (text: String, error: Error?) in
            var text = ""
            do {
                for try await soFar in Brain.ask(prompt) {
                    text = Prompts.tidy(soFar)
                    streaming = text
                }
                return (text, nil)
            } catch {
                return (text, error)
            }
        }
        let limit = Task { try? await Task.sleep(for: .seconds(60)); writing.cancel() }
        let (text, failure) = await writing.value
        limit.cancel()
        streaming = nil
        if let failure { Log.error("Apple Intelligence couldn't answer", failure) }
        if !text.isEmpty {
            add(ChatMessage(fromUser: false, text: text))
        } else if failure == nil && !writing.isCancelled {
            add(ChatMessage(fromUser: false, text: "I couldn\u{2019}t find an answer to that in what I heard."))
        }
        if failure != nil || writing.isCancelled {
            add(ChatMessage(fromUser: false, text: writing.isCancelled ? "Apple Intelligence took too long to answer. Try again in a moment."
                                : "Apple Intelligence couldn\u{2019}t answer that one. Try asking another way.", isError: true))
        }
    }

    private func openItems() -> [ListAnswers.Item] {
        let items = (try? container.mainContext.fetch(FetchDescriptor<ActionItem>(predicate: #Predicate { $0.status == "accepted" }))) ?? []
        return items.map { ListAnswers.Item(type: ActionType(rawValue: $0.type) ?? .todo, title: $0.title, start: $0.start, allDay: $0.allDay, place: $0.place) }
    }
}

enum AVPermissions {
    static func microphone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
