import Foundation
import os

/// Spawns a process with pipes, guarantees termination (SIGTERM → SIGKILL), and never leaves orphans.
final class ProcessRunner: @unchecked Sendable {
    private struct State {
        var didTerminate = false
        /// The first `stderrHeadCap` bytes the server printed (where a Node
        /// stack trace puts its cause), then a rolling tail of the newest
        /// bytes. A server that floods stderr can't grow memory past about
        /// 1 MB (Argon 2026-10-16 #4).
        var stderrData = Data()
        var stderrTailData = Data()
        var stderrDropped = false
        /// Raw stdout, kept only for one-shot commands (the headers helper).
        var rawStdout = Data()
        var messageBuffer = MCPMessageBuffer()
        var messageQueue: [Data] = []
        // Keyed by id so a cancelled read can resume & remove exactly its own waiter.
        var pendingContinuations: [(id: UInt64, cont: CheckedContinuation<Data, Error>)] = []
        var nextContinuationID: UInt64 = 0
        var closed = false
        /// A framing error that arrived while no read was waiting. Kept for the
        /// next read, which fails at once instead of waiting out the timeout
        /// (review, 2026-10-14). The stream can't recover from one, so it stays.
        var framingError: Error?
    }

    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Set by the stderr reader at EOF, so a failure reason can include the tail
    /// of what the server printed rather than racing it.
    private let stderrFinished = OSAllocatedUnfairLock(initialState: false)
    private let stdoutFinished = OSAllocatedUnfairLock(initialState: false)
    /// Only a one-shot command (the headers helper) keeps its raw stdout; a
    /// server probe never does, so it doesn't hold a copy of every reply.
    private let capturesRawStdout: Bool
    /// The root's start time. `Process` starts each command in its own process
    /// group (group ID = root PID), so teardown can still find children a
    /// launcher left behind after it exited; only members that started after
    /// the root are ever signalled.
    private var rootStarted: timeval?

    /// Everything the process wrote to stdout so far (capped at 1 MB).
    var rawStdout: Data { state.withLock { $0.rawStdout } }

    /// True once the stdout reader hit EOF: every byte has been delivered.
    var stdoutDidFinish: Bool { stdoutFinished.withLock { $0 } }

    var processIdentifier: Int32 {
        process.processIdentifier
    }

    var isRunning: Bool {
        process.isRunning
    }

