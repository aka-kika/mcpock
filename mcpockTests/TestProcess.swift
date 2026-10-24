import Foundation

extension Process {
    /// Stops a test's mock server without `waitUntilExit`, which can wait
    /// forever on a test thread when the exit was already seen (an
    /// SSEProbeTests run hung for 10 min on 2026-10-24). Polls up to 3 s,
    /// then SIGKILL.
    func stopForTest() {
        guard isRunning else { return }
        terminate()
        let deadline = Date().addingTimeInterval(3)
        while isRunning && Date() < deadline { usleep(20_000) }
        if isRunning { kill(processIdentifier, SIGKILL) }
    }
}
