import AVFoundation
import CoreMedia
import Speech
import WTFCore

/// Transcribes as you speak, so there's nothing to catch up on when you ask. The recorder feeds
/// it the speech it keeps (not the silence between), and the words are held with the time they
/// were said; when a recording closes, the pipeline takes its words from here and only has to
/// work out who said them. Anything it can't vouch for (it started late, or fell behind) is
/// transcribed from the file instead, as before.
final class LiveTranscriber: @unchecked Sendable {
    static let shared = LiveTranscriber()

    /// A word, placed by the recording it was heard in (its start) and where in it (seconds).
    struct TimedWord {
        var chunk: Date, start: Double, end: Double, text: String
        var confidence: Double?
        var alternatives: [String] = []
    }

    private static let rate = 16_000.0
    /// Between recordings the recogniser hears a short pause, so sentences don't run together.
    private static let joinSilence = 6_400 // 0.4 s

    private let lock = NSLock()
    // Everything below is guarded by [lock].
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    /// Samples fed so far, and which recording each stretch came from: at analyzer sample
    /// [sample], recording [chunk] was at its sample [offset]. Counted, not clocked, so exact.
    private var fed: Int64 = 0
    private var anchors: [(sample: Int64, chunk: Date, offset: Int)] = []
    /// Where each recording's fed audio ends, in analyzer samples.
    private var ends: [Date: Int64] = [:]
    private var words: [TimedWord] = []
    /// Words not final yet (the last second or two), for a live view.
    private var provisional: [TimedWord] = []
    /// Analyzer time (seconds) up to which results are final.
    private var finalThrough = 0.0
    /// When it started listening: recordings from before are transcribed from the file.
    private var since: Date?

    private let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var running: Bool { locked { analyzer != nil } }

    func start() async {
        guard !running, await SpeechEngine.shared.isReady() else { return }
        let transcriber = await SpeechEngine.shared.makeTranscriber(live: true)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await SpeechEngine.shared.applyVocabulary(to: analyzer)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let results = Task { [weak self] in
            do {
                for try await result in transcriber.results { self?.take(result) }
            } catch {
                Log.error("Live transcription stopped", error)
            }
        }
        locked {
            self.analyzer = analyzer
            self.input = continuation
            self.results = results
            self.format = format
            self.converter = format.flatMap { $0 == source ? nil : AVAudioConverter(from: source, to: $0) }
            fed = 0
            anchors = []
            ends = [:]
            words = []
            provisional = []
            finalThrough = 0
            since = Date()
        }
        Task { [weak self] in
            do { try await analyzer.start(inputSequence: stream) } catch {
                Log.error("Live transcription couldn't start", error)
                await self?.stop()
            }
        }
    }

    /// The words to expect have changed (a name, a correction): the running recogniser is told.
    func refreshVocabulary() async {
        guard let analyzer = locked({ analyzer }) else { return }
        await SpeechEngine.shared.applyVocabulary(to: analyzer)
    }

