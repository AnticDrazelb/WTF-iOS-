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
    /// The model's on the phone. The setting alone doesn't say so: settings come back from a
    /// backup and the model doesn't, and then it'd be downloaded unasked, over mobile data too,
    /// when a conversation's heard again. Put right here, so Settings offers the download again.
    static var downloaded: Bool {
        guard UserDefaults.standard.bool(forKey: "parakeetDownloaded") else { return false }
        guard FileManager.default.fileExists(atPath: AsrModels.defaultCacheDirectory(for: .v2).path) else {
            UserDefaults.standard.set(false, forKey: "parakeetDownloaded")
            return false
        }
        return true
    }
    /// English only (that's the model): in any other language Apple's is used. The language WTF
    /// transcribes in, if it's said ("transcribesEnglish"): that's English when the iPhone's
    /// language has no recogniser of its own. Otherwise the iPhone's own language, not
    /// Locale.current: WTF ships only in English, so that's always English.
    static var suitable: Bool {
        if let english = UserDefaults.standard.object(forKey: "transcribesEnglish") as? Bool { return english }
        return Locale(identifier: Locale.preferredLanguages.first ?? "en-US").language.languageCode == .english
    }
    /// It's switched on, downloaded and suits the language.
    static var inUse: Bool { enabled && downloaded && suitable }

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    /// Everyone waiting on the download, told how far it's got.
    private var watching = Watchers()
    /// One recording at a time: the model isn't made to be used by two at once, and each lets
    /// go of it when done (a transcription can outlast the wait for it).
    private var queue: Task<Void, Never>?
    private var transcribing = false

    /// Downloads the model the first time (reporting how far it's got, 0–1), then loads it.
    func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard manager == nil else { return }
        // One at a time: a second ask (Settings, while a conversation's being heard again) waits,
        // and is told how far it's got too.
        if let loading {
            if let progress { watching.add(progress) }
            let loaded = try await loading.value
            // The one loading it may not have carried on yet (which goes first isn't fixed): it's
            // ready either way, unless it was stopped.
            if manager == nil, !loading.isCancelled { manager = loaded }
            return
        }
        let watching = Watchers()
        if let progress { watching.add(progress) }
        self.watching = watching
        let job = Task { () throws -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(version: .v2, progressHandler: { p in watching.send(p) })
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            return m
        }
        loading = job
        // Only its own: a download stopped (remove) and started again has a newer one.
        defer { if loading == job { loading = nil } }
        let loaded: AsrManager
        do {
            loaded = try await job.value
        } catch {
            Log.error("Better Accuracy model didn't load", error)
            throw error
        }
        // Stopped (switched off) while it loaded, but it finished anyway: not kept.
        guard !job.isCancelled else {
            Task { await loaded.cleanup() }
            throw CancellationError()
        }
        manager = loaded
        Self.excludeFromBackup()
        UserDefaults.standard.set(true, forKey: "parakeetDownloaded")
        Log.info("Better Accuracy model ready")
    }

    /// The words in a recording (16 kHz), each with when it was said (seconds from the start) and
    /// how sure the model was. The model's let go of afterwards: it's large, and WTF runs all day.
    func words(_ url: URL) async throws -> [SpeakerAlign.Word] {
        let before = queue
        let job = Task { () throws -> [SpeakerAlign.Word] in
            await before?.value
            return try await self.wordsNow(url)
        }
        queue = Task { _ = try? await job.value }
        // Given up on (secondPass's deadline): told to stop, so the next isn't kept waiting.
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    private func wordsNow(_ url: URL) async throws -> [SpeakerAlign.Word] {
        // Switched off while this waited its turn: not downloaded again (Apple's is used).
        guard Self.enabled, Self.downloaded else { throw NotLoaded() }
        // Marked first, so Settings' unload can't let go of the model while this waits for it to load.
        transcribing = true
        defer {
            transcribing = false
            release()
        }
        try await prepare()
        guard let manager else { throw NotLoaded() }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(url, decoderState: &state)
        return Self.words(from: result.tokenTimings ?? [])
    }

    /// Switched off in Settings: the download goes, to give the space back.
    func remove() async {
        // The download going on is stopped and waited for, so it can't put files back once
        // they're deleted.
        let job = loading
        cancelLoading()
        _ = await job?.result
        await queue?.value
        // Switched on again meanwhile: it's wanted after all, and a new download may be under way
        // into the same place, so it's left alone.
        guard loading == nil, !Self.enabled else {
            Log.info("Better Accuracy switched on again while it was being removed; kept")
            return
        }
        release()
        try? FileManager.default.removeItem(at: AsrModels.defaultCacheDirectory(for: .v2))
        UserDefaults.standard.set(false, forKey: "parakeetDownloaded")
        Log.info("Better Accuracy model removed")
    }

    /// Lets go of the model (it's loaded again when a conversation needs it), unless a
    /// conversation's using it: it's let go of when that's done.
    func unload() {
        guard !transcribing else { return }
        release()
    }

    /// A download going on is stopped (FluidAudio has to notice the cancel for the transfer to stop).
    private func cancelLoading() {
        loading?.cancel()
        loading = nil
    }

    private func release() {
        let m = manager
        manager = nil
        Task { await m?.cleanup() }
    }

    /// How far the download's got, passed on to everyone waiting on it, the ones who asked later
    /// told where it's got to so far.
    ///
    /// FluidAudio reports each model file on its own, 0–0.5 downloading then 0.5–1 compiling, and
    /// starts again for the next. Everything's downloaded before the first compile, so that half
    /// is shown as the whole download, and from the first compile on it's 1 (Settings shows
    /// "Preparing…"), never going back.
    private final class Watchers: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [@Sendable (Double) -> Void] = []
        private var last: Double?
        private var preparing = false

        func add(_ handler: @escaping @Sendable (Double) -> Void) {
            lock.lock()
            handlers.append(handler)
            let last = last
            lock.unlock()
            if let last { handler(last) }
        }

        func send(_ progress: DownloadProgress) {
            lock.lock()
            if case .compiling = progress.phase { preparing = true }
            let fraction = preparing ? 1 : max(last ?? 0, min(1, progress.fractionCompleted / 0.5))
            last = fraction
            let all = handlers
            lock.unlock()
            all.forEach { $0(fraction) }
        }
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
