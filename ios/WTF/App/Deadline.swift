import Foundation

/// Waits for [op] at most [seconds], then gives up (nil). Unlike a task group, it really does stop
/// waiting: the work may carry on in the background, but whatever it returns late is dropped. For
/// anything that can stall (Apple's speech and AI frameworks, model loading), so one stuck step
/// can't freeze everything behind it.
func withDeadline<T>(_ seconds: Double, _ op: @escaping @Sendable () async -> T?) async -> T? {
    let gate = Gate()
    return await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
        let work = Task {
            let value = await op()
            if gate.first() { done.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if gate.first() {
                work.cancel()
                done.resume(returning: nil)
            }
        }
    }
}

/// Lets exactly one of two racers through.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    func first() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if opened { return false }
        opened = true
        return true
    }
}
