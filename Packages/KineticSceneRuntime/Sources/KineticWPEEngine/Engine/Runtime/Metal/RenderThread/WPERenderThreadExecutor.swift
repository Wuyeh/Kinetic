import Foundation

/// `SerialExecutor` that runs actor jobs on a `WPERenderThread`; pairing an actor's
/// `unownedExecutor` with this makes its isolation domain *be* the render thread (SE-0392).
/// `@unchecked Sendable`: holds only an immutable reference to the (Sendable) render thread.
final class WPERenderThreadExecutor: SerialExecutor, @unchecked Sendable {

    private let thread: WPERenderThread

    init(thread: WPERenderThread) {
        self.thread = thread
    }

    // Kinetic (macOS 13): the UnownedJob requirement predates `ExecutorJob` (macOS 14).
    func enqueue(_ job: UnownedJob) {
        // A job that never runs traps the runtime, so consumption must be unconditional.
        let executor = asUnownedSerialExecutor()
        thread.perform {
            job.runSynchronously(on: executor)
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    func checkIsolated() {
        precondition(
            thread.isCurrent,
            "WPERenderThreadExecutor.checkIsolated: not on the render thread"
        )
    }
}
