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
    /// What's open on top of the Timeline and Settings tabs (closed when what it shows is deleted).
    var timelinePath = NavigationPath()
    var settingsPath = NavigationPath()
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
    /// Listening's on but the microphone isn't running: something (a call, Siri) has it. The
    /// card and the pill say so wherever it's set.
    var paused = false {
        didSet { if paused != oldValue { ListeningActivity.shared.paused(paused) } }
    }
    /// Settings › Better Accuracy's download, while it's under way: kept here rather than on the
    /// page, so the bar carries on when the page is rebuilt (after Delete All, say).
    var betterProgress: Double?
    /// How far the speech model's download has got (0 to 1), while one's under way: shown in place
    /// of "Starting…", as the first start can take minutes.
    var speechDownload: Double?

    static let quickQuestion = "WTF was I just on about?"

    /// The store didn't open and WTF is running on one kept in memory: what's on disk, Ask's
    /// history included, is left alone for next time. Said in Ask for as long as it lasts.
    private(set) var storeLost = false
    static let noSpaceNote = "WTF can\u{2019}t save recordings. Check your iPhone has free space."
    static let storeLostNote = "WTF couldn\u{2019}t open what it\u{2019}s kept, so nothing heard now will be saved. Free some space or restart the iPhone, then open WTF again."
    /// What Ask's note says when nothing's wrong: nothing, unless the store's been lost, which
    /// starting listening doesn't put right.
    private var noProblem: String? { storeLost ? Self.storeLostNote : nil }

    private init() {
        // A store that won't open (no space, damaged, a failed update) would otherwise crash every
        // launch and every button. Left where it is, as it may well open next time: WTF runs on
        // a store kept in memory meanwhile, and Ask says so.
        var storeFailed = false
        do {
            container = try ModelContainer(for: Chunk.self, Conversation.self, ActionItem.self, Person.self, Fact.self)
        } catch {
            Log.error("Couldn't open the store", error)
            storeFailed = true
            container = try! ModelContainer(for: Chunk.self, Conversation.self, ActionItem.self, Person.self, Fact.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        pipeline = Pipeline(modelContainer: container)
        // Without this, iOS drops a button's answer notification while WTF is in front.
        UNUserNotificationCenter.current().delegate = Self.notices
        if storeFailed {
            storeLost = true
            problem = Self.storeLostNote
        }
        // Everything WTF keeps stays on this iPhone: not in iCloud or computer backups either.
        var support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? support.setResourceValues(values)
        let pipeline = pipeline
        Recorder.shared.onChunk = { url, start, end in
            Task { @MainActor in
                // Keep Transcripts applies while WTF listens in the background too, not only on opening.
                if Date().timeIntervalSince(AppModel.shared.lastExpiry) > 3600 {
                    AppModel.shared.lastExpiry = Date()
                    await AppModel.shared.expireOld()
                }
            }
            Task {
                await pipeline.addChunk(url: url, start: start, end: end)
                await pipeline.run()
                // Only once it's in a conversation: a recording that turns out to be music isn't
                // anything to answer "what was I saying?" from.
                if await pipeline.conversationCount() > 0 {
                    await MainActor.run { AppModel.shared.heardSomething(true) }
                }
                await Standby.shared.refresh()
            }
        }
        Recorder.shared.onSpeech = { samples, chunk, offset in
            SpeechHeard.shared.add(chunk)
            LiveTranscriber.shared.feed(samples, chunk: chunk, offset: offset)
        }
        Recorder.shared.onDiscard = { chunk in
            SpeechHeard.shared.drop(chunk)
            LiveTranscriber.shared.drop(chunk: chunk)
        }
        // Nothing's being saved while this lasts: said where WTF says what's wrong, not only in Diagnostics.
        Recorder.shared.onProblem = { _ in
            Task { @MainActor in AppModel.shared.problem = AppModel.noSpaceNote }
        }
        // And taken down once they save again, rather than left up until listening restarts.
        Recorder.shared.onRecovered = {
            Task { @MainActor in
                if AppModel.shared.problem == AppModel.noSpaceNote { AppModel.shared.problem = AppModel.shared.noProblem }
            }
        }
        // iOS doesn't always say when a call's over, so if listening hasn't come back in a few
        // minutes, a notification says so (and is withdrawn if it does come back). Quietly: it
        // can arrive during the call itself.
        Recorder.shared.onInterrupted = {
            let content = UNMutableNotificationContent()
            content.title = "WTF has paused listening"
            content.body = "Something has the microphone. WTF carries on when it\u{2019}s free; if it doesn\u{2019}t, open WTF."
            content.interruptionLevel = .passive
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 180, repeats: false)
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: AppModel.pausedNotice, content: content, trigger: trigger))
            Task { @MainActor in
                if AppModel.shared.recording { AppModel.shared.paused = true }
            }
        }
        Recorder.shared.onResumed = {
            AppModel.withdrawPausedNotice()
            // The microphone's back, so Ask's "listening stopped" note no longer stands.
            Task { @MainActor in
                AppModel.shared.paused = false
                // Not the free-space note: the microphone coming back doesn't make room to save.
                if AppModel.shared.recording, AppModel.shared.problem != AppModel.noSpaceNote { AppModel.shared.problem = AppModel.shared.noProblem }
            }
        }
        Recorder.shared.onStopped = { [weak self] in
            Log.error("Listening stopped: couldn't get the microphone back")
            let content = UNMutableNotificationContent()
            content.title = "WTF stopped listening"
            content.body = "Something else took the microphone. Open WTF to carry on."
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [AppModel.pausedNotice])
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: AppModel.pausedNotice, content: content, trigger: nil))
            Task { @MainActor in
                guard let self else { return }
                self.recording = false
                self.paused = false
                ListeningActivity.shared.stop()
                self.problem = "Listening stopped: something else took the microphone. Tap to carry on."
                // The live transcriber stops too, once the last recording's words are taken from
                // it; unless listening's being started again meanwhile.
                await self.pipeline.catchUp()
                guard !self.recording, self.starting == nil else { return }
                await LiveTranscriber.shared.stop()
            }
        }
    }

    func setListening(_ on: Bool) {
        if on {
            // Already on but paused, it's not a failed start: the banner says so, not an alert.
            let wasOn = recording
            Task {
                if !(await startListening()), !wasOn, let problem, problem != noProblem { startFailed = problem }
            }
        } else {
            // Off the main thread: letting go of the audio session can take a while. A start
            // straight after waits for it (see switchMicrophoneOn).
            let stopping = Task.detached(priority: .userInitiated) { Recorder.shared.stop() }
            self.stopping = stopping
            recording = false
            paused = false
            // A deliberate stop: no note left saying listening stopped by itself.
            problem = noProblem
            ListeningActivity.shared.stop()
            UserDefaults.standard.set(false, forKey: "listening")
            Self.withdrawPausedNotice()
            stops += 1
            let stop = stops
            // A start under way stops waiting (on the speech model's download, say) and stands down
            // now, rather than showing "Starting…" until the wait's up.
            starting?.cancel()
            // The last recording's words are taken from the live transcript before it stops.
            // Pausing ends the conversation: it gets its title and summary now, not in five minutes.
            // Unless listening's started again meanwhile: then the live transcriber and the
            // conversation belong to the new session and are left alone. From the Lock Screen or
            // Siri nothing else keeps WTF running once the microphone's let go, so iOS is asked
            // for a little time to finish.
            let time = ExtraTime("wtf.stop")
            Task {
                defer { time.end() }
                await stopping.value
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
    /// [tries]: how many times to ask for the microphone (one, for a quick try from the background).
    @discardableResult
    func startListening(tries: Int = 4) async -> Bool {
        if let starting { return await starting.value }
        let start = Task { await startListeningNow(tries: tries) }
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
    /// The last stop's letting go of the microphone, which a start waits for.
    @ObservationIgnored private var stopping: Task<Void, Never>?

    private func startListeningNow(tries: Int) async -> Bool {
        // A stop while this is under way (Settings, Siri, the stop sheet) wins: checked after each wait.
        let stopsBefore = stops
        if recording && Recorder.shared.running {
            // Already on, but a call may have kept the microphone: a start is a try to get it back.
            if Recorder.shared.stalled {
                await Task.detached(priority: .userInitiated) { Recorder.shared.resume(why: "on a start") }.value
            }
            guard !Recorder.shared.stalled else {
                paused = true
                problem = "Paused while something else has the microphone. WTF carries on when it\u{2019}s free."
                return false
            }
            paused = false
            if problem != Self.noSpaceNote { problem = noProblem }
            Self.withdrawPausedNotice()
            // iOS ends the card after about 8 hours, and it can be swiped away: back it comes.
            ListeningActivity.shared.restoreIfNeeded()
            return true
        }
        // Not before the first-run screen has said what WTF does: a shortcut can be used first.
        guard UserDefaults.standard.bool(forKey: "welcomed") else {
            problem = "Before WTF listens, open it to see how it works."
            return false
        }
        // iOS can't ask for the microphone from the background (a control, Siri): until it's been
        // asked in the app, WTF isn't in Settings' Microphone list to point to.
        let background = UIApplication.shared.applicationState == .background
        if background, AVAudioApplication.shared.recordPermission == .undetermined {
            problem = "Open WTF once to let it use the microphone."
            return false
        }
        guard await AVPermissions.microphone() else {
            // Not tried again on every opening: the alert this time says where to turn it on.
            UserDefaults.standard.set(false, forKey: "listening")
            problem = "WTF needs the microphone: Settings › Privacy & Security › Microphone."
            return false
        }
        // Now it's clear why: WTF says when it stops listening, and what it heard to act on. Asked
        // here, before any wait for the speech model, not out of nowhere after it; and only with
        // WTF in front, where iOS can show the question.
        if !background {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        // Stopped while it was starting: stays stopped, with nothing left running.
        func standDown() async -> Bool {
            Recorder.shared.stop()
            ListeningActivity.shared.stop()
            await LiveTranscriber.shared.stop()
            problem = noProblem
            return false
        }
        // Only the first time does the speech model need fetching; after that, no network at all.
        // A stalled download is given up on (it carries on in the system, for the next try), so
        // the starts waiting behind this one aren't stuck.
        if !(await SpeechEngine.shared.isReady()) {
            // Not from the background: a shortcut or Siri is cut off long before the download's
            // waited for, so WTF comes forward (see startListeningFromShortcut) to fetch it there.
            if background {
                problem = "Open WTF to finish getting speech recognition ready."
                return false
            }
            speechDownload = 0
            let fetched: Bool? = await withDeadline(180) { () -> Bool? in
                // A task of its own, so giving up on it doesn't cancel the download too.
                let download = Task {
                    try await SpeechEngine.shared.prepare { p in
                        Task { @MainActor in if AppModel.shared.speechDownload != nil { AppModel.shared.speechDownload = p } }
                    }
                }
                do {
                    try await download.value
                    return true
                } catch {
                    Log.error("Couldn't fetch the speech model", error)
                    return false
                }
            }
            speechDownload = nil
            if stops != stopsBefore { return await standDown() }
            // It can finish without installing anything (iOS declined, or nothing for this language).
            guard fetched == true, await SpeechEngine.shared.isReady() else {
                switch fetched {
                case nil: problem = "Speech recognition is still downloading. Check Wi-Fi, then try again."
                case false?: problem = "Couldn\u{2019}t get speech recognition ready. Check Wi-Fi and free space, then try again."
                case true?: problem = "iOS didn\u{2019}t install the speech model. Free some space and check Wi-Fi, then try again."
                }
                return false
            }
        }
        // The voice models download once (about 22 MB) while you talk.
        if VoiceEngine.enabled, !VoiceEngine.downloaded {
            Task.detached(priority: .utility) { try? await VoiceEngine.shared.prepare() } // failures are logged inside
        }
        heardSomething(await pipeline.conversationCount() > 0)
        // The Lock Screen card first: iOS only lets an app start the microphone from the Lock
        // Screen or the Action button if its card is showing.
        let carded = ListeningActivity.shared.start()
        // From the background, iOS won't let the microphone on without the card: said plainly,
        // rather than as a microphone error after the tries.
        if !carded, ListeningActivity.allowed, UIApplication.shared.applicationState == .background {
            problem = "Couldn\u{2019}t show the Lock Screen card, so WTF can\u{2019}t listen from here. Open WTF to start."
            return false
        }
        await LiveTranscriber.shared.start()
        if stops != stopsBefore { return await standDown() }
        do {
            try await switchMicrophoneOn(tries: tries)
        } catch {
            Log.error("Couldn't start listening", error)
            ListeningActivity.shared.stop()
            await LiveTranscriber.shared.stop()
            if stops != stopsBefore {
                problem = noProblem
            } else if UIApplication.shared.applicationState != .background {
                problem = "Couldn\u{2019}t switch the microphone on: \(Self.why(error)). Try again in a moment."
            } else {
                problem = "iOS didn\u{2019}t let WTF switch the microphone on from here. Open WTF to start listening."
            }
            return false
        }
        if stops != stopsBefore { return await standDown() }
        recording = true
        paused = false
        listeningSince = Date()
        problem = noProblem
        // Listening again: an earlier "stopped" or "paused" notice no longer stands.
        Self.withdrawPausedNotice()
        UserDefaults.standard.set(true, forKey: "listening")
        // A backstop: a task that ended the card as this started would leave listening without it.
        ListeningActivity.shared.restoreIfNeeded()
        return true
    }

    /// What iOS said when the microphone wouldn't come on, in a few plain words.
    private static func why(_ error: Error) -> String {
        if error is NoMicrophone { return "it wasn\u{2019}t ready" }
        let e = error as NSError
        return MicTrouble.reason(e.code) ?? "iOS said no (\(e.code))"
    }

    /// The microphone on, with a few quick tries: from the Lock Screen or the Action button, iOS
    /// can be holding the audio for a moment (its own panel) and say no to the first ask.
    private func switchMicrophoneOn(tries: Int) async throws {
        // A stop just before lets go of the microphone first, so it can't undo this start.
        await stopping?.value
        var lastError: Error?
        for attempt in 1...max(1, tries) {
            do {
                // Off the main thread: setting up the audio session can take a while.
                try await Task.detached(priority: .userInitiated) { try Recorder.shared.start() }.value
                if attempt > 1 { Log.info("The microphone came on at try \(attempt)") }
                return
            } catch {
                lastError = error
                Log.error("The microphone didn't come on (try \(attempt) of \(tries))", error)
                if attempt < tries { try? await Task.sleep(for: .milliseconds(400 * attempt)) }
            }
        }
        if let lastError { throw lastError }
    }

    /// From an App Intent: brings WTF forward, for when iOS won't let it switch the microphone on
    /// from the background. True if WTF's now in front.
    typealias ComeForward = @MainActor () async -> Bool

    /// Listening on, from the Action button or a Shortcut. From the background, a recording
    /// shortcut ([recordingIntent]: Start Listening, Start or Stop Listening) tries where it is
    /// (twice: iOS often says no to the first ask), its Lock Screen card up first, as Apple's rules
    /// for those allow; only if iOS says no does [forward] bring WTF forward to start there. Any
    /// other (the WTF Menu) can't record from the background, so it comes forward straight away.
    /// With WTF already open it just starts. Without [forward] (a control) it tries where it is.
    func startListeningFromShortcut(forward: ComeForward? = nil, recordingIntent: Bool = false) async -> Bool {
        // Already listening: nothing to start, whatever the Live Activities setting.
        if recording && Recorder.shared.running { return await startListening() }
        let background = UIApplication.shared.applicationState == .background
        // Apple's rule for recording shortcuts: listening started from one in the background
        // needs its Lock Screen card, and with Live Activities turned off there isn't one. With
        // WTF in front, or able to come forward, it starts there as the Listen button does.
        if !ListeningActivity.allowed, background, forward == nil {
            problem = "To start listening from here, turn on Live Activities for WTF (Settings \u{203A} Apps \u{203A} WTF). Or open WTF and tap Listen."
            return false
        }
        if let forward, background, !Recorder.shared.running {
            if recordingIntent && ListeningActivity.allowed {
                if await startListening(tries: 2) {
                    Log.info("Started listening from a shortcut without opening WTF")
                    return true
                }
                Log.info("iOS didn't let WTF start listening from the background; opening WTF to start it")
            }
            guard await forward() else {
                problem = "iOS didn\u{2019}t let WTF switch the microphone on from here. Open WTF to start listening."
                return false
            }
        }
        return await startListening()
    }

    nonisolated static let pausedNotice = "wtf.listening.paused"

    /// The paused or stopped notice, waiting or already shown: once listening's back, it's wrong.
    nonisolated static func withdrawPausedNotice() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [pausedNotice])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [pausedNotice])
    }

    /// Shows a button's answer notification while WTF is in front (see AnswerNotices).
    private static let notices = AnswerNotices()

    /// On opening the app: if listening should be on but the mic isn't running, start it again.
    func resumeIfNeeded() {
        // A start from Control Center or Siri that didn't work says to open WTF: not once it's open.
        if !recording, !isStarting, let problem, problem != Self.storeLostNote, problem.localizedCaseInsensitiveContains("open WTF") {
            self.problem = "Listening didn\u{2019}t start. Tap to start it."
        }
        guard UserDefaults.standard.bool(forKey: "listening") else { return }
        if !recording || !Recorder.shared.running {
            setListening(true)
        } else if Recorder.shared.stalled {
            // Off the main thread: getting the audio session back can take a while.
            Task {
                await Task.detached(priority: .userInitiated) { Recorder.shared.resume(why: "on opening the app") }.value
                guard recording else { return }
                if Recorder.shared.stalled {
                    paused = true
                    problem = "Paused while something else has the microphone. WTF carries on when it\u{2019}s free."
                } else {
                    paused = false
                    problem = noProblem
                }
            }
        }
    }

    /// A tap on the listening pill: the sheet to stop. If WTF had been closed (or crashed), the
    /// pill is one left from before and listening's coming back as WTF opens: the sheet shows once
    /// it has, rather than the tap being lost and listening carrying on with no way to stop shown.
    func openedFromPill() {
        if recording {
            stopSheet = true
            return
        }
        guard UserDefaults.standard.bool(forKey: "listening") else { return }
        let stopsBefore = stops
        Task {
            guard await startListening(), recording, stops == stopsBefore else { return }
            stopSheet = true
        }
    }

    /// [force]: asked for (Transcribe Now), so a recording that failed is tried again now too; not
    /// on every opening of the app, where it waits its turn (see Pipeline.catchUp).
    func processNow(force: Bool = false) {
        Task { await pipeline.run(force: force) }
    }

    /// A question or answer in Ask, kept. While a question's being answered, its answers are
    /// tagged with what it drew on as they're added, so deleting one of those conversations
    /// mid-answer takes them too; and once the question itself has gone (deleted, or Delete All),
    /// what was still to come of its answer isn't added at all.
    func add(_ message: ChatMessage) {
        var message = message
        if let asking, !message.fromUser, message.id != asking.question {
            guard messages.contains(where: { $0.id == asking.question }) else { return }
            if message.about == nil, !asking.about.isEmpty { message.about = Array(asking.about) }
        }
        messages.append(message)
        ChatLog.save(messages)
    }

    /// The question being answered now, and the conversations its answer draws on so far.
    @ObservationIgnored private var asking: (question: UUID, about: Set<UUID>)?

    /// The answer to [question] draws on [about]: the question and what's been said so far are
    /// tagged straight away, not only once it's finished.
    private func drawsOn(_ about: Set<UUID>, question: UUID) {
        asking = (question, about)
        tag(from: question, about: about)
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
        // A question still being answered would read what's being deleted, and add its answer after.
        stopAsking()
        messages = []
        ChatLog.save([])
        DayDigests.shared.forget()
        Standby.shared.forget()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        try? await Task.sleep(for: .milliseconds(300))
        await pipeline.deleteEverything()
        // Diagnostics go too: they hold no words, but they do say when WTF was listening.
        Log.clear()
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
    /// [fromItsPage]: its own page has closed itself, so the pages under it (its day) stay open.
    func deleteConversation(_ id: UUID, fromItsPage: Bool = false) async {
        let found = (try? container.mainContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id }))) ?? []
        await remove(found, keepPath: fromItsPage)
    }

    /// Conversations older than Settings › Keep Transcripts go, with what was asked about them.
    func expireOld() async {
        // One at a time: at launch it's asked for twice, and both would delete the same ones.
        guard !expiring else { return }
        expiring = true
        defer { expiring = false }
        let days = UserDefaults.standard.integer(forKey: "keepDays")
        let cutoff = Date().addingTimeInterval(-Double(days == 0 ? 7 : days) * 86_400)
        // Ask's history keeps no longer than that either (as ChatLog keeps it), while WTF runs as
        // well as on opening: answers about no conversation (the list, say) too.
        let before = messages.count
        messages.removeAll { $0.date < cutoff }
        if messages.count != before { ChatLog.save(messages) }
        let context = container.mainContext
        // Ticked-off and turned-down list items are kept a while (so they aren't suggested again
        // from the same talk), then go too: here, where the List's copies are. Counted from when
        // they were ticked off (those from before that was kept, from when they were heard).
        let finished = ((try? context.fetch(FetchDescriptor<ActionItem>(predicate: #Predicate { $0.status == "done" || $0.status == "dismissed" }))) ?? [])
            .filter { ($0.doneAt ?? $0.created) < cutoff }
        if !finished.isEmpty {
            for item in finished { context.delete(item) }
            try? context.save()
        }
        let old = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.end < cutoff }))) ?? []
        guard !old.isEmpty else { return }
        // Days old, so none is the conversation going on, even one left open when WTF was closed.
        await remove(old, keepFacts: true, onlyIfShown: true, inProgress: false)
        Log.info("\(old.count) conversation\(old.count == 1 ? "" : "s") past keeping went")
    }

    @ObservationIgnored private var expiring = false
    @ObservationIgnored var lastExpiry = Date()

    /// Conversations that are being deleted, kept off the screens meanwhile.
    var hiding: Set<PersistentIdentifier> = []
    /// The conversations and days (their start) the Timeline's pages are showing, kept by
    /// ConversationView and DayView: an old conversation going past keeping leaves the page
    /// you're reading alone unless it's on it.
    @ObservationIgnored var onScreen: Set<UUID> = []
    @ObservationIgnored var daysOnScreen: Set<Date> = []

    /// Deletes [conversations] with their suggestions, facts and recordings, and what Ask said
    /// about them. Safely: off the screens first (and off any page showing one), the pipeline lets
    /// go of them, then they're deleted where the screens' copies are, so none is left pointing at one.
    /// [onlyIfShown]: the Timeline's pages close only if one of them is showing one of these.
    /// [inProgress]: one still open may be the conversation going on, so what's being recorded goes too.
    /// [keepPath]: the page showing it has closed itself already; the ones under it stay.
    private func remove(_ conversations: [Conversation], keepFacts: Bool = false, onlyIfShown: Bool = false, inProgress: Bool = true, keepPath: Bool = false) async {
        guard !conversations.isEmpty else { return }
        let context = container.mainContext
        let keys = conversations.map(\.persistentModelID)
        let ids = conversations.map(\.id)
        let days = conversations.map(\.start)
        let spans = conversations.map { (start: $0.start, end: $0.end) }
        // Before the views hide them: a recap they start writing again now, without these, is kept.
        for day in days { DayDigests.shared.forget(day: day) }
        hiding.formUnion(keys)
        // Nothing said what's on screen: closed to be safe, as a page left on a deleted one can crash.
        let known = !onScreen.isEmpty || !daysOnScreen.isEmpty
        let shown = !known || !onScreen.isDisjoint(with: ids) || days.contains { daysOnScreen.contains(Calendar.current.startOfDay(for: $0)) }
        if !keepPath && (!onlyIfShown || shown) { timelinePath = NavigationPath() }
        try? await Task.sleep(for: .milliseconds(350))
        // The answer kept ready for the Action button, and the words just heard, are about the
        // latest conversation: they go only if that's one of these, not for every old one expiring.
        let latest = await pipeline.latestConversation()?.id
        // Going on: the latest, still open and not yet quiet for longer than starts a new one. One
        // left open when WTF was ended isn't, so what's been said since opening isn't cut off with it.
        // Talk that's started again within the gap, still being recorded or transcribed, counts too.
        let minutes = UserDefaults.standard.integer(forKey: "gapMinutes")
        let gap = Double(max(1, minutes == 0 ? 5 : minutes)) * 60
        let quiet = Date().addingTimeInterval(-gap)
        let heard = SpeechHeard.shared.starts()
        let goingOn = inProgress && conversations.contains(where: { c in
            !c.closed && c.id == latest && (c.end > quiet || heard.contains { $0 > c.end && $0.timeIntervalSince(c.end) <= gap })
        })
        let current = goingOn || latest.map { ids.contains($0) } == true
        // The answer notification is about the latest conversation.
        if current { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["wtf.answer"]) }
        if goingOn { await pipeline.cutOff() }
        for id in ids { await pipeline.forget(id) }
        // Recordings from then still waiting (a retry) would otherwise come back as a new conversation.
        await pipeline.drop(spans: spans)
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
        if current { Standby.shared.forget() }
        forgetAsked(about: Set(ids))
        backstory = []
        if recording { ListeningActivity.shared.show(await pipeline.latestThreads()) }
        heardSomething(((try? context.fetchCount(FetchDescriptor<Conversation>())) ?? 0) > 0)
        try? await Task.sleep(for: .milliseconds(500))
        hiding.subtract(keys)
    }

    /// Ask's questions and answers about these conversations go; and with no conversations left
    /// at all, nothing Ask said can stand, so all of it goes.
    /// (The Action button's kept answer is the caller's to forget: see remove.)
    func forgetAsked(about ids: Set<UUID>) {
        // What drew on them goes, and with a question that goes, the answers that followed it.
        var dropping = false
        messages.removeAll { m in
            let gone = (m.about ?? []).contains { ids.contains($0) }
            if m.fromUser { dropping = gone } else if dropping { return true }
            return gone
        }
        if !storeLost, (try? container.mainContext.fetchCount(FetchDescriptor<Conversation>())) == 0 { messages = [] }
        ChatLog.save(messages)
    }

    /// On opening: what earlier versions got wrong put right, old conversations gone, and Ask
    /// cleared if everything it was about has gone.
    func tidyUp() async {
        await pipeline.repairOnce()
        await expireOld()
        forgetAsked(about: [])
    }

    /// The question [from] and the answers after it: what they drew on. Added to what they were
    /// tagged with already, as an answer can come to draw on more as it goes (a follow-up's earlier answer).
    private func tag(from id: UUID, about: Set<UUID>) {
        guard !about.isEmpty, let i = messages.firstIndex(where: { $0.id == id }) else { return }
        for j in i..<messages.count { messages[j].about = Array(about.union(messages[j].about ?? [])) }
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
        let earlier = earlierExchange().flatMap { Self.follows(q, on: $0.about, focus: focus) ? $0 : nil }
        let asked = ChatMessage(fromUser: true, text: q, focus: focus)
        add(asked)
        // Questions about the list are answered straight from it: exact and instant, so there's
        // no waiting for the last few seconds to be transcribed.
        if focus == nil, let direct = ListAnswers.answer(q, open: openItems()) {
            add(ChatMessage(fromUser: false, text: direct))
            return
        }
        Brain.prewarm()
        status = "Catching up on the last few seconds\u{2026}"
        drawsOn(Set(focus.map { [$0] } ?? []), question: asked.id)
        current = Task {
            // The conversations the answer draws on: deleting one deletes the question and answer too.
            var about = Set(focus.map { [$0] } ?? [])
            defer { status = nil; streaming = nil; tag(from: asked.id, about: about); asking = nil; current = nil }
            // Close the chunk being recorded and transcribe it, so "just now" includes it (30 s at most).
            Recorder.shared.flush()
            let pipeline = pipeline
            let caughtUp = await withDeadline(20, { await pipeline.catchUp() }) != nil
            if Task.isCancelled { return } // Stop
            if !caughtUp {
                Log.error("Catching up took over 20 s; answering from what's transcribed so far")
                add(ChatMessage(fromUser: false, text: Self.stillTranscribing))
            }
            let intent = Prompts.intent(q)
            let now = Date()
            if focus == nil, intent == .digest, Prompts.isAboutToday(q) {
                let today = Calendar.current.startOfDay(for: now)
                let all = (try? container.mainContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.start >= today }, sortBy: [SortDescriptor(\.start)]))) ?? []
                // Read now: one of them may be deleted while the recap's written.
                let ids = all.map(\.id)
                // Nothing yet today: not another day's conversation passed off as today's.
                guard !all.isEmpty else {
                    add(ChatMessage(fromUser: false, text: recording ? "I haven't heard anything today yet. Keep talking and I'll keep track."
                                        : "I haven't heard anything today yet. Turn on listening and I'll keep track."))
                    return
                }
                if Brain.notReadyReason != nil {
                    // Without Apple Intelligence: the day as the Timeline's Your Day shows it. Every
                    // conversation counts, as without it none gets a title (only renamed ones have one).
                    about.formUnion(ids)
                    drawsOn(about, question: asked.id)
                    add(ChatMessage(fromUser: false, text: DayReview.plain(all.map(\.dayNote), time: { $0.formatted(date: .omitted, time: .shortened) })))
                    return
                }
                // The conversation going on (or just ended) has no summary yet: its last words
                // stand in, so "my day so far" doesn't leave out what was only just said.
                let notes = all.compactMap { c -> DayNote? in
                    if let title = c.title, !title.isEmpty { return c.dayNote }
                    let words = Prompts.tail(c.transcript, budget: 120)
                    return words.isEmpty ? nil : DayNote(start: c.start, title: "Not summarised yet", points: [words])
                }
                if !notes.isEmpty {
                    status = "Thinking\u{2026}"
                    // It can wait behind the Timeline's own recaps, and Apple's AI can stall: given
                    // up on after a while, for the usual answer instead.
                    // One written from stand-ins isn't kept: the Timeline's would show it as the day's.
                    let keep = !notes.contains { $0.title == "Not summarised yet" }
                    if let recap = await withDeadline(45, { await DayDigests.shared.recap(for: today, notes: notes, keep: keep) }) {
                        if Task.isCancelled { return }
                        about.formUnion(ids)
                        drawsOn(about, question: asked.id)
                        add(ChatMessage(fromUser: false, text: recap))
                        return
                    }
                    if Task.isCancelled { return }
                }
            }
            // "What did I say I'd do today?": what's still on the list and every to-do noted in
            // today's conversations, not the one conversation that best matches "I'd".
            if focus == nil, intent == .commitments, Self.saysToday.test(Prompts.plain(q)) {
                let today = Calendar.current.startOfDay(for: now)
                let all = (try? container.mainContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.start >= today }, sortBy: [SortDescriptor(\.start)]))) ?? []
                let listed = openItems().filter { $0.type == .todo && !$0.suggested }.map(\.title)
                let onList = Set(listed.map { $0.lowercased() })
                let said = DayReview.gather(all.map(\.dayNote), limit: 99) { $0.todo }.map { $0.text }.filter { !onList.contains($0.lowercased()) }
                func bullets(_ lines: [String]) -> String { lines.map { "\u{2022} \($0)" }.joined(separator: "\n") }
                var parts: [String] = []
                if !listed.isEmpty { parts.append("Still to do:\n" + bullets(listed)) }
                if !said.isEmpty { parts.append("Said today:\n" + bullets(said)) }
                // Without Apple Intelligence nothing's noted, so "nothing you said" wouldn't be
                // known: the usual answer quotes what was said instead.
                let unnoted = parts.isEmpty && Brain.notReadyReason != nil && !all.isEmpty
                if !unnoted {
                    about.formUnion(all.map(\.id))
                    drawsOn(about, question: asked.id)
                    if !parts.isEmpty { add(ChatMessage(fromUser: false, text: parts.joined(separator: "\n\n"))) }
                    // The conversation going on (or just ended) isn't written up yet, so its to-dos
                    // aren't noted: the AI reads its words for them.
                    if Brain.notReadyReason == nil, let last = all.last, (last.title ?? "").isEmpty, !last.transcript.isEmpty {
                        let label = last.start.formatted(date: .omitted, time: .shortened)
                        let notes: [(label: String, title: String?, summary: String?)] = [(label: label, title: nil, summary: nil)]
                        await answer(Prompts.focused(question: q, notes: notes, best: (label: label, transcript: last.transcript), now: now),
                                     hasFallback: !parts.isEmpty)
                        return
                    }
                    if parts.isEmpty {
                        add(ChatMessage(fromUser: false, text: all.isEmpty && !recording ? "I haven't heard anything today yet. Turn on listening and I'll keep track."
                                            : "Nothing on your to-do list, and nothing you said you'd do today."))
                    }
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
                drawsOn(about, question: asked.id)
                // Word for word, straight away; the AI's gist follows.
                // The tip on marking your voice is given once.
                let quoted = QuickRecap.of(latest.transcript, start: latest.start, now: now, tip: !UserDefaults.standard.bool(forKey: "shownVoiceTip"))
                if let quoted {
                    if quoted.contains("That\u{2019}s Me") { UserDefaults.standard.set(true, forKey: "shownVoiceTip") }
                    add(ChatMessage(fromUser: false, text: quoted))
                }
                if let why = Brain.notReadyReason {
                    // Nothing to quote and no AI to say more: never no answer at all.
                    if quoted == nil { add(ChatMessage(fromUser: false, text: why)) }
                    return
                }
                let background = await pipeline.latestBackground()
                await answer(Prompts.latest(question: q, transcript: latest.transcript, topic: latest.title, now: now, background: background, start: latest.start, end: latest.end),
                             hasFallback: quoted != nil)
                return
            }
            // A follow-up ("and when is it?") is looked for with the question it follows, and draws
            // on what that answer did: deleting those conversations deletes it too.
            let found = await pipeline.notes(for: earlier.map { $0.question + " " + q } ?? q, focus: focus)
            if Task.isCancelled { return } // Stop
            about.formUnion(found.used)
            if let earlier { about.formUnion(earlier.about) }
            drawsOn(about, question: asked.id)
            if let why = Brain.notReadyReason {
                // No AI: the sentences of the best match that mention the question's words, word for word.
                let quotes = found.best.map { Prompts.sentences(about: q, in: $0.transcript) } ?? []
                // None of its sentences has the question's words: how it ended, word for word, rather than nothing.
                let ending = found.best.map { Prompts.tail(TranscriptFormat.compact($0.transcript), budget: 150) } ?? ""
                if let best = found.best, !quotes.isEmpty {
                    add(ChatMessage(fromUser: false, text: "From \(best.label):\n" + quotes.map { "\u{201C}\($0)\u{201D}" }.joined(separator: "\n")))
                } else if let best = found.best, !ending.isEmpty {
                    add(ChatMessage(fromUser: false, text: "From \(best.label):\n" + ending))
                } else if found.notes.isEmpty {
                    add(ChatMessage(fromUser: false, text: recording ? "I haven't heard anything yet. Keep talking and I'll keep track." : "I haven't heard anything yet. Turn on listening and I'll keep track."))
                } else {
                    add(ChatMessage(fromUser: false, text: why))
                }
                return
            }
            let previous = earlier?.text ?? ""
            guard !found.notes.isEmpty else {
                add(ChatMessage(fromUser: false, text: recording ? "I haven't heard anything yet. Keep talking and I'll keep track." : "I haven't heard anything yet. Turn on listening and I'll keep track."))
                return
            }
            await answer(Prompts.focused(question: q, notes: found.notes, best: found.best, now: now, background: found.background, earlier: previous),
                         smaller: Prompts.focused(question: q, notes: found.notes, best: found.best, now: now, background: found.background, earlier: previous, budget: 1_800))
        }
    }

    /// The last question and WTF's answer to it, if it was in the last ten minutes: so a follow-up
    /// ("and what did she say?") has something to follow on from. The answer is the last one
    /// given (the AI's, after any word-for-word quote), not the note that catching up took long.
    /// [about]: the conversations they drew on.
    private func earlierExchange() -> (text: String, question: String, about: Set<UUID>)? {
        guard let q = messages.lastIndex(where: \.fromUser), Date().timeIntervalSince(messages[q].date) < 600,
              let a = messages[(q + 1)...].last(where: { !$0.fromUser && !$0.isError && $0.text != Self.stillTranscribing }) else { return nil }
        let question = messages[q].text
        return ("Earlier I asked: \(question)\nYou answered: \(String(a.text.prefix(600)))", question,
                Set(messages[q].about ?? []).union(a.about ?? []))
    }

    /// Whether [question] follows on from the last one (drawn on [about]), rather than asking
    /// something new: it's short, or picks up from it ("and what did she say?", "what about Tom?").
    /// Asked about a conversation ([focus]), only if the last one was about that too.
    private static func follows(_ question: String, on about: Set<UUID>, focus: UUID?) -> Bool {
        if let focus, !about.contains(focus) { return false }
        // Most questions have an "it" or a "that": one only counts with little else to search for.
        let n = Prompts.keywords(question).count
        return n < 2 || followOn.test(question) || (n < 3 && pointsBack.test(question))
    }
    private static let followOn = Rx(#"^\s*(and|but|so|what about|how about)\b"#)
    private static let pointsBack = Rx(#"\b(she|he|her|him|his|they|them|their|it|its|that|those|then|there)\b"#)
    /// A question about what you said you'd do that's about today only (see ask).
    private static let saysToday = Rx(#"\btoday\b"#)

    /// Said when catching up on the last few seconds takes too long (not an answer to follow on from).
    private static let stillTranscribing = "The last few seconds are still being transcribed, so this may miss them."

    /// The question being worked out, for Stop.
    @ObservationIgnored private var current: Task<Void, Never>?

    /// Stop in Ask: the answer being worked out is given up on (what's been written of it stays).
    func stopAsking() {
        current?.cancel()
    }

    /// Settings › People › Forget: deleted where the People list's copies are (deleting it from the
    /// pipeline's own context while the list showed it could crash).
    func forgetPerson(_ person: Person) {
        let name = person.voice.label
        container.mainContext.delete(person)
        try? container.mainContext.save()
        // Their voice in the conversations goes too, so it isn't matched again from there.
        let pipeline = pipeline
        Task { await pipeline.forgetVoice(named: name) }
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
        // The card may have been ended by iOS (after about 8 hours) or swiped away: back it comes.
        ListeningActivity.shared.restoreIfNeeded()
        if ListeningActivity.shared.showing {
            ListeningActivity.shared.showAnswer(answer)
            cardAnswerAt = Date()
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
        let about = await pipeline.latestConversation().map { [$0.id] }
        addFromButton(ChatMessage(fromUser: true, text: stepped ? "What came before that?" : Self.quickQuestion, about: about),
                      ChatMessage(fromUser: false, text: answer, about: about))
        // Waits only until it's started playing: the sound keeps the app awake to the end.
        let played = await ReadAloud.shared.readIntoHeadphones(answer)
        // Pressing again "within 20 seconds" counts from the end of the reading, not its start.
        lastPress = Date().addingTimeInterval(played ?? 0)
        Log.info("Action button: answered in \(String(format: "%.1f", Date().timeIntervalSince(pressed))) s, \(played != nil ? "reading it out" : "shown only")")
        return answer
    }

    /// "What came before that?" on its own (from the WTF Menu): the next step back each time.
    func beforeThatFromShortcut() async -> String {
        buttonPressedAt = Date()
        // The card keeps an answer and its Before That button up for a minute and a half: pressed
        // while it's still there, it goes on from that answer rather than starting over.
        let onCard = Date().timeIntervalSince(cardAnswerAt) < 90
        if backstory.isEmpty || Date().timeIntervalSince(lastPress) >= (onCard ? 90 : 20) {
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
        let about = await pipeline.latestConversation().map { [$0.id] }
        addFromButton(ChatMessage(fromUser: true, text: "What came before that?", about: about),
                      ChatMessage(fromUser: false, text: answer, about: about))
        let played = await ReadAloud.shared.readIntoHeadphones(answer)
        lastPress = Date().addingTimeInterval(played ?? 0)
        return answer
    }

    /// A button's question and answer, kept in Ask: before a question still being answered there,
    /// so that one's answer still follows it (and isn't taken for the button's).
    private func addFromButton(_ question: ChatMessage, _ answer: ChatMessage) {
        // Added as they are: add() would drop the answer while a question that's since been
        // deleted is still being answered.
        guard let asking, let at = messages.firstIndex(where: { $0.id == asking.question }) else {
            messages.append(contentsOf: [question, answer])
            ChatLog.save(messages)
            return
        }
        messages.insert(contentsOf: [question, answer], at: at)
        ChatLog.save(messages)
    }

    /// Where pressing again goes: the topics before what you were just saying, and how far it's got.
    private var backstory: [String] = []
    private var step = 0
    private var lastPress = Date.distantPast
    /// When an answer last went on the card (it stays there 90 seconds).
    private var cardAnswerAt = Date.distantPast

    /// Listening on or off, from a control or a Shortcut, without opening the app.
    func toggleListeningFromShortcut(forward: ComeForward? = nil, recordingIntent: Bool = false) async -> String {
        buttonPressedAt = Date()
        // A press while a start's under way (the speech model downloading, say) is a change of
        // mind: it stops, rather than joining the start.
        if recording || isStarting {
            setListening(false)
            return "WTF has stopped listening."
        }
        return await startListeningFromShortcut(forward: forward, recordingIntent: recordingIntent) ? "WTF is listening." : (problem ?? "Couldn't start listening.")
    }

    /// Your list, read out (or shown): what's coming up, what to do, what to buy.
    func listFromShortcut() async -> String {
        buttonPressedAt = Date()
        let all = openItems()
        let open = all.filter { !$0.suggested }
        var parts: [String] = []
        let now = Date()
        let events = open.filter { $0.type == .event && ($0.start ?? .distantFuture) >= now.addingTimeInterval(-3600) }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }.prefix(3)
        if !events.isEmpty {
            parts.append("Coming up: " + events.map { e in
                e.title + (e.start.map { " " + (Self.dayWord($0) + (e.allDay ? "" : " at " + $0.formatted(date: .omitted, time: .shortened))) } ?? "")
            }.joined(separator: ", ") + ".")
        }
        let todos = open.filter { $0.type == .todo }.prefix(5).map(\.title)
        if !todos.isEmpty { parts.append("To do: " + todos.joined(separator: ", ") + ".") }
        let buy = open.filter { $0.type == .buy }.prefix(8).map(\.title)
        if !buy.isEmpty { parts.append("To buy: " + buy.joined(separator: ", ") + ".") }
        // Heard but not added: said last, so it isn't missed.
        let heard = all.filter(\.suggested).prefix(5).map(\.title)
        if !heard.isEmpty { parts.append("Heard, not added yet: " + heard.joined(separator: ", ") + ".") }
        let answer = parts.isEmpty ? "Your list's empty." : parts.joined(separator: " ")
        // In Ask too, as the card cuts it short and tapping the card opens Ask.
        addFromButton(ChatMessage(fromUser: true, text: "What's on my list?"), ChatMessage(fromUser: false, text: answer))
        _ = await ReadAloud.shared.startIntoHeadphones(answer)
        return answer
    }

    /// When an event is, read out: today and tomorrow said as such, so a weekday means this week.
    private static func dayWord(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInTomorrow(date) { return "tomorrow" }
        return date.timeIntervalSinceNow < 6 * 86_400 ? date.formatted(.dateTime.weekday(.wide)) : date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// The answer to "what was I saying?", short enough to be read out in your ear, from what's
    /// been transcribed so far plus [live] (words heard in the last few seconds, not yet sorted
    /// by speaker). Nil if nothing's been heard. [ai]: seconds to give Apple Intelligence (0: none).
    func workOutRecap(live: String, ai: Double) async -> (text: String, covers: Date, byAI: Bool)? {
        let now = Date()
        var latest = await pipeline.latestConversation()
        if !live.isEmpty, let ended = latest?.end {
            // The words just heard begin a new conversation if the last one's been quiet for longer
            // than starts one (this morning's first words, say): not told as part of yesterday's.
            let gap = UserDefaults.standard.integer(forKey: "gapMinutes")
            if now.timeIntervalSince(ended) > Double(max(1, gap == 0 ? 5 : gap)) * 60 { latest = nil }
        }
        var transcript = latest?.transcript ?? ""
        if !live.isEmpty {
            let line = TranscriptFormat.lines([Utterance(start: now, speaker: Labels.anonymous, text: live)])
            transcript += (transcript.isEmpty ? "" : "\n") + line
        }
        guard !transcript.isEmpty else { return nil }
        let start = latest?.start ?? now
        let covers = latest?.end ?? .distantPast
        if ai > 0, Brain.notReadyReason == nil {
            // The topics are the last conversation's: nothing to say about words that start a new one.
            var threads: [TopicThread] = []
            if latest != nil { threads = await pipeline.latestThreads() }
            let hanging = Threads.hanging(threads).first.map { "\($0.title): \($0.leftAt ?? "")" }
            let topic = threads.last(where: { $0.status == .current })?.title ?? latest?.title
            // Notes are the last conversation's too: not passed off as this one's.
            var background = ""
            if latest != nil { background = await pipeline.latestBackground() }
            if let gist = await Brain.quick(Prompts.spoken(transcript: transcript, topic: topic, leftAt: hanging, now: now, background: background, start: latest?.start, end: latest?.end), seconds: ai)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !gist.isEmpty {
                return (gist, covers, true)
            }
        }
        // The words just heard have no voice yet, so with yours known the recap would pass over
        // them for an older line of yours; yet they're most likely what was lost. Said as they are.
        let heard = live.split(separator: " ")
        if heard.count >= 4 {
            return ("The last thing said, just now, was: " + (heard.count > 30 ? "\u{2026}" : "") + heard.suffix(30).joined(separator: " "), covers, false)
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
        drawsOn([conversation], question: asked.id)
        current = Task {
            defer { status = nil; streaming = nil; asking = nil; current = nil }
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

    /// [smaller]: the same with less of what was heard in it, tried if [prompt] doesn't fit in
    /// Apple Intelligence's context (the token count is only an estimate). [hasFallback]: an
    /// answer's already been given (word for word), so if the AI adds nothing, nothing more is said.
    private func answer(_ prompt: String, smaller: String? = nil, hasFallback: Bool = false) async {
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
        // Stop in Ask stops the writing too.
        let (text, failure) = await withTaskCancellationHandler { await writing.value } onCancel: { writing.cancel() }
        limit.cancel()
        streaming = nil
        let stopped = Task.isCancelled
        if let failure, !stopped { Log.error("Apple Intelligence couldn't answer", failure) }
        if let failure, let smaller, text.isEmpty, !stopped, Brain.isTooLong(failure) {
            Log.info("The question's notes were too long for Apple Intelligence; trying again with less")
            await answer(smaller, hasFallback: hasFallback)
            return
        }
        guard failure != nil || writing.isCancelled else {
            if !text.isEmpty {
                add(ChatMessage(fromUser: false, text: text))
            } else if !hasFallback {
                add(ChatMessage(fromUser: false, text: "I couldn\u{2019}t find an answer to that in what I heard."))
            }
            return
        }
        // Cut short: what was written so far stays, marked unfinished rather than passed off as
        // a whole answer, and with no second note under it.
        if !text.isEmpty {
            add(ChatMessage(fromUser: false, text: text + "\u{2026}", isError: true))
        } else if !stopped, !hasFallback {
            add(ChatMessage(fromUser: false, text: writing.isCancelled ? "Apple Intelligence took too long to answer. Try again in a moment."
                                : Brain.why(failure), isError: true))
        }
    }

    /// What's on the list, and what was heard for it but not added yet (said as such).
    private func openItems() -> [ListAnswers.Item] {
        let items = (try? container.mainContext.fetch(FetchDescriptor<ActionItem>(predicate: #Predicate { $0.status == "accepted" || $0.status == "suggested" }))) ?? []
        return items.map { ListAnswers.Item(type: ActionType(rawValue: $0.type) ?? .todo, title: $0.title, start: $0.start, allDay: $0.allDay, place: $0.place,
                                            suggested: $0.status == "suggested") }
    }
}

/// A little more time to finish something once WTF's in the background (iOS gives about 30 seconds).
@MainActor
private final class ExtraTime {
    private var task = UIBackgroundTaskIdentifier.invalid

    init(_ name: String) {
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Out of time: let go, or iOS closes WTF.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

enum AVPermissions {
    static func microphone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}

/// Shows the answer to a button pressed while WTF is in front (a control from Control Center),
/// which iOS otherwise drops; every other notice keeps to iOS's usual (not shown in front).
private final class AnswerNotices: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier == "wtf.answer" ? [.banner, .list, .sound] : []
    }
}

/// When the recordings that have had speech in them began, until they're dropped as noise: so a
/// delete can tell talk that's started again, not yet transcribed, from silence. Fed from the audio thread.
private final class SpeechHeard: @unchecked Sendable {
    static let shared = SpeechHeard()
    private let lock = NSLock()
    private var heard: [Date] = []

    func add(_ chunk: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard heard.last != chunk else { return }
        heard.append(chunk)
        if heard.count > 32 { heard.removeFirst(heard.count - 32) }
    }

    func drop(_ chunk: Date) {
        lock.lock()
        defer { lock.unlock() }
        heard.removeAll { $0 == chunk }
    }

    func starts() -> [Date] {
        lock.lock()
        defer { lock.unlock() }
        return heard
    }
}
