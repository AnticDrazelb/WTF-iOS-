import FluidAudio
import Foundation
import WTFCore

/// Settings › Better Accuracy: NVIDIA's Parakeet TDT v2 speech model (English), run on the
/// Neural Engine by FluidAudio. An optional download (about 440 MB), once.
///
/// In independent tests it gets fewer words wrong than Apple's recogniser, most of all with
/// background noise; but it only works on finished audio, so Apple's still transcribes as you
/// speak. When a conversation's over, it's heard again as a whole (Pipeline.secondPass), and
/// that's where this comes in: the summary, the list items and the facts are worked out from
/// its transcript. Anything that goes wrong falls back to Apple's.
actor Parakeet {
    static let shared = Parakeet()

    /// The switch in Settings.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "parakeet") }
    /// The model's on the phone.
    static var downloaded: Bool { UserDefaults.standard.bool(forKey: "parakeetDownloaded") }
    /// English only (that's the model): in any other language Apple's is used.
    static var suitable: Bool { Locale.current.language.languageCode == .english }
    /// It's switched on, downloaded and suits the language.
    static var inUse: Bool { enabled && downloaded && suitable }

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    /// Downloads the model the first time (reporting how far it's got, 0–1), then loads it.
    func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard manager == nil else { return }
        // One at a time: a second ask (Settings, while a conversation's being heard again) waits.
        if let loading {
            _ = try await loading.value
            return
        }
        let job = Task { () throws -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(version: .v2, progressHandler: { p in progress?(p.fractionCompleted) })
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            return m
        }
        loading = job
        defer { loading = nil }
        do {
            manager = try await job.value
        } catch {
            Log.error("Better Accuracy model didn't load", error)
            throw error
        }
        Self.excludeFromBackup()
        UserDefaults.standard.set(true, forKey: "parakeetDownloaded")
        Log.info("Better Accuracy model ready")
    }

    /// The words in a recording (16 kHz), each with when it was said (seconds from the start) and
    /// how sure the model was. The model's let go of afterwards: it's large, and WTF runs all day.
    func words(_ url: URL) async throws -> [SpeakerAlign.Word] {
        try await prepare()
        guard let manager else { throw NotLoaded() }
        defer { unload() }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(url, decoderState: &state)
        return Self.words(from: result.tokenTimings ?? [])
    }

    /// Switched off in Settings: the download goes, to give the space back.
    func remove() async {
        unload()
        try? FileManager.default.removeItem(at: AsrModels.defaultCacheDirectory(for: .v2))
        UserDefaults.standard.set(false, forKey: "parakeetDownloaded")
        Log.info("Better Accuracy model removed")
    }

    /// Lets go of the model (it's loaded again when a conversation needs it).
    func unload() {
        let m = manager
        manager = nil
        Task { await m?.cleanup() }
    }

    struct NotLoaded: LocalizedError {
        var errorDescription: String? { "The Better Accuracy model isn't loaded" }
    }

    /// Its pieces of words joined into words: a piece starting with "▁" (or a space) starts a new
    /// one. A word's as sure as its least sure piece.
    static func words(from tokens: [TokenTiming]) -> [SpeakerAlign.Word] {
        var out: [SpeakerAlign.Word] = []
        for t in tokens {
            guard !t.token.isEmpty, t.token != "<blank>", t.token != "<pad>" else { continue }
            let starts = t.token.hasPrefix("\u{2581}") || t.token.hasPrefix(" ")
            let piece = starts ? String(t.token.drop(while: { $0 == "\u{2581}" || $0 == " " })) : t.token
            if starts || out.isEmpty {
                guard !piece.isEmpty else { continue }
                out.append(SpeakerAlign.Word(start: t.startTime, end: t.endTime, text: piece, confidence: Double(t.confidence)))
            } else {
                out[out.count - 1].text += piece
                out[out.count - 1].end = t.endTime
                out[out.count - 1].confidence = min(out[out.count - 1].confidence ?? 1, Double(t.confidence))
            }
        }
        return out
    }

    /// The model stays on this iPhone: not in iCloud or computer backups.
    private static func excludeFromBackup() {
        var dir = AsrModels.defaultCacheDirectory(for: .v2)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }
}