    func stop() async {
        let (analyzer, input, results) = locked { () -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?, Task<Void, Never>?) in
            defer {
                self.analyzer = nil; self.input = nil; self.results = nil; since = nil
            }
            return (self.analyzer, self.input, self.results)
        }
        input?.finish()
        await Log.attempt("Live transcription didn't finish cleanly") { try await analyzer?.finalizeAndFinishThroughEndOfInput() }
        results?.cancel()
    }

    /// Speech from the recorder (16 kHz mono): samples from recording [chunk], starting at its
    /// sample [offset]. Called on the recorder's queue.
    func feed(_ samples: [Float], chunk: Date, offset: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let input, !samples.isEmpty else { return }
        let last = anchors.last
        let sameChunk = last?.chunk == chunk
        let expected = last.map { $0.offset + Int(fed - $0.sample) }
        if !sameChunk || expected != offset {
            // A new recording: a short pause between, so its first words don't run into the last one's.
            if !sameChunk, fed > 0 {
                push([Float](repeating: 0, count: Self.joinSilence), to: input)
                fed += Int64(Self.joinSilence)
            }
            anchors.append((fed, chunk, offset))
            if anchors.count > 200 { anchors.removeFirst(anchors.count - 200) }
        }
        push(samples, to: input)
        fed += Int64(samples.count)
        ends[chunk] = fed
    }

    /// Half a second of silence after [chunk], so the recogniser knows its speech has stopped;
    /// only if nothing newer has been fed since (a recording that carries straight on does that).
    private func padSilence(after chunk: Date) {
        lock.lock(); defer { lock.unlock() }
        guard let input, let last = anchors.last, Self.same(last.chunk, chunk) else { return }
        push([Float](repeating: 0, count: 8_000), to: input)
        fed += 8_000
        anchors.append((fed, Date.distantPast, 0)) // the padding belongs to no recording
    }

    private func push(_ samples: [Float], to input: AsyncStream<AnalyzerInput>.Continuation) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        guard let converter, let format else {
            input.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / Self.rate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil { input.yield(AnalyzerInput(buffer: out)) }
    }

    /// The same recording (its start time, give or take the database's rounding).
    private static func same(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 0.001 }

    /// Analyzer seconds → which recording, and how far into it.
    private func place(_ seconds: Double) -> (chunk: Date, at: Double)? {
        let sample = Int64(seconds * Self.rate)
        guard let a = anchors.last(where: { $0.sample <= sample }) ?? anchors.first else { return nil }
        return (a.chunk, (Double(a.offset) + Double(sample - a.sample)) / Self.rate)
    }

    private func take(_ result: SpeechTranscriber.Result) {
        let timed = SpeechEngine.timedWords(result)
        lock.lock(); defer { lock.unlock() }
        let placed = timed.compactMap { w -> TimedWord? in
            guard let p = place(w.start), p.chunk != .distantPast else { return nil }
            return TimedWord(chunk: p.chunk, start: p.at, end: p.at + max(0, w.end - w.start), text: w.text,
                             confidence: w.confidence, alternatives: w.alternatives)
        }
        if result.isFinal {
            words += placed
            provisional = []
        } else {
            provisional = placed
        }
        finalThrough = max(finalThrough, result.resultsFinalizationTime.seconds)
    }

    /// The words of the recording that started at [from], in seconds from its start, once they're
    /// final; nil if it wasn't all heard live (so the file gets transcribed instead).
    func words(from: Date, to: Date) async -> [SpeakerAlign.Word]? {
        guard let (analyzer, target) = locked({ () -> (SpeechAnalyzer, Double)? in
            guard let analyzer, let since, since <= from.addingTimeInterval(0.5),
                  anchors.contains(where: { Self.same($0.chunk, from) && $0.offset == 0 }),
                  let end = ends.first(where: { Self.same($0.key, from) })?.value else { return nil }
            return (analyzer, Double(end) / Self.rate)
        }) else { return nil }
        // A moment of silence after the last word lets the recogniser settle on it (otherwise it can
        // wait for more speech that isn't coming), then ask for everything up to there to be final.
        // Not awaited: if it stalls, the deadline below gives up and the file is used instead.
        padSilence(after: from)
        Task { await Log.attempt("Live transcription couldn't finalise") { try await analyzer.finalize(through: CMTime(seconds: target, preferredTimescale: 16_000)) } }
        let deadline = Date().addingTimeInterval(3)
        while locked({ finalThrough }) < target - 0.05 {
            guard Date() < deadline else {
                Log.error("Live transcription fell behind; transcribing the recording from its file")
                return nil
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return locked {
            let mine = words.filter { Self.same($0.chunk, from) }
            words.removeAll { $0.chunk <= from.addingTimeInterval(0.001) }
            ends = ends.filter { $0.key > from.addingTimeInterval(0.001) }
            return mine.map { SpeakerAlign.Word(start: $0.start, end: $0.end, text: $0.text, confidence: $0.confidence, alternatives: $0.alternatives) }
        }
    }

    /// What's been said in the last [seconds], final or not: for the live view.
    func recentText(seconds: Double = 20) -> String {
        locked {
            let cutoff = Date().addingTimeInterval(-seconds)
            return SpeakerAlign.join((words + provisional).filter { $0.chunk.addingTimeInterval($0.end) >= cutoff }.map(\.text))
        }
    }
}
