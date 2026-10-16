import Foundation

/// Waits for [op] at most [seconds], then gives up (nil). Unlike a task group, it really does stop
/// waiting: the work may carry on in the background, but whatever it returns late is dropped. For
/// anything that can stall (Apple's speech and AI frameworks, model loading), so one stuck step
/// can't freeze everything behind it. If the task waiting is cancelled (Stop in Ask), it stops
/// waiting straight away too, and the work is told to stop.
func withDeadline<T>(_ seconds: Double, _ op: @escaping @Sendable () async -> T?) async -> T? {
    let race = Race<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            race.start(done, seconds: seconds, op)
        }
    } onCancel: {
        race.finish(nil, givingUp: true)
    }
}

/// The work against the clock (and a cancel): exactly one of them answers.
private final class Race<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done: CheckedContinuation<T?, Never>?
    private var finished = false
    private var work: Task<Void, Never>?
    private var clock: Task<Void, Never>?

    func start(_ done: CheckedContinuation<T?, Never>, seconds: Double, _ op: @escaping @Sendable () async -> T?) {
        lock.lock()
        // Cancelled before it began.
        if finished {
            lock.unlock()
            done.resume(returning: nil)
            return
        }
        self.done = done
        work = Task {
            let value = await op()
            self.finish(value, givingUp: false)
        }
        clock = Task {
            try? await Task.sleep(for: .seconds(seconds))
            self.finish(nil, givingUp: true)
        }
        lock.unlock()
    }

    /// The first to call it answers; [givingUp]: the time's up or the wait was cancelled, so the work is cancelled.
    func finish(_ value: T?, givingUp: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let done = self.done, work = self.work, clock = self.clock
        self.done = nil
        lock.unlock()
        clock?.cancel()
        if givingUp { work?.cancel() }
        done?.resume(returning: value)
    }
}
