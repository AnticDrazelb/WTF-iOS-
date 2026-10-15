import Foundation
import FluidAudio

/// Tells speech from everything else with a small neural speech detector (Silero, about 2 MB,
/// downloaded once), so quiet or distant voices are kept and fans, traffic and clatter aren't.
/// Loudness alone misses soft speech. The recorder asks it about every 30 ms of sound; it judges a
/// quarter of a second at a time, in the background. Until it's ready (or if it can't load), the
/// recorder goes by loudness as before.
final class SpeechGate: @unchecked Sendable {
    static let shared = SpeechGate()

    /// Speech starts a recording at this probability, and keeps it going down to the lower one.
    static let open: Float = 0.5
    static let stay: Float = 0.35
    /// Quieter than this (RMS) isn't worth asking about: it's silence.
    static let silence: Float = 0.0015

    private let lock = NSLock()
    // Guarded by [lock].
    private var probability: Float = 0
    private var updated = Date.distantPast
    private var ready = false
    private var window: [Float] = []
    /// Near-silence was skipped since the last window judged: the detector starts afresh.
    private var skipped = false
    private var input: AsyncStream<Window>.Continuation?

    private struct Window: Sendable {
        var samples: [Float]
        var fresh: Bool
    }
    private var worker: Task<Void, Never>?

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Whether it's working, for Diagnostics.
    var isReady: Bool { locked { ready } }

    /// Loads the model (downloading it the first time) and starts judging what it's given.
    func start() {
        let (stream, continuation) = AsyncStream<Window>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let begun = locked { () -> Bool in
            guard worker == nil else { return false }
            input = continuation
            return true
        }
        guard begun else { return }
        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                let manager = try await VadManager(config: VadConfig(defaultThreshold: SpeechGate.open))
                var state = await manager.makeStreamState()
                self?.locked { self?.ready = true }
                Log.info("Speech detector ready")
                var failures = 0
                for await window in stream {
                    if window.fresh { state = await manager.makeStreamState() }
                    do {
                        let result = try await manager.processStreamingChunk(window.samples, state: state)
                        state = result.state
                        self?.set(result.probability)
                        failures = 0
                    } catch {
                        // One bad moment isn't the end of it; many in a row, and loudness takes over.
                        failures += 1
                        state = await manager.makeStreamState()
                        if failures == 1 { Log.error("The speech detector stumbled", error) }
                        if failures >= 20 { throw error }
                    }
                }
            } catch {
                Log.error("The speech detector isn't available, so speech is told by loudness", error)
            }
            self?.locked {
                self?.ready = false
                self?.worker = nil
                self?.input = nil
            }
        }
        locked { worker = task }
    }

    private func set(_ p: Float) {
        locked {
            probability = p
            updated = Date()
        }
    }

    /// Sound as it's heard (16 kHz mono), from the recorder's queue.
    func feed(_ frame: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard ready, let input else { return }
        window += frame
        guard window.count >= VadManager.chunkSize else { return }
        let samples = Array(window.prefix(VadManager.chunkSize))
        window.removeFirst(VadManager.chunkSize)
        // Near-silence is silence: no need to wake the model for it.
        var sum: Float = 0
        for s in samples { sum += s * s }
        if (sum / Float(samples.count)).squareRoot() < Self.silence {
            probability = 0
            updated = Date()
            skipped = true
        } else {
            input.yield(Window(samples: samples, fresh: skipped))
            skipped = false
        }
    }

    /// Whether [frame] is speech, by the detector if it has a recent answer, else nil. [recording]:
    /// already keeping speech, so it takes a little less to carry on.
    func isSpeech(recording: Bool) -> Bool? {
        locked {
            guard ready, Date().timeIntervalSince(updated) < 1 else { return nil }
            return probability >= (recording ? Self.stay : Self.open)
        }
    }
}