    init(
        command: String, args: [String], env: [String: String], workingDirectory: String? = nil,
        capturesRawStdout: Bool = false
    ) throws {
        self.capturesRawStdout = capturesRawStdout
        var processEnv = PathResolver.processEnvironment(configEnv: env)
        var resolved = PathResolver.resolveCommand(command, env: processEnv)
        // A relative path (`./.venv/bin/python`) is the project's, where the
        // agent starts it, not mcpock's own folder (review 2026-10-20, 542f).
        if resolved.contains("/"), !resolved.hasPrefix("/"),
           let workingDirectory, ConfigDiscovery.isExistingFolder(workingDirectory) {
            resolved = ((PathResolver.expandTilde(workingDirectory) as NSString)
                .appendingPathComponent(resolved) as NSString).standardizingPath
        }

        // A GUI app-bundle binary as the server command means an Electron-style
        // "run my script as Node" setup (MiniMax Code's `matrix`, etc.). Without
        // ELECTRON_RUN_AS_NODE=1 the binary boots the full app, which the probe
        // then kills — an open/crash loop every cycle. Inject it unless the
        // config sets the variable itself; non-Electron binaries ignore it.
        if PathResolver.isAppBundleExecutable(resolved), env["ELECTRON_RUN_AS_NODE"] == nil {
            processEnv["ELECTRON_RUN_AS_NODE"] = "1"
        }

        if !resolved.contains("/") {
            throw ProbeError.spawnFailed("Command not found: \(command)")
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: resolved) {
            throw ProbeError.spawnFailed("Command not found: \(resolved)")
        }
        if !fm.isExecutableFile(atPath: resolved) {
            throw ProbeError.spawnFailed("Not executable: \(resolved)")
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = args
        process.environment = processEnv
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // A project folder deleted since the config was read must not fail
        // the start with "doesn't exist" (Argon 2026-10-17 #3): discovery
        // drops such entries, this covers the gap until the next read.
        if let workingDirectory, ConfigDiscovery.isExistingFolder(workingDirectory) {
            process.currentDirectoryURL = URL(fileURLWithPath: PathResolver.expandTilde(workingDirectory))
        }

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        // Each pipe is drained by a dedicated thread doing blocking reads — NOT
        // `readabilityHandler`. The handler runs on a queue nobody can join, so a
        // chunk it had already pulled off the pipe could still be in flight when
        // the termination handler declared the stream closed and failed every
        // parked reader; the response then landed in the queue a moment later,
        // for nobody, and a healthy server probed as "No response" (seen once
        // under build load, 2026-09-12). A blocking reader parses each chunk
        // *before* it can observe EOF, so "closed" is only ever declared after
        // the last byte has been handled.
        Self.drain(stdoutPipe.fileHandleForReading, name: "mcpock.stdout",
                   sink: { [weak self] in self?.handleStdout($0) },
                   onEOF: { [weak self] in
                       self?.stdoutFinished.withLock { $0 = true }
                       self?.failPendingReaders()
                   })
        Self.drain(stderrPipe.fileHandleForReading, name: "mcpock.stderr",
                   sink: { [weak self] in self?.handleStderr($0) },
                   onEOF: { [weak self] in self?.stderrFinished.withLock { $0 = true } })

        // Taken before the spawn, so it is never later than the root's own
        // start: a launcher that forks its server and exits within a
        // millisecond has no start time left to read, and without this floor
        // its children were never found and kept running (Argon 2026-10-17 #5).
        var spawnTime = timeval()
        gettimeofday(&spawnTime, nil)
        do {
            try process.run()
        } catch {
            // Nothing will ever write: close our write ends so the readers see EOF.
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            throw ProbeError.spawnFailed(error.localizedDescription)
        }
        rootStarted = Self.startTime(of: process.processIdentifier) ?? spawnTime
    }

    /// Blocking read loop on its own thread; `sink` runs there, in order, and
    /// `onEOF` runs after the final chunk has been delivered.
    private static func drain(
        _ handle: FileHandle, name: String,
        sink: @escaping (Data) -> Void, onEOF: @escaping () -> Void
    ) {
        let thread = Thread {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                sink(chunk)
            }
            onEOF()
        }
        thread.name = name
        thread.start()
    }

    deinit {
        forceKill()
    }

    func write(_ data: Data) throws {
        let running = state.withLock { $0.didTerminate == false } && process.isRunning
        guard running else {
            throw ProbeError.spawnFailed("Process is not running")
        }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    /// Wait for the next complete MCP JSON message (framed or newline-delimited).
    func readMessage(timeout: Duration) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw ProbeError.noData }
                return try await self.waitForMessage()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProbeError.timeout(timeout)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Terminate gracefully, then SIGKILL if needed. Always called after a probe.
    /// Also reaps descendant processes (e.g. npx → node) so probes never leave orphans.
    func terminateAndReap(gracePeriod: Duration = .milliseconds(500)) async {
        // Claim termination atomically so a concurrent terminate/forceKill (or the
        // deinit fallback) can never signal the process tree a second time — after
        // the process is reaped its PID can be reused by an unrelated process.
        let alreadyDone = state.withLock { state -> Bool in
            if state.didTerminate { return true }
            state.didTerminate = true
            return false
        }
        if alreadyDone { return }

        // List the tree BEFORE closing stdin (1.9.0): a server that exits on
        // stdin EOF gets reparented children that `pgrep -P` can no longer find
        // from its PID. Each member keeps its start time, so a PID reused by an
        // unrelated process later is never signalled.
        let rootPIDBeforeClose = process.processIdentifier
        let tree = rootPIDBeforeClose > 0 && process.isRunning
            ? treeSnapshot(of: rootPIDBeforeClose) : []

        try? stdinPipe.fileHandleForWriting.close()

        // Only signal while the root is still alive: once it exits and is reaped,
        // its PID (and pgrep -P results for it) may describe an unrelated process.
        // A root that already exited cannot have findable descendants either —
        // orphaned children are reparented away from it.
        let rootPID = process.processIdentifier
        if rootPID > 0, process.isRunning {
            // SIGTERM the whole tree first
            signalProcessTree(root: rootPID, signal: SIGTERM)
            if process.isRunning {
                process.terminate()
            }

            let deadline = ContinuousClock.now + gracePeriod
            while process.isRunning && ContinuousClock.now < deadline {
                await Self.pause(.milliseconds(50))
            }

            if process.isRunning {
                signalProcessTree(root: rootPID, signal: SIGKILL)
                kill(rootPID, SIGKILL)
                let killDeadline = ContinuousClock.now + .milliseconds(500)
                while process.isRunning && ContinuousClock.now < killDeadline {
                    await Self.pause(.milliseconds(20))
                }
            }
        }

        // Whatever outlived the root (it exited on its own, or its children
        // ignored SIGTERM): SIGTERM, a short wait, then SIGKILL. The process
        // group catches children a launcher left behind when it exited before
        // teardown: reparented to launchd, `pgrep -P` can't find them, but they
        // keep the group (Argon 2026-10-16 #3). Killing them also ends the
        // stdout/stderr reader threads, which only stop at EOF.
        var survivors = Self.merged(tree, groupMembers(of: rootPIDBeforeClose))
            .filter { $0.isStillTheSameProcess }
        if !survivors.isEmpty {
            survivors.forEach { kill($0.pid, SIGTERM) }
            let survivorDeadline = ContinuousClock.now + .milliseconds(300)
            while !survivors.isEmpty && ContinuousClock.now < survivorDeadline {
                await Self.pause(.milliseconds(20))
                survivors = survivors.filter { $0.isStillTheSameProcess }
            }
            survivors.forEach { kill($0.pid, SIGKILL) }
        }

        // Give the stderr reader a moment to hit EOF so `stderrTail()` sees the
        // server's last words; bounded, because a surviving grandchild could hold
        // the pipe open.
        let stderrDeadline = ContinuousClock.now + .milliseconds(300)
        while !stderrFinished.withLock({ $0 }) && ContinuousClock.now < stderrDeadline {
            await Self.pause(.milliseconds(10))
        }

        failPendingReaders()
    }

