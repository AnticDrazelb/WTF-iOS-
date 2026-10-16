import AVFoundation
import CoreMedia
import Speech
import WTFCore

/// On-device transcription with Apple's SpeechAnalyzer (iOS 26): free, offline, and the speech
/// model is shared with the system rather than downloaded into the app.
///
/// Apple's newer transcriber (SpeechTranscriber, made for long conversation) needs newer
/// hardware than iOS 26 does: on iPhones without it (the iPhone 11s and the second SE, by
/// developers' reports) WTF uses the dictation one instead (DictationTranscriber, the model
/// behind the keyboard's microphone). Same calls, same word timings; a little less accurate on
/// long talk. Everything else (the analyzer, the vocabulary, the downloads) is shared.
actor SpeechEngine {
    static let shared = SpeechEngine()

    private var locale: Locale?

    /// This iPhone can't run SpeechTranscriber, so the dictation transcriber is used (see above).
    nonisolated static var usesDictation: Bool { !SpeechTranscriber.isAvailable }

    /// Which recogniser, for Settings and Diagnostics.
    nonisolated static var recogniserName: String { usesDictation ? "dictation model (this iPhone can't run the speech model)" : "speech model" }

    private func transcriberLocale() async -> Locale {
        if let locale { return locale }
        let equivalent: Locale?
        if Self.usesDictation {
            equivalent = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current)
        } else {
            equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        }
        let found = equivalent ?? Locale(identifier: "en-US")
        locale = found
        return found
    }

    /// [live]: also reports words before they're final, for transcribing as you speak. Otherwise
    /// (a whole recording or conversation) its runner-up readings too, for fixing misheard words;
    /// live, all day, they'd cost more battery than they're worth.
    func makeTranscriber(live: Bool = false) async -> any SpeechModule {
        let locale = await transcriberLocale()
        if Self.usesDictation {
            // Far field: the iPhone's usually on a table or in a pocket, not held to the mouth.
            // Punctuation asked for: unlike SpeechTranscriber, it leaves it out otherwise.
            return DictationTranscriber(locale: locale, contentHints: [.farField], transcriptionOptions: [.punctuation],
                                        reportingOptions: live ? [.volatileResults] : [.alternativeTranscriptions],
                                        attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        }
        return SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                 reportingOptions: live ? [.volatileResults] : [.alternativeTranscriptions],
                                 attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    /// What a transcriber hears, whichever kind it is: the words of each result, whether they're
    /// final, and the time (seconds into the audio) up to which everything is final.
    struct Heard: Sendable {
        var words: [SpeakerAlign.Word]
        var isFinal: Bool
        var finalThrough: Double
    }

    static func results(of transcriber: any SpeechModule) -> AsyncThrowingStream<Heard, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let speech = transcriber as? SpeechTranscriber {
                        for try await r in speech.results {
                            continuation.yield(Heard(words: timedWords(r.text, alternatives: r.alternatives, range: r.range),
                                                     isFinal: r.isFinal, finalThrough: r.resultsFinalizationTime.seconds))
                        }
                    } else if let dictation = transcriber as? DictationTranscriber {
                        for try await r in dictation.results {
                            continuation.yield(Heard(words: timedWords(r.text, alternatives: r.alternatives, range: r.range),
                                                     isFinal: r.isFinal, finalThrough: r.resultsFinalizationTime.seconds))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Words it should expect: people you've named, shops, things on your list.
    private var vocabulary: [String] = []

    func setVocabulary(_ words: [String]) { vocabulary = words }

    /// The words it's been told to expect, for the AI that fixes misheard words.
    func expectedWords() -> [String] { vocabulary }

    func applyVocabulary(to analyzer: SpeechAnalyzer) async {
        guard !vocabulary.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary
        do { try await analyzer.setContext(context) } catch { Log.error("Couldn't give the recogniser its \(vocabulary.count) words", error) }
    }

    /// A result's words, each with when it was said (seconds into the audio), how sure the
    /// recogniser was of it, and what else it might have been.
    static func timedWords(_ text: AttributedString, alternatives: [AttributedString], range: CMTimeRange) -> [SpeakerAlign.Word] {
        var timed: [SpeakerAlign.Word] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            guard !piece.isEmpty else { continue }
            if let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] {
                let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self].map { Double($0) }
                timed.append(SpeakerAlign.Word(start: range.start.seconds, end: range.end.seconds, text: piece, confidence: confidence))
            } else if !timed.isEmpty {
                timed[timed.count - 1].text += piece // punctuation and spaces belong to the word before
            } else {
                timed.append(SpeakerAlign.Word(start: range.start.seconds, end: range.start.seconds, text: piece))
            }
        }
        // The recogniser's runner-up readings of the phrase, lined up with the words they'd replace.
        if alternatives.count > 1, !timed.isEmpty {
            let others = alternatives.dropFirst().prefix(3).map { alt in
                String(alt.characters).split(whereSeparator: \.isWhitespace).map(String.init)
            }
            for (i, readings) in Doubts.alternatives(top: timed.map(\.text), others: Array(others)) where i < timed.count {
                timed[i].alternatives = readings
            }
        }
        // No word timings: the phrase as one.
        if timed.isEmpty {
            let whole = String(text.characters)
            if !whole.trimmingCharacters(in: .whitespaces).isEmpty {
                timed = [SpeakerAlign.Word(start: range.start.seconds, end: range.end.seconds, text: whole)]
            }
        }
        return timed
    }

    /// Whether the speech model for this language is on the phone.
    func isReady() async -> Bool {
        let t = await makeTranscriber()
        return await AssetInventory.status(forModules: [t]) == .installed
    }

    /// Fetches the speech model if the phone doesn't have it yet (Apple hosts it; it's shared with dictation).
    func prepare() async throws {
        let locale = await transcriberLocale()
        let t = await makeTranscriber()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            Log.info("Downloading the speech model for \(locale.identifier)")
            try await request.downloadAndInstall()
            Log.info("Speech model for \(locale.identifier) installed")
        } else {
            Log.info("Speech model for \(locale.identifier): nothing to download (status \(await AssetInventory.status(forModules: [t])))")
        }
    }

    /// The language it transcribes, for Settings.
    func language() async -> String { await transcriberLocale().identifier }

    /// The words in a recording, each with when it was said (seconds from the start), so they can
    /// be lined up with who was speaking.
    func words(_ url: URL) async throws -> [SpeakerAlign.Word] {
        let transcriber = await makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        await applyVocabulary(to: analyzer)
        let collector = Task { () -> [SpeakerAlign.Word] in
            var out: [SpeakerAlign.Word] = []
            for try await heard in Self.results(of: transcriber) { out += heard.words }
            return out
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            // Nothing left waiting on a recogniser that won't finish (a bad file, or given up on).
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        return try await collector.value
    }
}
