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

    /// Work runs in two queues, each one job at a time and in order: transcribing (what a question
    /// waits for) and the slower AI work after it (threads, summaries), so a question never waits
    /// behind a summary, and nothing is done twice.
    private var transcribing: Task<Bool, Never>?
    private var thinking: Task<Void, Never>?
    /// New lines whose topic hasn't been worked out yet (it waits until after any question's answered).
    /// Each with the words the recogniser doubted and the ones it was sure of, for fixing misheard words.
    private var toFollow: [(id: UUID, text: String, from: Date, to: Date, doubts: [Doubt], protected: Set<String>)] = []

    /// Conversations whose summary failed, and how often (see summarise).
    private var summaryFailures: [UUID: Int] = [:]

    /// The conversation going on was deleted: what's still being recorded or waiting to be
    /// transcribed would have joined it, so it goes too, rather than coming back as a new one.
    func cutOff() {
        wipedAt = Date()
        toFollow = []
        for chunk in (try? modelContext.fetch(FetchDescriptor<Chunk>(predicate: #Predicate { $0.status == "pending" }))) ?? [] {
            if let path = chunk.path { try? FileManager.default.removeItem(atPath: path) }
            modelContext.delete(chunk)
        }
        try? modelContext.save()
    }

    /// Bumped by Delete Everything: work that was waiting on something checks it hasn't happened meanwhile.
    private var wiped = 0
    /// When everything was last deleted: a recording that started before then, finished after, goes too.
    private var wipedAt = Date.distantPast

    /// A conversation, fetched afresh by its id: one held across a wait may have been deleted meanwhile.
    private func conversation(_ id: UUID) -> Conversation? {
        (try? modelContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })))?.first
    }

    func addChunk(url: URL, start: Date, end: Date) {
        guard start >= wipedAt else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        modelContext.insert(Chunk(start: start, end: end, path: url.path))
        try? modelContext.save()
    }

    /// Transcribes what's waiting, so a question includes the latest words. Summaries can wait.
    @discardableResult
    func catchUp() async -> Bool {
        let before = transcribing
        let job = Task { _ = await before?.value; return await self.transcribePending() }
        transcribing = job
        return await job.value
    }

    private func transcribePending() async -> Bool {
        let pending = (try? modelContext.fetch(FetchDescriptor<Chunk>(
            predicate: #Predicate { $0.status == "pending" }, sortBy: [SortDescriptor(\.start)]))) ?? []
        guard !pending.isEmpty, await SpeechEngine.shared.isReady() else { return true }
        let generation = wiped
        defer { Task { @MainActor in AppModel.shared.transcribing = nil } }
        var ok = true
        for (i, chunk) in pending.enumerated() {
            await MainActor.run { AppModel.shared.transcribing = (i, pending.count) }
            guard wiped == generation else { return false }
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
                if isSong {
                    Log.info("Recording \(chunk.start.formatted(date: .omitted, time: .standard)) (\(Int(length)) s) was music, so it wasn't transcribed")
                    let (from, to) = (chunk.start, chunk.end)
                    _ = await withDeadline(4) { await LiveTranscriber.shared.words(from: from, to: to) }
                    guard wiped == generation else { return false }
                    chunk.status = "music"
                    chunk.path = nil
                    try? FileManager.default.removeItem(atPath: path)
                    try? modelContext.save()
                    continue
                }
                async let heardVoices = withDeadline(60 + length) { await VoiceEngine.shared.split(url) }
                // Usually the words were heard live already; if not, from the file.
                var words = await withDeadline(4) { await LiveTranscriber.shared.words(from: chunk.start, to: chunk.end) }
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
                    await suggest(for: c, found: ruleActions(c))
                    guard wiped == generation else { return false }
                }
                if !keepAudio {
                    chunk.path = nil
                    try? FileManager.default.removeItem(atPath: path)
                }
            } catch {
                guard wiped == generation else { return false }
                Log.error("Couldn't transcribe the recording from \(chunk.start.formatted(date: .omitted, time: .standard)) (try \(chunk.attempts + 1) of 5)", error)
                chunk.attempts += 1
                if chunk.attempts >= 5 {
                    chunk.status = "failed"
                    chunk.path = nil
                    try? FileManager.default.removeItem(atPath: path)
                }
                ok = false
            }
            try? modelContext.save()
        }
        return ok
    }

    /// Catch up, then summarise conversations that have gone quiet, then tidy away old ones.
    func run() async {
        await refreshVocabulary()
        await catchUp()
        let before = thinking
        let job = Task { await before?.value; await self.think() }
        thinking = job
        await job.value
    }

    /// The slow part: the thread map, summaries of finished conversations, and tidying up.
    private func think() async {
        let generation = wiped
        sweepAudio()
        await followThreads()
        guard wiped == generation else { return }
        let quietBefore = Date().addingTimeInterval(-Double(gapMinutes) * 60)
        let waiting = ((try? modelContext.fetch(FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.summary == nil }))) ?? []).filter { $0.closed || $0.end < quietBefore }.map(\.id)
        for id in waiting {
            guard wiped == generation else { return }
            await summarise(id)
        }
        guard wiped == generation else { return }
        // Old recordings' records go here; old conversations go in the app (AppModel.expireOld),
        // where the screens' copies are, so none is left pointing at one that's gone.
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        try? modelContext.delete(model: Chunk.self, where: #Predicate { $0.end < cutoff })
        try? modelContext.save()
    }

    /// Audio that's no longer needed goes: anything kept for a second hearing for more than a
    /// day, a whole-conversation file left by a second hearing that was cut short, and
    /// recordings nothing refers to any more.
    private func sweepAudio() {
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
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let path = dir.appendingPathComponent(name).path
            let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
            // A recording still being made isn't in the database yet: only ones well finished go.
            if name.hasPrefix("whole_") || (!referenced.contains(path) && modified < tenMinutesAgo) {
                try? fm.removeItem(atPath: path)
            }
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
        let cal = Calendar.current
        func secondOfDay(_ d: Date) -> Int { let x = cal.dateComponents([.hour, .minute, .second], from: d); return x.hour! * 3600 + x.minute! * 60 + x.second! }
        let from = secondOfDay(thread.start), to = secondOfDay(thread.end) + 1
        func at(_ line: Substring) -> Int? {
            guard line.count > 9, line.hasPrefix("["), let h = Int(line.dropFirst(1).prefix(2)), let m = Int(line.dropFirst(4).prefix(2)),
                  let s = Int(line.dropFirst(7).prefix(2)) else { return nil }
            return h * 3600 + m * 60 + s
        }
        // A line covers everything until the next one starts, so a topic that began part-way
        // through a long line includes that line.
        let lines = c.transcript.split(separator: "\n")
        let starts = lines.map(at)
        var kept: [Substring] = []
        for (i, line) in lines.enumerated() {
            guard let t = starts[i] else { continue }
            let next = starts[(i + 1)...].compactMap { $0 }.first ?? Int.max
            if t < to && next > from { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    /// What the AI needs for any other question: the day's notes, the conversation that best
    /// matches it (by meaning as well as words), the parts of it that matter most, and what's
    /// known that bears on it.
    func notes(for question: String, focus: UUID?) -> (notes: [(label: String, title: String?, summary: String?)], best: (label: String, transcript: String)?, background: String, used: [UUID]) {
        let all = (try? modelContext.fetch(FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.start, order: .reverse)]))) ?? []
        let pool = focus.map { id in all.filter { $0.id == id } } ?? Array(all.prefix(40))
        let keys = Prompts.keywords(question)
        let asked = Meaning.vector(question)
        func rank(_ c: Conversation) -> Double {
            var meaning = 0.0
            if let asked, let v = Meaning.vector([c.title, c.summary, c.memory.text()].compactMap { $0 }.joined(separator: ". ")) {
                meaning = Meaning.similarity(asked, v)
            }
            return meaning * 10 + min(score(c, keys), 15)
        }
        let best = pool.map { ($0, rank($0)) }.max { $0.1 < $1.1 }?.0
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
        unremembered[id] = nil
        toFollow.removeAll { $0.id == id }
        let optional: UUID? = id
        for chunk in (try? modelContext.fetch(FetchDescriptor<Chunk>(predicate: #Predicate { $0.conversationID == optional }))) ?? [] {
            if let path = chunk.path { try? FileManager.default.removeItem(atPath: path) }
        }
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
        unremembered = [:]
        try? modelContext.delete(model: Fact.self)
        Learned.forget()
        UserDefaults.standard.removeObject(forKey: "declinedNames")
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

    /// Whether finished conversations are heard again as a whole (needs the voice models).
    static var hearAgain: Bool { VoiceEngine.enabled && VoiceEngine.downloaded }
    /// Longer than this, a conversation's left as it was transcribed (memory and battery).
    static let hearAgainLimit = 20.0 * 60

    /// When a conversation's over, it's heard again as a whole: the voices told apart across all
    /// of it at once (steadier than recording by recording, where a short snippet can be put
    /// down to the wrong person), and the words transcribed with all the context around them.
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
        guard chunks.count >= 2, recordings.count == chunks.count, length <= Self.hearAgainLimit,
              recordings.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path) }) else { return }
        let before = c.transcript
        let started = Date()
        let url = Recorder.audioDirectory.appendingPathComponent("whole_\(id.uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let joined = Self.join(recordings, into: url) else { return }
        // Its own voice models, so recordings being made now aren't kept waiting behind it.
        async let heardVoices = withDeadline(60 + joined.length) { await VoiceEngine.whole.split(url) }
        let words = await withDeadline(30 + 1.5 * joined.length) { () -> [SpeakerAlign.Word]? in
            do { return try await SpeechEngine.shared.words(url) } catch {
                Log.error("Couldn't transcribe the whole conversation again", error)
                return nil
            }
        }
        let split = await heardVoices
        guard let words, !words.isEmpty, let split else {
            Log.info("Hearing the conversation again didn't finish, so it's kept as it was")
            return
        }
        guard let now = conversation(id), now.transcript == before, now.userEdited != true else {
            Log.info("The conversation changed while it was being heard again, so it's kept as it is")
            return
        }
        var heard: [Voiceprint] = []
        let labels = VoiceMatcher.label(split.voices, heard: &heard, known: knownVoices())
        let turns = split.turns.compactMap { t in labels[t.speaker].map { SpeakerAlign.Turn(start: t.start, end: t.end, speaker: $0) } }
        let said = SpeakerAlign.assign(words, turns: turns, fallback: turns.first?.speaker ?? Labels.numbered(1))
        let utterances = said.compactMap { s -> Utterance? in
            let text = TranscriptFormat.clean(s.text)
            return text.isEmpty ? nil : Utterance(start: joined.time(at: s.start), speaker: s.speaker, text: text)
        }
        let transcript = TranscriptFormat.lines(utterances)
        guard JoinedAudio.accept(old: before, new: transcript) else {
            Log.info("Heard the conversation again, but the result didn't look right, so it's kept as it was")
            return
        }
        let voicesBefore = Set(Labels.speakers(in: before)).count
        now.transcript = transcript
        now.voiceprints = heard
        try? modelContext.save()
        Log.info("Heard a \(Int(joined.length / 60)) min conversation again as a whole: \(Set(labels.values).count) voices (was \(voicesBefore)), \(String(format: "%.0f", Date().timeIntervalSince(started))) s")
        // Misheard words fixed again: the stretches with words the recogniser doubted.
        guard Brain.notReadyReason == nil else { return }
        let doubts = Doubts.of(words, limit: 60), protected = Doubts.protected(words)
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
        if let fresh = conversation(id) { await suggest(for: fresh, found: ruleActions(fresh)) }
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

    /// A named person called something else, everywhere.
    func renamePerson(_ id: UUID, to typed: String) {
        guard let p = (try? modelContext.fetch(FetchDescriptor<Person>(predicate: #Predicate { $0.id == id })))?.first,
              !p.isMe, let name = Labels.cleanName(typed), name != Labels.me, name != p.name else { return }
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

    /// Stops recognising someone. Transcripts keep the name they were given.
    func forgetPerson(_ id: UUID) {
        try? modelContext.delete(model: Person.self, where: #Predicate { $0.id == id })
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

    private func label(_ c: Conversation) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(c.start) ? "'Today' HH:mm" : "EEE d MMM HH:mm"
        let e = DateFormatter(); e.dateFormat = "HH:mm"
        return "\(f.string(from: c.start))–\(e.string(from: c.end))"
    }

    /// The conversation a recording carries on, if it's soon enough after the last one.
    private func openConversation(for chunk: Chunk) -> Conversation? {
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.end, order: .reverse)])
        d.fetchLimit = 1
        guard let latest = (try? modelContext.fetch(d))?.first, !latest.closed,
              chunk.start.timeIntervalSince(latest.end) <= Double(gapMinutes) * 60 else { return nil }
        return latest
    }

    private func attach(_ chunk: Chunk, text: String, to open: Conversation?) -> Conversation {
        if let open {
            open.transcript += "\n" + text
            open.end = max(open.end, chunk.end)
            return open
        }
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.end, order: .reverse)])
        d.fetchLimit = 1
        if let latest = (try? modelContext.fetch(d))?.first { latest.closed = true }
        let c = Conversation(start: chunk.start, end: chunk.end, transcript: text)
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
        await suggest(for: c, found: ruleActions(c))
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
        let facts = ((try? modelContext.fetch(FetchDescriptor<Fact>())) ?? []).map(\.text)
        let personal = await PersonalWords.words()
        let extra = Learned.fixes.map(\.meant) + KnownFacts.names(in: facts) + personal
        let words = Vocabulary.words(people: people, items: items, extra: extra, limit: 120)
        guard await SpeechEngine.shared.expectedWords() != words else { return }
        await SpeechEngine.shared.setVocabulary(words)
        await LiveTranscriber.shared.refreshVocabulary()
    }

    private func knownVoices() -> [KnownVoice] {
        ((try? modelContext.fetch(FetchDescriptor<Person>())) ?? []).map(\.voice)
    }

    private func ruleActions(_ c: Conversation) -> [ExtractedAction] {
        // Once WTF knows your voice, to-dos are what you said you'd do; until then, any line could be yours.
        ActionRules.ruleActions(ActionRules.candidateLines(c.transcript), conversationStart: c.start, title: c.title,
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
            summaryFailures[id, default: 0] += 1
            Log.error("Couldn't summarise a \(transcript.count)-character conversation (try \(summaryFailures[id]!))")
            if summaryFailures[id]! >= 3, let c = conversation(id) {
                c.title = "Conversation"
                c.summary = ""
                try? modelContext.save()
            }
            return
        }
        guard let c = conversation(id) else { return }
        c.title = written.title
        c.summary = written.points.map { "\u{2022} " + $0 }.joined(separator: "\n")
        try? modelContext.save()
        await learnFacts(from: id)
        guard let c = conversation(id) else { return }
        let lines = ActionRules.candidateLines(c.transcript)
        guard !lines.isEmpty else { return }
        let recent = Array(lines.suffix(60)), start = c.start
        let notesOnly = Prompts.background(memory: c.memory, facts: [])
        guard let found = await withDeadline(60, { await Log.attempt("List items", { try await Brain.actions(lines: recent, start: start, background: notesOnly) }) }) else {
            Log.error("Couldn't find list items in a conversation")
            return
        }
        guard let c = conversation(id) else { return }
        let fromModel = ActionRules.fromModel(
            buy: found.buy, todo: found.todo,
            events: found.appointments.map { ($0.what, $0.when, $0.place, $0.booked) }, conversationStart: c.start, lines: recent)
        await suggest(for: c, found: ActionRules.merge(fromModel, ruleActions(c)))
    }

    /// Suggests what's new: not on the list already, and not already suggested from this conversation.
    private func suggest(for c: Conversation, found: [ExtractedAction]) async {
        guard !found.isEmpty else { return }
        let cid: UUID? = c.id
        let open = (try? modelContext.fetch(FetchDescriptor<ActionItem>(predicate: #Predicate { $0.status == "suggested" || $0.status == "accepted" }))) ?? []
        let mine = (try? modelContext.fetch(FetchDescriptor<ActionItem>(predicate: #Predicate { $0.conversationID == cid }))) ?? []
        let known = open + mine
        var fresh: [ExtractedAction] = []
        for a in found where !known.contains(where: { $0.type == a.type.rawValue && ($0.title.lowercased() == a.title.lowercased() || ActionRules.similar($0.title, a.title)) })
            && !fresh.contains(where: { $0.type == a.type && $0.title.lowercased() == a.title.lowercased() }) {
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
        for a in fresh {
            let heard = a.source.map { Self.heard($0, about: a, on: c.start) }
            let item = ActionItem(type: a.type.rawValue, title: a.title, start: a.resolved?.start(),
                                  allDay: a.resolved?.allDay ?? false, place: a.place, quote: heard?.quote ?? a.whenText, conversationID: cid)
            item.heardAt = heard?.at
            item.note = a.note
            modelContext.insert(item)
        }
        try? modelContext.save()
        guard !fresh.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "WTF heard \(fresh.count) thing\(fresh.count == 1 ? "" : "s") to act on"
        content.body = fresh.prefix(3).map(\.title).joined(separator: ", ")
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
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

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

/// A step that didn't finish in time.
struct StepTimedOut: LocalizedError {
    var what: String
    var errorDescription: String? { "Gave up \(what): it took too long" }
}
