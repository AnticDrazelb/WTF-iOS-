import Foundation
import SoundAnalysis
import WTFCore

/// Songs aren't conversation: a recording that's clearly music (the radio, the TV) isn't
/// transcribed, so lyrics don't end up in transcripts or lists. Apple's built-in sound
/// classifier does the listening; nothing to download.
enum MusicCheck {
    static func isSong(_ url: URL) async -> Bool {
        do {
            let analyzer = try SNAudioFileAnalyzer(url: url)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            let known = Set(request.knownClassifications)
            guard known.contains("music"), known.contains("speech") else { return false }
            let windows = Windows()
            try analyzer.add(request, withObserver: windows)
            let finished = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                analyzer.analyze { done.resume(returning: $0) }
            }
            return finished && MusicFilter.isSong(windows.all)
        } catch {
            Log.error("Couldn't check a recording for music", error)
            return false
        }
    }
}

/// The classifier's scores for each second or so of the recording.
private final class Windows: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [MusicFilter.Window] = []

    var all: [MusicFilter.Window] {
        lock.lock(); defer { lock.unlock() }
        return windows
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        func score(_ id: String) -> Double { r.classification(forIdentifier: id)?.confidence ?? 0 }
        let w = MusicFilter.Window(music: score("music"), singing: score("singing"), speech: score("speech"))
        lock.lock(); windows.append(w); lock.unlock()
    }
}
