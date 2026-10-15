import AVFoundation
import CoreMedia
import Speech
import WTFCore

/// On-device transcription with Apple's SpeechAnalyzer (iOS 26): free, offline, and the speech
/// model is shared with the system rather than downloaded into the app.
actor SpeechEngine {
    static let shared = SpeechEngine()

    private var locale: Locale?

    private func transcriberLocale() async -> Locale {
        if let locale { return locale }
        let found = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
        locale = found
        return found
    }

    /// [live]: also reports words before they're final, for transcribing as you speak. Otherwise
    /// (a whole recording or conversation) its runner-up readings too, for fixing misheard words;
    /// live, all day, they'd cost more battery than they're worth.
    func makeTranscriber(live: Bool = false) async -> SpeechTranscriber {
        SpeechTranscriber(locale: await transcriberLocale(), transcriptionOptions: [],
                          reportingOptions: live ? [.volatileResults] : [.alternativeTranscriptions],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
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
    static func timedWords(_ result: SpeechTranscriber.Result) -> [SpeakerAlign.Word] {
        let text = result.text
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
                timed.append(SpeakerAlign.Word(start: result.range.start.seconds, end: result.range.start.seconds, text: piece))
            }
        }
        // The recogniser's runner-up readings of the phrase, lined up with the words they'd replace.
        if result.alternatives.count > 1, !timed.isEmpty {
            let others = result.alternatives.dropFirst().prefix(3).map { alt in
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
                timed = [SpeakerAlign.Word(start: result.range.start.seconds, end: result.range.end.seconds, text: whole)]
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
            for try await result in transcriber.results { out += Self.timedWords(result) }
            return out
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
}
