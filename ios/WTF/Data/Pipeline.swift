import AVFoundation
import Foundation
import SwiftData
import UserNotifications
import WTFCore

/// Turns recorded chunks into transcripts, groups them into conversations, suggests list items
/// as soon as they're heard, and summarises conversations once they've gone quiet. Runs off
/// the main thread with its own SwiftData context.
@ModelActor
actor Pipeline {
    private var gapMinutes: Int { max(1, UserDefaults.standard.integer(forKey: "gapMinutes").nonZero ?? 5) }
    private var keepDays: Int { UserDefaults.standard.integer(forKey: "keepDays").nonZero ?? 7 }

    /// Work runs in three queues, each one job at a time and in order: transcribing (what a question
    /// waits for), the topic trail of what's just been said, and the slower AI work after it
    /// (summaries), so a question never waits behind a summary, the trail never waits behind a
    /// long conversation being heard again, and nothing is done twice.
    private var transcribing: Task<Bool, Never>?
    private var following: Task<Void, Never>?
    private var thinking: Task<Void, Never>?
    /// New lines whose topic hasn't been worked out yet (it waits until after any question's answered).
    /// Each with the words the recogniser doubted and the ones it was sure of, for fixing misheard words.
    private var toFollow: [(id: UUID, text: String, from: Date, to: Date, doubts: [Doubt], protected: Set<String>)] = []

    /// The conversation going on was deleted: what's still being recorded or waiting to be
    /// transcribed would have joined it, so it goes too, rather than coming back as a new one.
    func cutOff() {
        // The transcribing going on holds chunks fetched before these deletes: it stops (see wiped).
        wiped += 1
        wipedAt = Date()
        toFollow = []
        // Nor are its words kept to answer from (the Action button reads the last few seconds).
        LiveTranscriber.shared.forget()
        // A retry from an earlier conversation, still waiting (see transcribePending), is kept:
        // only what could have joined this one goes (drop(spans:) sees to its own retries).
        let since = (latestConversation()?.start ?? .distantPast).addingTimeInterval(-Double(gapMinutes * 60))
        for chunk in (try? modelContext.fetch(FetchDescriptor<Chunk>(predicate: #Predicate { $0.status == "pending" }))) ?? [] {
            guard chunk.attempts == 0 || chunk.end >= since else { continue }
            if let path = chunk.path { try? FileManager.default.removeItem(atPath: path) }
            modelContext.delete(chunk)
        }
        try? modelContext.save()
    }

    /// Bumped by Delete Everything and cutOff: work that was waiting on something checks it hasn't happened meanwhile.
    private var wiped = 0
    /// When everything was last deleted: a recording that started before then, finished after, goes too.
    /// Kept across launches: one WTF was ended part-way through is taken in when it next runs
    /// (sweepAudio), and what was deleted mustn't come back then.
    private var wipedAt: Date {
        get { UserDefaults.standard.object(forKey: "wipedAt") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "wipedAt") }
    }
    /// Conversations deleted in the app: AI work already under way for one finds it gone, rather
    /// than suggesting list items from it as it goes.
    private var forgotten = Set<UUID>()

    /// A conversation, fetched afresh by its id: one held across a wait may have been deleted meanwhile.
    private func conversation(_ id: UUID) -> Conversation? {
        guard !forgotten.contains(id) else { return nil }
        return (try? modelContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })))?.first
    }

    func addChunk(url: URL, start: Date, end: Date) {
        guard start >= wipedAt else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        // Already taken in as one WTF was ended part-way through (see sweepAudio): not twice.
        let path: String? = url.path
        if let known = (try? modelContext.fetch(FetchDescriptor<Chunk>(predicate: #Predicate { $0.path == path })))?.first {
            known.end = max(known.end, end)
            try? modelContext.save()
            return
        }
        modelContext.insert(Chunk(start: start, end: end, path: url.path))
        try? modelContext.save()
    }

    /// A chunk deleted while its transcription was waiting on something (see cutOff).
    private func gone(_ chunk: Chunk) -> Bool { chunk.isDeleted || chunk.modelContext == nil }

    /// Transcribes what's waiting, so a question includes the latest words. Summaries can wait.
    /// [force]: asked for (Transcribe Now, pull to refresh), so one that failed is tried now too,
    /// rather than the button doing nothing while it waits.
    @discardableResult
    func catchUp(force: Bool = false) async -> Bool {
        let before = transcribing
        let job = Task { _ = await before?.value; return await self.transcribePending(force: force) }
        transcribing = job
        return await job.value
    }

    /// When each recording that failed was last tried (by its file), so it's tried again after a
    /// while, longer each time, not on every recording ahead of what's just been said.
    private var lastTried: [String: Date] = [:]

    private func transcribePending(force: Bool = false) async -> Bool {
        let now = Date()
        let all = (try? modelContext.fetch(FetchDescriptor<Chunk>(
            predicate: #Predicate { $0.status == "pending" }, sortBy: [SortDescriptor(\.start)]))) ?? []
        // New ones first; one that failed waits its turn after them.
        let pending = all.filter { $0.attempts == 0 } + all.filter { chunk in
            guard chunk.attempts > 0 else { return false }
            guard !force, let path = chunk.path, let tried = lastTried[path] else { return true }
            return now > tried.addingTimeInterval(60 * pow(2, Double(chunk.attempts)))
        }
        guard !pending.isEmpty, await SpeechEngine.shared.isReady() else { return pending.count == all.count }
        let generation = wiped
        defer { Task { @MainActor in AppModel.shared.transcribing = nil } }
        var ok = true
        for (i, chunk) in pending.enumerated() {
            await MainActor.run { AppModel.shared.transcribing = (i, pending.count) }
            guard wiped == generation else { return false }
            if gone(chunk) { continue }
            guard let path = chunk.path, FileManager.default.fileExists(atPath: path) else {
                chunk.status = "failed"
                continue
            }
            do {
                // The words and the voices at the same time: Apple's recogniser and the speaker models.
                // Every step has a deadline, so one stuck recording can't hold up the rest.
                let url = URL(fileURLWithPath: path)
                let length = max(1, chunk.end.timeIntervalSince(chunk.start))
                let started = Date()
                // A song on the radio or the TV isn't conversation: not transcribed, so no lyrics.
                var isSong = false
                if length >= 6 { isSong = await withDeadline(5 + length / 4, { await MusicCheck.isSong(url) }) == true }
                guard wiped == generation else { return false }
                if gone(chunk) { continue }
                // The times copied first: the chunk itself belongs to this actor, not the closures.
                let (from, to) = (chunk.start, chunk.end)
                if isSong {
                    Log.info("Recording \(chunk.start.formatted(date: .omitted, time: .standard)) (\(Int(length)) s) was music, so it wasn't transcribed")
                    _ = await withDeadline(4) { await LiveTranscriber.shared.words(from: from, to: to) }
                    guard wiped == generation else { return false }
                    if gone(chunk) { continue }
                    chunk.status = "music"
                    chunk.path = nil
                    try? FileManager.default.removeItem(atPath: path)
                    try? modelContext.save()
                    continue
                }
                async let heardVoices = withDeadline(60 + length) { await VoiceEngine.shared.split(url) }
                // Usually the words were heard live already; if not, from the file.
                var words = await withDeadline(4) { await LiveTranscriber.shared.words(from: from, to: to) }
                let live = words != nil
                if words == nil {
                    words = await withDeadline(20 + 2 * length) { () -> [SpeakerAlign.Word]? in
                        do { return try await SpeechEngine.shared.words(url) } catch {
                            Log.error("Speech recognition failed on the recording", error)
                            return nil
                        }
                    }
                }
                let split = await heardVoices
                guard wiped == generation else { return false }
                // Deleted meanwhile (the conversation it was part of was deleted): nothing to write to.
                if gone(chunk) { continue }
                guard let words else { throw StepTimedOut(what: "transcribing \(Int(length)) s of audio") }
                Log.info("Recording \(chunk.start.formatted(date: .omitted, time: .standard)) (\(Int(length)) s): \(words.count) words \(live ? "live" : "from the file") (\(Doubts.summary(words))), \(split?.voices.count ?? 0) voices, \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                let target = openConversation(for: chunk)
                var voices = target?.voiceprints ?? []
                let utterances = whoSaidWhat(words, split: split, voices: &voices, before: target?.transcript, start: chunk.start)
                let text = TranscriptFormat.lines(utterances)
                var keepAudio = false
                if text.isEmpty {
                    chunk.status = "empty"
                } else {
                    let c = attach(chunk, text: text, to: target)
                    if split != nil { c.voiceprints = voices }
                    chunk.status = "done"
                    chunk.conversationID = c.id
                    let cid = c.id
                    // The audio's kept until its conversation is over, to be heard again as a whole
                    // (secondPass), unless it's grown too long for that: then none of it is kept.
                    keepAudio = Self.hearAgain && c.end.timeIntervalSince(c.start) <= Self.hearAgainLimit
                    if !keepAudio { forgetAudio(of: cid) }
                    try? modelContext.save()
                    toFollow.append((cid, text, chunk.start, chunk.end, Doubts.of(words), Doubts.protected(words)))
                    await suggest(for: c, found: instantActions(c, new: text))
                    guard wiped == generation else { return false }
                    // Deleted in the app meanwhile, with its chunks: gone() can't see that from here.
                    guard conversation(cid) != nil else { continue }
                }
                if !keepAudio {
                    chunk.path = nil
                    try? FileManager.default.removeItem(atPath: path)
                }
            } catch {
                guard wiped == generation else { return false }
                if gone(chunk) { continue }
                Log.error("Couldn't transcribe the recording from \(chunk.start.formatted(date: .omitted, time: .standard)) (try \(chunk.attempts + 1) of 5)", error)
                chunk.attempts += 1
                lastTried[path] = Date()
                if chunk.attempts >= 5 {
                    chunk.status = "failed"
                    chunk.path = nil
                    try? FileManager.default.removeItem(atPath: path)
                }
                ok = false
            }
            try? modelContext.save()
        }
        return ok && pending.count == all.count
    }

    /// Catch up and follow the topic, then (in the background, without waiting) summarise
    /// conversations that have gone quiet and tidy away old ones. [force]: see catchUp.
    func run(force: Bool = false) async {
        await refreshVocabulary()
        await catchUp(force: force)
        let trail = following
        let follow = Task { await trail?.value; await self.followThreads() }
        following = follow
        // A summary waits for its conversation's last lines to be followed, so it has them.
        let before = thinking
        thinking = Task { await before?.value; await follow.value; await self.think() }
        await follow.value
    }

    /// The slow part: summaries of finished conversations, and tidying up.
    private func think() async {
        let generation = wiped
        sweepAudio()
        let quietBefore = Date().addingTimeInterval(-Double(gapMinutes) * 60)
        // One whose summary just failed is tried again in a while, not on the very next recording.
        let retryBefore = Date().addingTimeInterval(-600)
        // Only the ones wanted are fetched, not every one kept: this is done on every recording.
        var over: [Conversation]
        if Brain.notReadyReason == nil {
            over = (try? modelContext.fetch(FetchDescriptor<Conversation>(
                predicate: #Predicate { $0.summary == nil && ($0.closed || $0.end < quietBefore) }))) ?? []
        } else {
            // Without Apple Intelligence no summary can be written: only ones still to close, or
            // with audio to hear again, are worth a look.
            over = (try? modelContext.fetch(FetchDescriptor<Conversation>(
                predicate: #Predicate { $0.summary == nil && !$0.closed && $0.end < quietBefore }))) ?? []
            let withAudio = Set(((try? modelContext.fetch(FetchDescriptor<Chunk>(
                predicate: #Predicate { $0.status == "done" && $0.path != nil }))) ?? []).compactMap(\.conversationID))
            over += withAudio.compactMap { conversation($0) }.filter { $0.summary == nil && $0.closed }
        }
        over = over.filter { ($0.summaryTriedAt ?? .distantPast) < retryBefore }
        let waiting = over.map(\.id)
        for id in waiting {
            guard wiped == generation else { return }
            await summarise(id)
        }
        guard wiped == generation else { return }
        // Summarised, but WTF was closed before its facts and list items were looked for.
        if Brain.notReadyReason == nil {
            let no: Bool? = false
            let unfinished = ((try? modelContext.fetch(FetchDescriptor<Conversation>(
                predicate: #Predicate { $0.summary != nil && $0.extracted == no }))) ?? []).map(\.id)
            for id in unfinished {
                guard wiped == generation else { return }
                await extract(id)
            }
        }
        guard wiped == generation else { return }
        // Old recordings' records go here: once their audio's gone a day after, or at the latest
        // with their conversations. Not ones waiting (the Timeline shows those). Old conversations
        // and list items go in the app (AppModel.expireOld), where the screens' copies are, so
        // none is left pointing at one that's gone.
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        let dayAgo = Date().addingTimeInterval(-86_400)
        try? modelContext.delete(model: Chunk.self, where: #Predicate {
            $0.status != "pending" && ($0.end < cutoff || ($0.path == nil && $0.end < dayAgo))
        })
        try? modelContext.save()
    }

    /// Audio that's no longer needed goes: anything kept for a second hearing for more than a
    /// day, a whole-conversation file left by a second hearing that was cut short, and
    /// recordings nothing refers to any more.
    private func sweepAudio() {
        // The store didn't open (AppModel uses a stand-in): the recordings on disk belong to the
        // real one, left alone for next time, not swept as if nothing referred to them.
        guard !modelContainer.configurations.contains(where: { $0.isStoredInMemoryOnly }) else { return }
        let fm = FileManager.default
        let dayAgo = Date().addingTimeInterval(-86_400)
        for chunk in (try? modelContext.fetch(FetchDescriptor<Chunk>(predicate: #Predicate { $0.status == "done" && $0.path != nil && $0.end < dayAgo }))) ?? [] {
            if let path = chunk.path { try? fm.removeItem(atPath: path) }
            chunk.path = nil
        }
        try? modelContext.save()
        let referenced = Set(((try? modelContext.fetch(FetchDescriptor<Chunk>(predicate: #Predicate { $0.path != nil }))) ?? []).compactMap(\.path))
        let dir = Recorder.audioDirectory
        let tenMinutesAgo = Date().addingTimeInterval(-600)
        let keptFrom = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let path = dir.appendingPathComponent(name).path
            let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
            // A recording still being made isn't in the database yet: only ones well finished go.
            guard name.hasPrefix("whole_") || (!referenced.contains(path) && modified < tenMinutesAgo) else { continue }
            // WTF was ended (by iOS, say) while this was being recorded: what was said is still
            // transcribed, rather than lost. Its name is when it began.
            if name.hasPrefix("chunk_"), name.hasSuffix(".wav"), let ms = Double(name.dropFirst(6).dropLast(4)) {
                let start = Date(timeIntervalSince1970: ms / 1000)
                let url = URL(fileURLWithPath: path)
                if start > keptFrom, let seconds = Self.mend(url), seconds >= 1.5 {
                    Log.info("Found \(Int(seconds)) s recorded at \(start.formatted(date: .omitted, time: .standard)) when WTF was ended: it'll be transcribed")
                    addChunk(url: url, start: start, end: start.addingTimeInterval(seconds))
                    continue
                }
            }
            try? fm.removeItem(atPath: path)
        }
    }

    /// Deletes the audio kept for a conversation.
    private func forgetAudio(of id: UUID) {
        let cid: UUID? = id
        for chunk in (try? modelContext.fetch(FetchDescriptor<Chunk>(predicate: #Predicate { $0.conversationID == cid && $0.path != nil }))) ?? [] {
            if let path = chunk.path { try? FileManager.default.removeItem(atPath: path) }
            chunk.path = nil
        }
        try? modelContext.save()
    }

    func latestConversation() -> (id: UUID, transcript: String, start: Date, end: Date, title: String?)? {
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.end, order: .reverse)])
        d.fetchLimit = 1
        return (try? modelContext.fetch(d))?.first.map { ($0.id, $0.transcript, $0.start, $0.end, $0.title) }
    }

    func conversationCount() -> Int { (try? modelContext.fetchCount(FetchDescriptor<Conversation>())) ?? 0 }

    /// Counts for the diagnostics report (no content).
    func health() -> String {
        func count<T: PersistentModel>(_ d: FetchDescriptor<T>) -> Int { (try? modelContext.fetchCount(d)) ?? -1 }
        let pending = count(FetchDescriptor<Chunk>(predicate: #Predicate { $0.status == "pending" }))
        let failed = count(FetchDescriptor<Chunk>(predicate: #Predicate { $0.status == "failed" }))
        let conversations = count(FetchDescriptor<Conversation>())
        let people = count(FetchDescriptor<Person>())
        let items = count(FetchDescriptor<ActionItem>())
        return "Recordings waiting: \(pending), failed: \(failed)\nConversations: \(conversations)\nPeople: \(people)\nList items: \(items)"
    }

    /// Listening's paused: the conversation going on is over.
    func closeLatest() {
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.end, order: .reverse)])
        d.fetchLimit = 1
        guard let c = (try? modelContext.fetch(d))?.first, !c.closed else { return }
        c.closed = true
        try? modelContext.save()
    }

    func latestThreads() -> [TopicThread] {
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.end, order: .reverse)])
        d.fetchLimit = 1
        return (try? modelContext.fetch(d))?.first?.threads ?? []
    }

    /// The transcript lines said while [thread] was the topic.
    func lines(of thread: TopicThread, in id: UUID) -> String {
        guard let c = (try? modelContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })))?.first else { return "" }
        // A line covers everything until the next one starts, so a topic that began part-way
        // through a long line includes that line. By date, not time of day: a topic can run past midnight.
        let lines = c.transcript.split(separator: "\n")
        let starts = TranscriptFormat.times(of: lines, from: c.start)
        let from = thread.start, to = thread.end.addingTimeInterval(1)
        var kept: [Substring] = []
        for (i, line) in lines.enumerated() {
            guard let t = starts[i] else { continue }
            let next = starts[(i + 1)...].compactMap { $0 }.first ?? .distantFuture
            if t < to && next > from { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    /// What the AI needs for any other question: the day's notes, the conversation that best
    /// matches it (by meaning as well as words), the parts of it that matter most, and what's
    /// known that bears on it.
    func notes(for question: String, focus: UUID?) -> (notes: [(label: String, title: String?, summary: String?)], best: (label: String, transcript: String)?, background: String, used: [UUID]) {
        // Only the ones it could use: whole transcripts are large, and there can be months of them.
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.start, order: .reverse)])
        if let id = focus { d.predicate = #Predicate<Conversation> { $0.id == id } } else { d.fetchLimit = 40 }
        let pool = (try? modelContext.fetch(d)) ?? []
        let keys = Prompts.keywords(question)
        let asked = Meaning.vector(question)
        func rank(_ c: Conversation) -> Double {
            var meaning = 0.0
            if let asked, let v = Meaning.vector([c.title, c.summary, c.memory.text()].compactMap { $0 }.joined(separator: ". ")) {
                meaning = Meaning.similarity(asked, v)
            }
            return meaning * 10 + min(score(c, keys), 15)
        }
        // Nothing to go on ("WTF?"): the newest conversation (the pool is newest first), not an
        // older one that happens to win on meaning.
        let best = keys.isEmpty && focus == nil ? pool.first : pool.map { ($0, rank($0)) }.max { $0.1 < $1.1 }?.0
        let notes = pool.prefix(12).map { (label: label($0), title: $0.title, summary: $0.summary) }
        var used = focus.map { [$0] } ?? []
        guard let best else { return (notes, nil, "", used) }
        if !used.contains(best.id) { used.append(best.id) }
        // A long conversation: the lines that bear on the question (and the ones either side), not just its end.
        var transcript = best.transcript
        if Prompts.tokens(TranscriptFormat.compact(transcript)) > 1_300 {
            let lines = transcript.split(separator: "\n").map(String.init)
            // By meaning for up to 400 lines (the newest), by words for the rest: answers stay quick.
            let byMeaning = max(0, lines.count - 400)
            let scores = lines.enumerated().map { i, line -> Double in
                let text = Corrections.text(of: line)
                let meaning = i < byMeaning ? 0 : asked.flatMap { a in Meaning.vector(text).map { Meaning.similarity(a, $0) } } ?? 0
                return meaning + Retrieval.wordScore(question, text)
            }
            let excerpt = Retrieval.excerpt(lines, scores: scores, budget: 1_200)
            if !excerpt.isEmpty { transcript = excerpt + "\n" + Prompts.tail(transcript, budget: 150) }
        }
        let background = Prompts.background(memory: best.memory, facts: relevantFacts(to: question, limit: 5))
        return (notes, (label(best), transcript), background, used)
    }

    /// A conversation about to be deleted (by the app, where the screens' copies are): nothing
    /// more is done with it, and its audio goes.
    func forget(_ id: UUID) {
        forgotten.insert(id)
        unremembered[id] = nil
        // What it was heard to say isn't left on the Lock Screen.
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.heardNotice(id)])
        toFollow.removeAll { $0.id == id }
        let optional: UUID? = id
        for chunk in (try? modelContext.fetch(FetchDescriptor<Chunk>(predicate: #Predicate { $0.conversationID == optional }))) ?? [] {
            if let path = chunk.path { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    /// Conversations deleted (by the app): recordings from their time still waiting to be
    /// transcribed (a retry) go too, rather than coming back later as a new conversation.
    /// One made after it ends goes only if it's a retry: one not tried yet may be the start of the
    /// next conversation (listening paused and started again), and that's kept.
    func drop(spans: [(start: Date, end: Date)]) {
        guard !spans.isEmpty else { return }
        let gap = Double(gapMinutes * 60)
        let waiting = (try? modelContext.fetch(FetchDescriptor<Chunk>(predicate: #Predicate { $0.status == "pending" && $0.conversationID == nil }))) ?? []
        for chunk in waiting where spans.contains(where: {
            chunk.start >= $0.start.addingTimeInterval(-gap)
                && (chunk.start <= $0.end || (chunk.attempts > 0 && chunk.start <= $0.end.addingTimeInterval(gap)))
        }) {
            if let path = chunk.path { try? FileManager.default.removeItem(atPath: path) }
            modelContext.delete(chunk)
        }
        try? modelContext.save()
    }

    /// Once: what earlier versions got wrong, put right. The "[1]" a correction left at the start
    /// of some lines, and list suggestions that weren't: someone being picked up filed as
    /// shopping, today's plans with no time as calendar items, "not booked yet" on things nobody
    /// books, and tasks nobody said. (What you've already added to a list is left alone.)
    func repairOnce() {
        let key = "repaired.lists.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        defer { UserDefaults.standard.set(true, forKey: key) }
        let conversations = (try? modelContext.fetch(FetchDescriptor<Conversation>())) ?? []
        var lines: [UUID: [String]] = [:]
        for c in conversations {
            let fixed = Corrections.repaired(c.transcript)
            if fixed != c.transcript { c.transcript = fixed }
            lines[c.id] = ActionRules.candidateLines(fixed)
        }
        let suggested = (try? modelContext.fetch(FetchDescriptor<ActionItem>(predicate: #Predicate { $0.status == "suggested" }))) ?? []
        var removed = 0
        for item in suggested {
            if let q = item.quote { item.quote = Rx(#"^\s*\[\s*\d+\s*\]\s*"#).replace(q, with: "") }
            let said = item.conversationID.flatMap { lines[$0] } ?? []
            var wrong = false
            switch item.type {
            case ActionType.buy.rawValue:
                wrong = ActionRules.isCollecting(item.title, in: [item.quote ?? ""] + said)
            case ActionType.todo.rawValue:
                wrong = !said.isEmpty && !ActionRules.grounded(item.title, in: said)
            case ActionType.event.rawValue:
                if let start = item.start, item.allDay, Calendar.current.isDate(start, inSameDayAs: item.heardAt ?? item.created) { wrong = true }
                if item.note == "Not booked yet", !ActionRules.isBookable(item.title + " " + (item.quote ?? "")) { item.note = nil }
            default:
                break
            }
            if wrong {
                modelContext.delete(item)
                removed += 1
            }
        }
        try? modelContext.save()
        if removed > 0 { Log.info("Took \(removed) wrong suggestion\(removed == 1 ? "" : "s") off the lists") }
    }

    func deleteEverything() {
        wiped += 1
        wipedAt = Date()
        toFollow = []
        LiveTranscriber.shared.forget()
        unremembered = [:]
        forgotten = []
        try? modelContext.delete(model: Fact.self)
        Learned.forget()
        DeclinedNames.forget()
        try? modelContext.delete(model: Conversation.self)
        try? modelContext.delete(model: Chunk.self)
        try? modelContext.delete(model: ActionItem.self)
        try? modelContext.delete(model: Person.self)
        try? modelContext.save()
        try? FileManager.default.removeItem(at: Recorder.audioDirectory)
    }

    // MARK: - Memory

    /// Lines not yet in their conversation's notes.
    private var unremembered: [UUID: String] = [:]

    /// Brings a conversation's notes up to date once enough new talk has built up (or [force]:
    /// it's over), so recaps, lists and answers see the whole of it.
    private func remember(_ id: UUID, force: Bool = false) async {
        guard Brain.notReadyReason == nil, let new = unremembered[id], !new.isEmpty else { return }
        // About a minute of talk at a time: often enough to keep up, rarely enough to spare the battery.
        guard force || new.split(whereSeparator: \.isWhitespace).count >= 120 else { return }
        guard let before = conversation(id) else { unremembered[id] = nil; return }
        let prompt = Prompts.memory(before.memory, new: new)
        unremembered[id] = nil
        guard let notes = await withDeadline(40, { await Log.attempt("Conversation notes", { try await Brain.remember(prompt) }) }) else {
            // Not lost: tried again with the next lot (iOS limits how much AI an app does in the background).
            unremembered[id] = String([new, unremembered[id]].compactMap { $0 }.joined(separator: "\n").suffix(6_000))
            return
        }
        guard let c = conversation(id) else { return }
        c.memory = notes
        try? modelContext.save()
    }

    /// Facts known from other days that bear on [text].
    private func relevantFacts(to text: String, limit: Int = 5) -> [String] {
        let facts = (try? modelContext.fetch(FetchDescriptor<Fact>(sortBy: [SortDescriptor(\.created, order: .reverse)]))) ?? []
        let chosen = Set(KnownFacts.relevant(facts.map(\.text), to: text, limit: limit))
        // With when each was noted, so "next Friday" from a month ago isn't taken as this week's.
        return facts.filter { chosen.contains($0.text) }.prefix(limit).map {
            "\($0.text) (noted \($0.created.formatted(.dateTime.day().month(.abbreviated))))"
        }
    }

    /// For the top of a prompt about the latest conversation: its notes and the facts that bear on it.
    func latestBackground() -> String {
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.end, order: .reverse)])
        d.fetchLimit = 1
        guard let c = (try? modelContext.fetch(d))?.first else { return "" }
        let memory = c.memory
        let about = memory.text() + " " + (c.title ?? "") + " " + Prompts.tail(c.transcript, budget: 300)
        return Prompts.background(memory: memory, facts: relevantFacts(to: about, limit: 4))
    }

    /// Picks out facts worth keeping after today, once a conversation's over.
    private func learnFacts(from id: UUID) async {
        guard Brain.notReadyReason == nil, let c = conversation(id), c.transcript.split(whereSeparator: \.isWhitespace).count >= 30 else { return }
        let known = ((try? modelContext.fetch(FetchDescriptor<Fact>())) ?? []).map(\.text)
        let prompt = Prompts.lastingFacts(transcript: c.transcript, known: KnownFacts.relevant(known, to: c.transcript, limit: 15))
        guard let found = await withDeadline(40, { await Log.attempt("Lasting facts", { try await Brain.lastingFacts(prompt) }) }),
              conversation(id) != nil else { return }
        let fresh = KnownFacts.fresh(found, known: known).prefix(5)
        for f in fresh { modelContext.insert(Fact(text: f, conversationID: id)) }
        if !fresh.isEmpty {
            try? modelContext.save()
            Log.info("Learnt \(fresh.count) lasting fact(s)")
        }
    }

    // MARK: - Hearing it again

    /// Whether finished conversations are heard again as a whole: for the voices (needs the voice
    /// models), or the words (Settings › Better Accuracy).
    static var hearAgain: Bool { voicesAgain || Parakeet.inUse }
    private static var voicesAgain: Bool { VoiceEngine.enabled && VoiceEngine.downloaded }
    /// Longer than this, a conversation's left as it was transcribed (memory and battery).
    static let hearAgainLimit = 20.0 * 60

    /// When a conversation's over, it's heard again as a whole: the voices told apart across all
    /// of it at once (steadier than recording by recording, where a short snippet can be put
    /// down to the wrong person), and the words transcribed with all the context around them.
    /// With Better Accuracy on, the words come from Parakeet (Apple's if that fails), and even a
    /// conversation of one recording is heard again for them, if it's long enough to be worth
    /// loading the model (its voices were told apart just now, so they stay as they are).
    /// It replaces the first transcript only if it's sound and nothing changed it meanwhile (you
    /// naming a voice or fixing a word), then misheard words are fixed again. The audio is
    /// deleted afterwards either way.
    private func secondPass(_ id: UUID) async {
        defer { forgetAudio(of: id) }
        guard Self.hearAgain, let c = conversation(id), c.userEdited != true else { return }
        let cid: UUID? = id
        let chunks = (try? modelContext.fetch(FetchDescriptor<Chunk>(predicate: #Predicate { $0.conversationID == cid && $0.status == "done" },
                                                                     sortBy: [SortDescriptor(\.start)]))) ?? []
        let recordings = chunks.compactMap { chunk in chunk.path.map { (url: URL(fileURLWithPath: $0), recorded: chunk.start) } }
        let length = chunks.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        let better = Parakeet.inUse, single = chunks.count == 1
        let voicesOn = Self.voicesAgain && !single
        guard chunks.count >= (better ? 1 : 2), !single || length >= 20, recordings.count == chunks.count, length <= Self.hearAgainLimit,
              recordings.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path) }) else { return }
        let before = c.transcript
        let started = Date()
        let url = Recorder.audioDirectory.appendingPathComponent("whole_\(id.uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let joined = Self.join(recordings, into: url) else { return }
        // Its own voice models, so recordings being made now aren't kept waiting behind it.
        async let heardVoices = Self.voices(in: url, length: joined.length, on: voicesOn)
        // Parakeet's first load can take a while (the Neural Engine prepares it): more time for it.
        let words = await withDeadline((better ? 60 : 30) + 1.5 * joined.length) { () -> [SpeakerAlign.Word]? in
            if better {
                do {
                    let heard = try await Parakeet.shared.words(url)
                    if !heard.isEmpty { return heard }
                } catch {
                    Log.error("Better Accuracy couldn't transcribe the conversation; using Apple's recogniser", error)
                }
            }
            do { return try await SpeechEngine.shared.words(url) } catch {
                Log.error("Couldn't transcribe the whole conversation again", error)
                return nil
            }
        }
        let split = await heardVoices
        // Parakeet isn't told the names to expect, as Apple's recogniser is (see missedNames).
        let expected = better ? await SpeechEngine.shared.expectedWords() : []
        // Without the voices, Better Accuracy's words are still worth having (see keptVoices).
        guard var words, !words.isEmpty, split != nil || !voicesOn || better else {
            Log.info("Hearing the conversation again didn't finish, so it's kept as it was")
            return
        }
        guard let now = conversation(id), now.transcript == before, now.userEdited != true else {
            Log.info("The conversation changed while it was being heard again, so it's kept as it is")
            return
        }
        if better { words = Self.withLearnedNames(words) }
        // Without the voice models, every line's just "Speech", as it was.
        var heard: [Voiceprint] = []
        let labels = split.map { VoiceMatcher.label($0.voices, heard: &heard, known: knownVoices()) } ?? [:]
        var turns = split?.turns.compactMap { t in labels[t.speaker].map { SpeakerAlign.Turn(start: t.start, end: t.end, speaker: $0) } } ?? []
        // A name given to a voice as it went (you named it, or it was matched then) that this
        // hearing doesn't find, or no voices heard this time: the voices stay as they were.
        let named = Set(Labels.speakers(in: before)).filter { $0 != Labels.anonymous && Labels.number($0) == nil }
        let keptVoices = single || (voicesOn && split == nil) || !named.isSubset(of: Set(labels.values))
        if keptVoices { turns = Self.turns(of: before, from: now.start, in: joined) }
        let fallback = keptVoices ? turns.first?.speaker ?? Labels.anonymous
            : split == nil ? Labels.anonymous : turns.first?.speaker ?? Labels.numbered(1)
        // A line every half a minute or so, as when it was heard as it went: one voice talking
        // for minutes (or voices not told apart) would otherwise be one line, with one time, for the lot.
        var pieces: [String] = []
        var last = fallback
        for stretch in Self.stretches(of: words) {
            let said = SpeakerAlign.assign(stretch, turns: turns, fallback: last)
            last = said.last?.speaker ?? last
            let utterances = said.compactMap { s -> Utterance? in
                let text = TranscriptFormat.clean(s.text)
                return text.isEmpty ? nil : Utterance(start: joined.time(at: s.start), speaker: s.speaker, text: text)
            }
            let piece = TranscriptFormat.lines(utterances)
            if !piece.isEmpty { pieces.append(piece) }
        }
        let transcript = pieces.joined(separator: "\n")
        guard JoinedAudio.accept(old: before, new: transcript) else {
            Log.info("Heard the conversation again, but the result didn't look right, so it's kept as it was")
            return
        }
        let voicesBefore = Set(Labels.speakers(in: before)).count
        now.transcript = transcript
        if split != nil && !keptVoices { now.voiceprints = heard }
        try? modelContext.save()
        Log.info("Heard a \(Int(joined.length / 60)) min conversation again as a whole\(better ? " (Better Accuracy)" : ""): \(keptVoices ? "voices kept as they were, " : "")\(Set(turns.map(\.speaker)).count) voices (was \(voicesBefore)), \(String(format: "%.0f", Date().timeIntervalSince(started))) s")
        // Misheard words fixed again: the stretches with words the recogniser doubted.
        guard Brain.notReadyReason == nil else { return }
        var doubts = Doubts.of(words, limit: 60)
        let missed = better ? Self.missedNames(words, before: before, from: now.start, in: joined, expected: expected) : []
        let alreadyDoubted = Set(doubts.map(\.word))
        doubts += missed.filter { !alreadyDoubted.contains($0.word) }
        let protected = Doubts.protected(words).subtracting(missed.map(\.word))
        let doubted = Set(doubts.map(\.word))
        let lines = transcript.split(separator: "\n").map(String.init)
        for start in stride(from: 0, to: lines.count, by: 12) {
            let group = lines[start..<min(start + 12, lines.count)].joined(separator: "\n")
            let groupWords = Set(group.split(whereSeparator: \.isWhitespace).map { Doubts.normal(String($0)) })
            guard !groupWords.isDisjoint(with: doubted) else { continue }
            let mentioned = doubts.filter { groupWords.contains($0.word) }
            _ = await correctMisheard(group, in: id, doubts: mentioned, protected: protected)
        }
    }

    /// The voices as they were heard as it went: a turn for each line of [transcript], until the
    /// next line, in seconds into the joined audio.
    private static func turns(of transcript: String, from start: Date, in joined: JoinedAudio) -> [SpeakerAlign.Turn] {
        spans(of: transcript, from: start, in: joined).map { SpeakerAlign.Turn(start: $0.start, end: $0.end, speaker: $0.speaker) }
    }

    /// Each line of [transcript], who said it and what, from when it was said until the next
    /// line, in seconds into the joined audio.
    private static func spans(of transcript: String, from start: Date, in joined: JoinedAudio) -> [(start: Double, end: Double, speaker: String, text: String)] {
        let lines = transcript.split(separator: "\n")
        let times = TranscriptFormat.times(of: lines, from: start)
        var timed: [(at: Double, speaker: String, text: String)] = []
        for (i, line) in lines.enumerated() {
            guard let t = times[i], let g = TranscriptFormat.turn.whole(String(line)) else { continue }
            // Line times are to the second: a line just after a recording began counts as in it.
            guard let piece = joined.pieces.last(where: { $0.recorded <= t.addingTimeInterval(1) }) ?? joined.pieces.first else { continue }
            timed.append((piece.at + min(max(0, t.timeIntervalSince(piece.recorded)), piece.length), g[1], g[2]))
        }
        return timed.enumerated().map { i, line in
            (start: line.at, end: i + 1 < timed.count ? timed[i + 1].at : joined.length, speaker: line.speaker, text: line.text)
        }
    }

    /// About this long, a line of a conversation heard again ends at the end of a sentence; at
    /// twice this, wherever it's got to.
    static let lineSeconds = 25.0

    /// [words] in stretches of about [lineSeconds], each to be a line (or a line per voice) of its own.
    private static func stretches(of words: [SpeakerAlign.Word]) -> [[SpeakerAlign.Word]] {
        var out: [[SpeakerAlign.Word]] = []
        var current: [SpeakerAlign.Word] = []
        for w in words {
            if let first = current.first, let previous = current.last {
                let span = w.start - first.start
                let sentenceEnded = previous.text.trimmingCharacters(in: .whitespaces).last.map { ".?!\u{2026}".contains($0) } ?? false
                if span > 2 * lineSeconds || (span > lineSeconds && sentenceEnded) {
                    out.append(current)
                    current = []
                }
            }
            current.append(w)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Names you've corrected ("Shona" → "Siobhan") put right in Parakeet's words: unlike Apple's
    /// recogniser, it isn't told them. Only names, one word for one: a fix of an ordinary word
    /// may not be right everywhere it's heard. And only where Parakeet took it for a name too
    /// (a capital, not just a sentence's first word): a name once misheard as "and" or "will"
    /// isn't put in for every "and" or "will".
    private static func withLearnedNames(_ words: [SpeakerAlign.Word]) -> [SpeakerAlign.Word] {
        var names: [String: String] = [:]
        // Most used first, so that one wins.
        for fix in Learned.fixes where !fix.heard.contains(" ") && !fix.meant.contains(" ") && fix.meant.first?.isUppercase == true {
            if names[fix.heard] == nil { names[fix.heard] = fix.meant }
        }
        guard !names.isEmpty else { return words }
        return words.indices.map { i in
            let w = words[i]
            guard let meant = names[Doubts.normal(w.text)], w.text.first?.isUppercase == true, i > 0,
                  let end = words[i - 1].text.last, !".?!\u{2026}".contains(end) else { return w }
            var fixed = w
            // Punctuation after it is kept ("Shona," → "Siobhan,").
            fixed.text = meant + String(w.text.reversed().prefix(while: { $0.isPunctuation }).reversed())
            return fixed
        }
    }

    /// Names WTF was told to expect (people, contacts, what you've corrected) that the first
    /// hearing got and Parakeet didn't: what it heard around that line instead is pointed out to
    /// the AI, with the name as the likely reading, rather than kept because it was sure of it.
    private static func missedNames(_ words: [SpeakerAlign.Word], before: String, from start: Date, in joined: JoinedAudio,
                                    expected: [String]) -> [Doubt] {
        func tokens(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map { Doubts.normal(String($0)) } }
        let expect = Set(expected.flatMap(tokens).filter { $0.count >= 3 })
        guard !expect.isEmpty else { return [] }
        let heardNow = Set(words.map { Doubts.normal($0.text) })
        let lines = spans(of: before, from: start, in: joined)
        let heardThen = Set(lines.flatMap { tokens($0.text) })
        var out: [Doubt] = []
        var seen = Set<String>()
        for line in lines {
            let lost = Set(tokens(line.text)).filter { expect.contains($0) && !heardNow.contains($0) }
            guard !lost.isEmpty else { continue }
            for w in words where w.end > line.start - 1 && w.start < line.end + 1 {
                let n = Doubts.normal(w.text)
                guard !n.isEmpty, !heardThen.contains(n), seen.insert(n).inserted else { continue }
                out.append(Doubt(word: n, confidence: w.confidence, alternatives: Array(lost.sorted().prefix(3))))
            }
        }
        return Array(out.prefix(20))
    }

    /// Who spoke when in the whole conversation, if the voice models are on.
    private static func voices(in url: URL, length: Double, on: Bool) async -> VoiceEngine.Split? {
        guard on else { return nil }
        return await withDeadline(60 + length) { await VoiceEngine.whole.split(url) }
    }

    /// Recordings joined into one file, with half a second between each.
    private static func join(_ pieces: [(url: URL, recorded: Date)], into url: URL) -> JoinedAudio? {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        var joined = JoinedAudio()
        do {
            let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let gapFrames = AVAudioFrameCount(JoinedAudio.gap * out.processingFormat.sampleRate)
            guard let gap = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: gapFrames) else { return nil }
            gap.frameLength = gapFrames
            gap.floatChannelData![0].update(repeating: 0, count: Int(gapFrames)) // silence
            for (i, piece) in pieces.enumerated() {
                let file = try AVAudioFile(forReading: piece.url, commonFormat: .pcmFormatFloat32, interleaved: false)
                guard file.processingFormat.sampleRate == out.processingFormat.sampleRate,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
                try file.read(into: buffer)
                if i > 0 { try out.write(from: gap) }
                try out.write(from: buffer)
                joined.add(length: Double(buffer.frameLength) / file.processingFormat.sampleRate, recorded: piece.recorded)
            }
        } catch {
            Log.error("Couldn't join a conversation's recordings", error)
            return nil
        }
        return joined
    }

    // MARK: - Fixing words

    /// You fixed a line: it's changed, and what you changed is learnt for next time. Found by its
    /// words, or (if the AI tidied it meanwhile) by its time and speaker. False if it's gone.
    func fixLine(in id: UUID, original: String, text typed: String) async -> Bool {
        let new = typed.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, let c = conversation(id) else { return false }
        var lines = c.transcript.components(separatedBy: "\n")
        let prefix = Corrections.prefix(of: original)
        guard let i = lines.firstIndex(of: original) ?? (prefix.isEmpty ? nil : lines.firstIndex { $0.hasPrefix(prefix) }) else { return false }
        let old = Corrections.text(of: lines[i])
        guard old != new else { return true }
        lines[i] = Corrections.prefix(of: lines[i]) + new
        c.transcript = lines.joined(separator: "\n")
        let pairs = Fixes.pairs(from: old, to: new)
        Learned.add(pairs)
        c.fixes = Fixes.learn(pairs, into: c.fixes, limit: 100)
        c.userEdited = true
        try? modelContext.save()
        Log.info("You fixed \(pairs.count) word(s) in a line")
        await refreshVocabulary()
        // As when first heard: with the AI, the rules' to-dos and shopping aren't suggested on their own.
        if let fresh = conversation(id) { await suggest(for: fresh, found: instantActions(fresh)) }
        return true
    }

    // MARK: - Naming voices

    /// "Speaker 2 is Sarah" (or "that's me"): renames their lines, remembers their voice, and finds
    /// them in your other conversations. Returns the name used and how many others they were in.
    func nameVoice(in id: UUID, label: String, as typed: String) -> (name: String, elsewhere: Int)? {
        guard let name = Labels.cleanName(typed), name != label,
              let c = (try? modelContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })))?.first
        else { return nil }
        let isMe = name == Labels.me
        let heard = c.voiceprints.first { $0.label == label }
        let people = (try? modelContext.fetch(FetchDescriptor<Person>())) ?? []
        var person = people.first { isMe ? $0.isMe : !$0.isMe && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if let heard {
            if let person { person.add(heard.print, seconds: heard.seconds) }
            else {
                let p = Person(name: isMe ? "Me" : name, print: heard.print, seconds: heard.seconds, isMe: isMe)
                modelContext.insert(p)
                person = p
            }
        }
        let shown = person?.voice.label ?? name
        relabel(c, from: label, to: shown)
        var elsewhere = 0
        if let voice = person?.voice {
            let all = (try? modelContext.fetch(FetchDescriptor<Conversation>())) ?? []
            for other in all where other.id != c.id && !other.voiceprints.contains(where: { $0.label == shown }) {
                if let match = VoiceMatcher.match(voice, in: other.voiceprints) {
                    relabel(other, from: match, to: shown)
                    elsewhere += 1
                }
            }
        }
        try? modelContext.save()
        return (shown, elsewhere)
    }

    /// A named person called something else, everywhere. Not to a name someone else has: that
    /// would merge two people.
    func renamePerson(_ id: UUID, to typed: String) {
        guard let p = (try? modelContext.fetch(FetchDescriptor<Person>(predicate: #Predicate { $0.id == id })))?.first,
              !p.isMe, let name = Labels.cleanName(typed), name != Labels.me, name != p.name else { return }
        let people = (try? modelContext.fetch(FetchDescriptor<Person>())) ?? []
        if people.contains(where: { $0.id != p.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return }
        let old = p.name
        p.name = name
        for c in (try? modelContext.fetch(FetchDescriptor<Conversation>())) ?? [] where c.transcript.contains("] \(old): ") {
            relabel(c, from: old, to: name)
        }
        try? modelContext.save()
    }

    /// Renaming someone already named in a transcript: the person, everywhere (not a second
    /// person with the same voice). False if no one's called that.
    func renamePerson(named old: String, to typed: String) -> Bool {
        guard let p = ((try? modelContext.fetch(FetchDescriptor<Person>())) ?? []).first(where: { !$0.isMe && $0.name == old }) else { return false }
        renamePerson(p.id, to: typed)
        return true
    }

    /// A person forgotten (Settings › People): their voice goes from the conversations too, so
    /// it isn't matched again from there.
    func forgetVoice(named name: String) {
        var changed = false
        for c in (try? modelContext.fetch(FetchDescriptor<Conversation>())) ?? [] where c.voiceprints.contains(where: { $0.label == name }) {
            c.voiceprints = c.voiceprints.filter { $0.label != name }
            changed = true
        }
        if changed { try? modelContext.save() }
    }

    /// A conversation renamed by you: saved here, so a summary being written meanwhile doesn't
    /// put its own title back over it.
    func rename(_ id: UUID, to title: String) {
        guard let c = conversation(id) else { return }
        c.title = title
        try? modelContext.save()
    }

    private func relabel(_ c: Conversation, from: String, to: String) {
        c.transcript = Labels.rename(c.transcript, from: from, to: to)
        c.title = c.title.map { Labels.renameInText($0, from: from, to: to) }
        c.summary = c.summary.map { Labels.renameInText($0, from: from, to: to) }
        var voices = c.voiceprints
        if let i = voices.firstIndex(where: { $0.label == from }) {
            let moved = voices.remove(at: i)
            if let j = voices.firstIndex(where: { $0.label == to }) { voices[j].add(moved.print, seconds: moved.seconds) }
            else { voices.append(Voiceprint(label: to, print: moved.print, seconds: moved.seconds)) }
            c.voiceprints = voices
        }
    }

    // MARK: - Private

    private func score(_ c: Conversation, _ keys: [String]) -> Double {
        let notes = ((c.title ?? "") + " " + (c.summary ?? "")).lowercased()
        let text = c.transcript.lowercased()
        var s = 0.0
        for k in keys {
            if notes.contains(k) { s += 3 }
            s += Double(min(text.components(separatedBy: k).count - 1, 5))
        }
        return s + c.start.timeIntervalSince1970 / 1e10 // newer wins ties
    }

    /// In the iPhone's own clock (12 or 24 hours): the AI copies it into its answers.
    private func label(_ c: Conversation) -> String {
        let today = Calendar.current.isDateInToday(c.start)
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(today ? "jmm" : "EEEdMMMjmm")
        let e = DateFormatter()
        e.setLocalizedDateFormatFromTemplate("jmm")
        return "\(today ? "Today " : "")\(f.string(from: c.start))–\(e.string(from: c.end))"
    }

    /// The conversation a recording carries on, if it's soon enough after the last one. A
    /// recording transcribed late (a retry, after newer ones) goes back into the conversation it
    /// was said in, if there is one, rather than onto the end of the latest.
    private func openConversation(for chunk: Chunk) -> Conversation? {
        let gap = Double(gapMinutes) * 60
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.end, order: .reverse)])
        d.fetchLimit = 1
        guard let latest = (try? modelContext.fetch(d))?.first else { return nil }
        if chunk.start >= latest.end {
            guard !latest.closed, chunk.start.timeIntervalSince(latest.end) <= gap else { return nil }
            return latest
        }
        let (from, to) = (chunk.start.addingTimeInterval(-gap), chunk.end.addingTimeInterval(gap))
        let around = (try? modelContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.start <= to && $0.end >= from }))) ?? []
        func distance(_ c: Conversation) -> TimeInterval {
            chunk.start < c.start ? c.start.timeIntervalSince(chunk.start) : max(0, chunk.start.timeIntervalSince(c.end))
        }
        return around.min { distance($0) < distance($1) }
    }

    private func attach(_ chunk: Chunk, text: String, to open: Conversation?) -> Conversation {
        if let open {
            open.transcript = TranscriptFormat.insert(text, at: chunk.start, into: open.transcript, from: open.start)
            open.start = min(open.start, chunk.start)
            open.end = max(open.end, chunk.end)
            return open
        }
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.end, order: .reverse)])
        d.fetchLimit = 1
        // A new conversation ends the one before, unless this recording's older than it (a late
        // retry with nothing around it): then it's a conversation of its own, in the past.
        if let latest = (try? modelContext.fetch(d))?.first, chunk.start >= latest.end { latest.closed = true }
        let c = Conversation(start: chunk.start, end: chunk.end, transcript: text)
        let end = chunk.end
        if ((try? modelContext.fetchCount(FetchDescriptor<Conversation>(predicate: #Predicate { $0.end > end }))) ?? 0) > 0 { c.closed = true }
        modelContext.insert(c)
        return c
    }

    /// The words, each line labelled with its voice: you, someone you've named, or "Speaker N".
    /// Without the voice models, every line is just "Speech".
    private func whoSaidWhat(_ words: [SpeakerAlign.Word], split: VoiceEngine.Split?, voices: inout [Voiceprint],
                             before: String?, start: Date) -> [Utterance] {
        var turns: [SpeakerAlign.Turn] = []
        var fallback = Labels.anonymous
        if let split {
            let labels = VoiceMatcher.label(split.voices, heard: &voices, known: knownVoices())
            turns = split.turns.compactMap { t in labels[t.speaker].map { SpeakerAlign.Turn(start: t.start, end: t.end, speaker: $0) } }
            // Words the voices didn't cover: most likely whoever was speaking last.
            fallback = lastSpeaker(before).flatMap { $0 == Labels.anonymous ? nil : $0 } ?? turns.first?.speaker ?? Labels.numbered(1)
        }
        return SpeakerAlign.assign(words, turns: turns, fallback: fallback).compactMap { said in
            let text = TranscriptFormat.clean(said.text)
            return text.isEmpty ? nil : Utterance(start: start.addingTimeInterval(said.start), speaker: said.speaker, text: text)
        }
    }

    private func lastSpeaker(_ transcript: String?) -> String? {
        transcript?.split(separator: "\n").last.flatMap { TranscriptFormat.turn.whole(String($0))?[1] }
    }

    /// The thread map: which topic each new stretch of talk belongs to, and what got left hanging.
    private func followThreads() async {
        guard Brain.notReadyReason == nil else { toFollow = []; return }
        while !toFollow.isEmpty {
            let next = toFollow.removeFirst()
            let id = next.id
            guard conversation(id) != nil else { continue }
            let text = await correctMisheard(next.text, in: id, doubts: next.doubts, protected: next.protected)
            unremembered[id] = [unremembered[id], text].compactMap { $0 }.joined(separator: "\n")
            await remember(id)
            guard let c = conversation(id) else { continue }
            let before = c.transcript.hasSuffix(text) ? String(c.transcript.dropLast(text.count)) : ""
            let prompt = Threads.prompt(c.threads, recent: before, new: text)
            guard let change = await withDeadline(40, { await Log.attempt("Thread map", { try await Brain.topic(prompt) }) }),
                  let fresh = conversation(id) else { continue }
            fresh.threads = Threads.apply(change, to: fresh.threads, from: next.from, to: next.to)
            try? modelContext.save()
            // A late retry joins an older conversation: its trail isn't what's being said now.
            guard latestConversation()?.id == id else { continue }
            await showTrail(of: fresh)
        }
    }

    /// "Bucked the back room" → "booked": the AI fixes words the recogniser misheard, from
    /// context, starting with the ones it doubted, and knowing the names and words you use and
    /// the mistakes you've corrected before. A fix is only kept if it changes a few words, leaves
    /// the rest as said, and doesn't touch a word the recogniser was sure of (unless it's one
    /// you've corrected before).
    private func correctMisheard(_ text: String, in id: UUID, doubts: [Doubt], protected: Set<String>) async -> String {
        let lines = text.split(separator: "\n").map(String.init)
        guard !lines.isEmpty, let first = conversation(id), first.transcript.contains(text) else { return text }
        let known = await SpeechEngine.shared.expectedWords()
        let learned = Learned.fixes
        let guarded = protected.subtracting(learned.flatMap { $0.heard.split(separator: " ").map(String.init) })
        guard let proposed = await withDeadline(30, { await Log.attempt("Correcting misheard words", {
                  try await Brain.correct(lines, doubts: doubts, known: known, learned: learned)
              }) }),
              let c = conversation(id), c.transcript.contains(text) else { return text }
        let fixedLines = Corrections.apply(proposed, to: lines, protected: guarded)
        let fixed = fixedLines.joined(separator: "\n")
        guard fixed != text else { return text }
        c.transcript = c.transcript.replacingOccurrences(of: text, with: fixed)
        try? modelContext.save()
        Log.info("Corrected misheard words in \(zip(lines, fixedLines).filter { $0.0 != $0.1 }.count) line(s)")
        await suggest(for: c, found: instantActions(c, new: fixed))
        return fixed
    }

    /// Puts the latest conversation's trail on the Lock Screen and in the Dynamic Island.
    private func showTrail(of c: Conversation) async {
        let threads = c.threads
        await MainActor.run { ListeningActivity.shared.show(threads) }
    }

    /// Tells the recogniser the names and words it should expect: people you've named, words
    /// you've corrected, names in what WTF knows, your contacts and calendar (if you've said so),
    /// your list and the shops. Also applied to the live recogniser as it runs.
    private func refreshVocabulary() async {
        let people = ((try? modelContext.fetch(FetchDescriptor<Person>())) ?? []).filter { !$0.isMe }.map(\.name)
        let items = ((try? modelContext.fetch(FetchDescriptor<ActionItem>(predicate: #Predicate { $0.status == "accepted" || $0.status == "suggested" }))) ?? []).map(\.title)
        var recentFacts = FetchDescriptor<Fact>(sortBy: [SortDescriptor(\.created, order: .reverse)])
        recentFacts.fetchLimit = 40
        let facts = ((try? modelContext.fetch(recentFacts)) ?? []).map(\.text)
        let personal = await PersonalWords.words()
        // Each kind has its share, so the list and the shops still fit however much is learnt.
        let extra: [String] = Learned.fixes.prefix(20).map(\.meant) + Array(KnownFacts.names(in: facts).prefix(15)) + Array(personal.prefix(35))
        let words = Vocabulary.words(people: people, items: items, extra: extra, limit: 120)
        guard await SpeechEngine.shared.expectedWords() != words else { return }
        await SpeechEngine.shared.setVocabulary(words)
        await LiveTranscriber.shared.refreshVocabulary()
    }

    private func knownVoices() -> [KnownVoice] {
        ((try? modelContext.fetch(FetchDescriptor<Person>())) ?? []).map(\.voice)
    }

    /// What's suggested the moment it's heard. With the AI, only appointments with a day: to-dos
    /// and shopping wait for findListItems, where the AI weighs them, as the rules alone are noisy.
    private func instantActions(_ c: Conversation, new: String? = nil) -> [ExtractedAction] {
        let found = ruleActions(c, new: new)
        guard Brain.notReadyReason == nil else { return found }
        return found.filter { $0.type == .event && $0.resolved != nil }
    }

    /// [new]: only the lines just added (and the one before, for what led up to them) are looked
    /// through, as the rest were when they came in: a conversation can run for hours, and this is
    /// done for every recording.
    private func ruleActions(_ c: Conversation, new: String? = nil) -> [ExtractedAction] {
        var said = c.transcript
        if let new, !new.isEmpty, let r = c.transcript.range(of: new, options: .backwards) {
            let head = c.transcript[..<r.lowerBound].dropLast() // the line break before it
            let from = head.lastIndex(of: "\n").map { head.index(after: $0) } ?? head.startIndex
            said = String(c.transcript[from..<r.upperBound])
        }
        // Once WTF knows your voice, to-dos are what you said you'd do; until then, any line could be yours.
        return ActionRules.ruleActions(ActionRules.candidateLines(said), conversationStart: c.start, title: c.title,
                                       youOnly: c.transcript.contains("] \(Labels.me): "))
    }

    /// A conversation that's over: heard again as a whole, then its title, summary, list items
    /// and lasting facts. Each step fetches it afresh, as you may have deleted it meanwhile.
    private func summarise(_ id: UUID) async {
        guard let c = conversation(id) else { return }
        // Over: nothing more joins it, even while it's being heard again and summarised.
        if !c.closed {
            c.closed = true
            try? modelContext.save()
        }
        await secondPass(id)
        guard Brain.notReadyReason == nil, let c = conversation(id) else { return }
        c.threads = Threads.close(c.threads)
        try? modelContext.save()
        await remember(id, force: true)
        guard let c = conversation(id) else { return }
        let background = Prompts.background(memory: c.memory, facts: relevantFacts(to: c.memory.text() + " " + Prompts.tail(c.transcript, budget: 400), limit: 4))
        let transcript = c.transcript
        var written: (title: String, points: [String])?
        if let notes = await withDeadline(60, { await Log.attempt("Summary", { try await Brain.summarise(transcript, background: background) }) }) {
            written = (notes.title, notes.points)
        } else if let plain = await withDeadline(60, { await Log.attempt("Summary in plain text", { try await Brain.summariseText(transcript, background: background) }) }) {
            written = plain // the structured notes were refused (a sensitive subject) or failed
        }
        guard let written else {
            // Tried again on later runs, but not for ever: after three goes it's called just
            // "Conversation", rather than "Summarising…" for good and an AI call on every recording.
            // Counted on the conversation, so being ended in the background doesn't start it again.
            guard let c = conversation(id) else { return }
            let tries = (c.summaryAttempts ?? 0) + 1
            c.summaryAttempts = tries
            c.summaryTriedAt = Date()
            Log.error("Couldn't summarise a \(transcript.count)-character conversation (try \(tries))")
            if tries >= 3 {
                if c.title == nil { c.title = "Conversation" }
                c.summary = ""
                // Its facts and list items are still looked for: they're asked for separately.
                c.extracted = false
            }
            try? modelContext.save()
            if tries >= 3 { await extract(id) }
            return
        }
        guard let c = conversation(id) else { return }
        // Only the user names a conversation before it's summarised: their name stays.
        if c.title == nil { c.title = written.title }
        c.summary = written.points.map { "\u{2022} " + $0 }.joined(separator: "\n")
        c.extracted = false
        try? modelContext.save()
        await extract(id)
    }

    /// A summarised conversation's lasting facts and list items. Marked done only once both have
    /// been looked for, so WTF closed part-way through looks again on the next run.
    private func extract(_ id: UUID) async {
        await learnFacts(from: id)
        await findListItems(in: id)
        guard let c = conversation(id) else { return }
        c.extracted = true
        try? modelContext.save()
    }

    private func findListItems(in id: UUID) async {
        guard let c = conversation(id) else { return }
        let lines = ActionRules.candidateLines(c.transcript)
        guard !lines.isEmpty else { return }
        let recent = Array(lines.suffix(60)), start = c.start
        let notesOnly = Prompts.background(memory: c.memory, facts: [])
        guard let found = await withDeadline(60, { await Log.attempt("List items", { try await Brain.actions(lines: recent, start: start, background: notesOnly) }) }) else {
            Log.error("Couldn't find list items in a conversation")
            // The rules' to-dos and shopping waited for this (see instantActions): not lost with it.
            if let c = conversation(id) { await suggest(for: c, found: ruleActions(c)) }
            return
        }
        guard let c = conversation(id) else { return }
        let fromModel = ActionRules.fromModel(
            buy: found.buy, todo: found.todo,
            events: found.appointments.map { ($0.what, $0.when, $0.place, $0.booked) }, conversationStart: c.start, lines: recent)
        // The rules' finds give the AI's their quote and doubts, but a to-do or shopping item only
        // the rules found isn't suggested: they misfire on everyday talk ("I'm going to bed now").
        // One said before the lines the AI read is kept, though: nothing else would find it.
        let read = Set(recent)
        let merged = ActionRules.merge(fromModel, ruleActions(c)).filter { a in
            a.type == .event || fromModel.contains { $0.type == a.type && $0.title.lowercased() == a.title.lowercased() }
                || !(a.source.map { read.contains($0) } ?? true)
        }
        await suggest(for: c, found: merged)
    }

    /// Suggests what's new: not on the list already, and not already suggested from this conversation.
    private func suggest(for c: Conversation, found: [ExtractedAction]) async {
        guard !found.isEmpty, !forgotten.contains(c.id) else { return }
        let cid: UUID? = c.id
        let open = (try? modelContext.fetch(FetchDescriptor<ActionItem>(predicate: #Predicate { $0.status == "suggested" || $0.status == "accepted" }))) ?? []
        let mine = (try? modelContext.fetch(FetchDescriptor<ActionItem>(predicate: #Predicate { $0.conversationID == cid }))) ?? []
        func matches(_ item: ActionItem, _ a: ExtractedAction) -> Bool {
            item.type == a.type.rawValue && (item.title.lowercased() == a.title.lowercased() || ActionRules.similar(item.title, a.title))
        }
        // Another conversation's appointment is the same one only if it's on the same day: there's
        // a dentist or a meeting again next month.
        func sameDay(_ item: ActionItem, _ a: ExtractedAction) -> Bool {
            guard a.type == .event else { return true }
            guard let was = item.start, let now = a.resolved?.start() else { return item.start == nil && a.resolved?.start() == nil }
            return Calendar.current.isDate(was, inSameDayAs: now)
        }
        // This conversation's own one, moved to another day ("actually, it's Thursday now"), is
        // suggested again for the new day. One with no day said is the one already suggested, as
        // is one from the very words it was suggested from (you may have changed its day since).
        func sameAsMine(_ item: ActionItem, _ a: ExtractedAction) -> Bool {
            guard matches(item, a) else { return false }
            if a.resolved?.start() == nil || sameDay(item, a) { return true }
            let quote = a.source.map { Self.heard($0, about: a, on: c.start).quote } ?? a.whenText
            return quote != nil && quote == item.quote
        }
        func onSameDay(_ x: ExtractedAction, _ y: ExtractedAction) -> Bool {
            guard x.type == .event, let p = x.resolved?.start(), let q = y.resolved?.start() else { return true }
            return Calendar.current.isDate(p, inSameDayAs: q)
        }
        var fresh: [ExtractedAction] = []
        for a in found where !mine.contains(where: { sameAsMine($0, a) }) && !open.contains(where: { matches($0, a) && sameDay($0, a) })
            && !fresh.contains(where: { $0.type == a.type && ($0.title.lowercased() == a.title.lowercased() || ActionRules.similar($0.title, a.title)) && onSameDay($0, a) }) {
            fresh.append(a)
        }
        // Appointments checked against the calendar: already there, nothing to suggest; there at
        // another time, worth saying.
        fresh = fresh.compactMap { a -> ExtractedAction? in
            guard a.type == .event, let start = a.resolved?.start() else { return a }
            let entries = PersonalWords.calendarEntries(from: start.addingTimeInterval(-15 * 86_400), to: start.addingTimeInterval(15 * 86_400))
            switch CalendarCheck.check(title: a.title, start: start, allDay: a.resolved?.allDay ?? false, against: entries) {
            case .alreadyThere?:
                Log.info("Heard an appointment that's already in the calendar")
                return nil
            case .differs(let note)?:
                var b = a
                b.note = note
                return b
            case nil:
                return a
            }
        }
        guard !fresh.isEmpty else { return }
        // When each line was said, worked out over the whole transcript, so a line said after
        // midnight isn't dated a day early.
        let lines = c.transcript.split(separator: "\n")
        let times = TranscriptFormat.times(of: lines, from: c.start)
        for a in fresh {
            let heard = a.source.map { Self.heard($0, about: a, on: c.start) }
            let said = a.source.flatMap { source in lines.lastIndex(where: { $0 == source }).flatMap { times[$0] } }
            let item = ActionItem(type: a.type.rawValue, title: a.title, start: a.resolved?.start(),
                                  allDay: a.resolved?.allDay ?? false, place: a.place, quote: heard?.quote ?? a.whenText, conversationID: cid)
            item.heardAt = said ?? heard?.at
            item.note = a.note
            modelContext.insert(item)
        }
        try? modelContext.save()
        // A later one replaces it, so it lists everything from this conversation still waiting,
        // not only what was just heard.
        let waiting = (try? modelContext.fetch(FetchDescriptor<ActionItem>(
            predicate: #Predicate { $0.conversationID == cid && $0.status == "suggested" }, sortBy: [SortDescriptor(\.created)]))) ?? []
        guard !waiting.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "WTF heard \(waiting.count) thing\(waiting.count == 1 ? "" : "s") to act on"
        content.body = waiting.prefix(3).map(\.title).joined(separator: ", ") + (waiting.count > 3 ? " + \(waiting.count - 3) more" : "")
        // One per conversation (a later one replaces it), so it goes when the conversation does (forget).
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.heardNotice(c.id), content: content, trigger: nil))
    }

    /// The "WTF heard…" notification for a conversation.
    static func heardNotice(_ id: UUID) -> String { "wtf.heard.\(id.uuidString)" }
}

extension Pipeline {
    /// Where a list item came from: the sentence of its line that says it, and when that was.
    nonisolated static func heard(_ line: String, about a: ExtractedAction, on day: Date) -> (quote: String, at: Date?) {
        let text = line.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
        let sentences = text.split(whereSeparator: { ".?!".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let key = a.title + " " + (a.whenText ?? "")
        let best = sentences.max { ActionRules.overlap(key, $0) < ActionRules.overlap(key, $1) } ?? text
        var quote = best
        if let end = text.range(of: best)?.upperBound, end < text.endIndex, ".?!".contains(text[end]) { quote.append(text[end]) }
        if quote.count > 160 { quote = String(quote.prefix(157)) + "\u{2026}" }
        var at: Date?
        if let m = Rx(#"^\[(\d\d):(\d\d):(\d\d)\]"#).first(line) {
            at = Calendar.current.date(bySettingHour: Int(m[1])!, minute: Int(m[2])!, second: Int(m[3])!, of: day)
        }
        return (quote, at)
    }
}

extension Pipeline {
    /// A recording WTF was ended part-way through: the lengths in its header were never written,
    /// so they're put right from the file's size. The seconds of audio in it, or nil if it isn't
    /// a WAV file that can be read.
    nonisolated static func mend(_ url: URL) -> Double? {
        guard let file = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd(), size > 44, size < UInt64(UInt32.max) else { return nil }
        guard (try? file.seek(toOffset: 0)) != nil, let read = try? file.read(upToCount: 8192) else { return nil }
        let head = [UInt8](read)
        func word(_ at: Int) -> Int { Int(head[at]) | Int(head[at + 1]) << 8 | Int(head[at + 2]) << 16 | Int(head[at + 3]) << 24 }
        func name(_ at: Int) -> String { String(decoding: head[at..<at + 4], as: UTF8.self) }
        guard head.count >= 12, name(0) == "RIFF", name(8) == "WAVE" else { return nil }
        var bytesPerSecond = 32_000 // 16 kHz, 16-bit, one channel: as Recorder writes them
        var at = 12
        while at + 8 <= head.count {
            let length = word(at + 4)
            if name(at) == "fmt ", at + 20 <= head.count, word(at + 16) > 0 { bytesPerSecond = word(at + 16) }
            if name(at) == "data" {
                let start = at + 8
                var bytes = Int(size) - start
                bytes -= bytes % 2
                guard bytes > 0 else { return nil }
                func le(_ n: Int) -> Data { withUnsafeBytes(of: UInt32(n).littleEndian) { Data($0) } }
                do {
                    try file.seek(toOffset: 4)
                    try file.write(contentsOf: le(start + bytes - 8))
                    try file.seek(toOffset: UInt64(at + 4))
                    try file.write(contentsOf: le(bytes))
                } catch { return nil }
                return Double(bytes) / Double(bytesPerSecond)
            }
            at += 8 + length + (length & 1)
        }
        return nil
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

/// A step that didn't finish in time.
struct StepTimedOut: LocalizedError {
    var what: String
    var errorDescription: String? { "Gave up \(what): it took too long" }
}