    /// A short wait that still waits when the task is cancelled. Teardown runs
    /// under cancellation (Stop, a cancelled task group), where `Task.sleep`
    /// throws at once: its wait loops then spun at 100% CPU for up to 1.6 s
    /// per process (Argon 2026-10-17 #4).
    static func pause(_ duration: Duration) async {
        let (seconds, attoseconds) = duration.components
        let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) { done.resume() }
        }
    }

    func forceKill() {
        // Same atomic claim as terminateAndReap: if termination already ran, the
        // process is gone and its PID may belong to someone else — never re-kill it.
        let alreadyDone = state.withLock { state -> Bool in
            if state.didTerminate { return true }
            state.didTerminate = true
            return false
        }
        if alreadyDone { return }

        try? stdinPipe.fileHandleForWriting.close()
        let rootPID = process.processIdentifier
        if rootPID > 0, process.isRunning {
            signalProcessTree(root: rootPID, signal: SIGKILL)
            kill(rootPID, SIGKILL)
        }
        groupMembers(of: rootPID)
            .filter { $0.isStillTheSameProcess }
            .forEach { kill($0.pid, SIGKILL) }
        failPendingReaders()
    }

    /// Mark the stream closed and fail every parked reader. Shared by graceful
    /// termination, force-kill and the stdout reader's EOF.
    private func failPendingReaders() {
        let waiters = state.withLock { state -> [CheckedContinuation<Data, Error>] in
            state.closed = true
            let pending = state.pendingContinuations.map(\.cont)
            state.pendingContinuations.removeAll()
            return pending
        }
        for cont in waiters {
            cont.resume(throwing: ProbeError.noData)
        }
    }

    /// Depth-first SIG to all descendants, then the root.
    private func signalProcessTree(root: Int32, signal: Int32) {
        for child in descendantPIDs(of: root) {
            signalProcessTree(root: child, signal: signal)
        }
        kill(root, signal)
    }

    /// One process of a server's tree, pinned to its start time.
    private struct TreeMember {
        let pid: Int32
        let started: timeval

        /// True while this PID still belongs to the process that was listed.
        var isStillTheSameProcess: Bool {
            guard let now = ProcessRunner.startTime(of: pid) else { return false }
            return now.tv_sec == started.tv_sec && now.tv_usec == started.tv_usec
        }
    }

    /// Every descendant of `root` (not the root itself), depth first.
    private func treeSnapshot(of root: Int32) -> [TreeMember] {
        var members: [TreeMember] = []
        for child in descendantPIDs(of: root) {
            members += treeSnapshot(of: child)
            if let started = Self.startTime(of: child) {
                members.append(TreeMember(pid: child, started: started))
            }
        }
        return members
    }

    /// The live members of process group `pgid` that started no earlier than
    /// this runner's root, never mcpock itself. The start-time floor keeps a
    /// later, unrelated group that reused the ID out.
    private func groupMembers(of pgid: Int32) -> [TreeMember] {
        guard pgid > 0, let floor = rootStarted else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
        size = procs.count * stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        let me = getpid()
        return procs.prefix(size / stride).compactMap { info in
            let pid = info.kp_proc.p_pid
            guard pid > 0, pid != me, info.kp_eproc.e_pgid == pgid, info.kp_proc.p_stat != SZOMB else { return nil }
            let started = info.kp_proc.p_un.__p_starttime
            let afterRoot = started.tv_sec > floor.tv_sec
                || (started.tv_sec == floor.tv_sec && started.tv_usec >= floor.tv_usec)
            return afterRoot ? TreeMember(pid: pid, started: started) : nil
        }
    }

    /// `a` then the members of `b` not already in it (by PID).
    private static func merged(_ a: [TreeMember], _ b: [TreeMember]) -> [TreeMember] {
        let seen = Set(a.map(\.pid))
        return a + b.filter { !seen.contains($0.pid) }
    }

    /// A process's start time from the kernel, or nil when it is gone.
    private static func startTime(of pid: Int32) -> timeval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid
        else { return nil }
        // A zombie still has a start time but is already dead.
        if info.kp_proc.p_stat == SZOMB { return nil }
        return info.kp_proc.p_un.__p_starttime
    }

    private func descendantPIDs(of pid: Int32) -> [Int32] {
        // Use sysctl-free pgrep for simplicity and reliability on macOS.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(pid)"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
            .filter { $0 > 0 }
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    /// True when the process exited on its own (`exit()`), as opposed to being
    /// killed by a signal — `terminationStatus` is only an exit code in that case.
    var exitedNormally: Bool {
        process.terminationReason == .exit
    }

    /// What the server printed to stderr, its middle left out once over the
    /// cap. Decoded leniently: a cut can split a multi-byte character.
    var stderrString: String {
        state.withLock { state in
            let head = String(decoding: state.stderrData, as: UTF8.self)
            guard !state.stderrTailData.isEmpty || state.stderrDropped else { return head }
            let tail = String(decoding: state.stderrTailData, as: UTF8.self)
            return head + (state.stderrDropped ? "\n…\n" : "") + tail
        }
    }

    static let stderrHeadCap = 512 * 1024
    static let stderrTailCap = 512 * 1024

    /// The last few non-empty stderr lines, joined — for surfacing why a probe failed.
    func stderrTail(maxLines: Int = 2, maxLength: Int = 240) -> String {
        let tail = Self.nonEmptyLines(stderrString).suffix(maxLines).joined(separator: " ")
        return Self.truncate(tail, maxLength: maxLength)
    }

    /// A line that looks like the start of the real error: a `SomethingError:`
    /// or lowercase `error:`/`panic:` message, or — only when none of those
    /// appear — a Python `Traceback` header. Matched against the *whole*
    /// stderr history (not just the tail), because a Node stack trace puts
    /// its cause at the top and the tail is only `at ...` frames by then (the
    /// wigolo case: the tail showed `at async main (...index.js:146:7)`, the
    /// answer was the first line, `Error: Could not locate the bindings
    /// file`). Anchored to the start of a trimmed line and case-insensitive,
    /// so a path or word that merely contains "error" is never matched.
    /// Python's own `SomethingError:` line sits at the *bottom* of its
    /// traceback, already inside the tail — checked first here so a Python
    /// crash resolves to that same line, not to the "Traceback" header, and
    /// `stderrReason` below can then recognize it's already covered.
    func firstErrorLine(maxLength: Int = 240) -> String? {
        let lines = Self.nonEmptyLines(stderrString)
        guard !lines.isEmpty else { return nil }
        let line = lines.first(where: Self.looksLikeErrorCause)
            ?? lines.first(where: Self.looksLikeTracebackHeader)
        guard let line else { return nil }
        return Self.truncate(line, maxLength: maxLength)
    }

    /// The failure text to show: the first line that looks like the real
    /// error (if stderr has one the tail wouldn't otherwise show), then the
    /// tail — without repeating a first line the tail already contains (a
    /// Python traceback's cause is at the bottom, so it's already there).
    func stderrReason(maxTailLines: Int = 2, maxLength: Int = 240) -> String {
        let tail = stderrTail(maxLines: maxTailLines, maxLength: maxLength)
        guard let first = firstErrorLine(maxLength: maxLength), !tail.contains(first) else {
            return tail
        }
        return tail.isEmpty ? first : "\(first) — \(tail)"
    }

    private static let errorCauseRegex = try! NSRegularExpression(
        pattern: #"^(?:[A-Za-z][A-Za-z0-9_]*Error:|error:|panic:)"#,
        options: [.caseInsensitive]
    )

    private static let tracebackHeaderRegex = try! NSRegularExpression(
        pattern: #"^Traceback\b"#,
        options: [.caseInsensitive]
    )

    private static func looksLikeErrorCause(_ line: String) -> Bool {
        errorCauseRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func looksLikeTracebackHeader(_ line: String) -> Bool {
        tracebackHeaderRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func nonEmptyLines(_ text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func truncate(_ text: String, maxLength: Int) -> String {
        text.count > maxLength ? String(text.prefix(maxLength)) + "…" : text
    }

    // MARK: - Private

    private func handleStdout(_ chunk: Data) {
        let toResume: [(CheckedContinuation<Data, Error>, Result<Data, Error>)] = state.withLock { state in
            var pending: [(CheckedContinuation<Data, Error>, Result<Data, Error>)] = []
            if capturesRawStdout, state.rawStdout.count < 1_048_576 { state.rawStdout.append(chunk) }
            state.messageBuffer.append(chunk)
            do {
                while let msg = try state.messageBuffer.nextMessage() {
                    if state.pendingContinuations.isEmpty {
                        state.messageQueue.append(msg)
                    } else {
                        let cont = state.pendingContinuations.removeFirst().cont
                        pending.append((cont, .success(msg)))
                    }
                }
            } catch {
                if !state.pendingContinuations.isEmpty {
                    let cont = state.pendingContinuations.removeFirst().cont
                    pending.append((cont, .failure(error)))
                } else {
                    state.framingError = error
                }
            }
            return pending
        }

        for (cont, result) in toResume {
            cont.resume(with: result)
        }
    }

    private func handleStderr(_ chunk: Data) {
        state.withLock { state in
            var rest = chunk[...]
            let room = Self.stderrHeadCap - state.stderrData.count
            if room > 0 {
                state.stderrData.append(rest.prefix(room))
                rest = rest.dropFirst(room)
            }
            guard !rest.isEmpty else { return }
            state.stderrTailData.append(rest)
            // Trim only past twice the cap, so a flood costs one copy per
            // ~512 KB instead of one per chunk.
            if state.stderrTailData.count > 2 * Self.stderrTailCap {
                state.stderrTailData = Data(state.stderrTailData.suffix(Self.stderrTailCap))
                state.stderrDropped = true
            }
        }
    }

    private func waitForMessage() async throws -> Data {
        let id = state.withLock { state -> UInt64 in
            state.nextContinuationID &+= 1
            return state.nextContinuationID
        }
        // Cancellation-aware: when the read's timeout task cancels this one, resume and
        // remove our continuation so the enclosing task group can unwind. Without this a
        // timed-out read leaves a parked continuation and the whole probe deadlocks.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let immediate: Result<Data, Error>? = state.withLock { state in
                    if !state.messageQueue.isEmpty {
                        return .success(state.messageQueue.removeFirst())
                    }
                    if let error = state.framingError {
                        return .failure(error)
                    }
                    if state.closed {
                        return .failure(ProbeError.noData)
                    }
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    state.pendingContinuations.append((id, cont))
                    return nil
                }
                if let immediate {
                    cont.resume(with: immediate)
                }
            }
        } onCancel: {
            let cont = state.withLock { state -> CheckedContinuation<Data, Error>? in
                guard let idx = state.pendingContinuations.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return state.pendingContinuations.remove(at: idx).cont
            }
            cont?.resume(throwing: CancellationError())
        }
    }
}
