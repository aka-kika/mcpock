import Foundation

/// `mcpock-mcp filter --hide-file <path> -- <command> <args…>`: the tool
/// filter (22 Nov). Starts the real server, passes every line both ways as
/// it is, and takes the hidden tools out of the server's tool list
/// (`ToolFilterCore`). It adds nothing and keeps nothing: no log, no network,
/// no file but the hide file it reads.
///
/// - The server gets this process's environment and folder, which are the
///   ones the agent gave the entry, so it starts exactly as it did unfiltered.
/// - The hide file is read again whenever it changes, so a tool turned off
///   in mcpock is gone from the next tool list without a restart.
/// - When either side ends, so does the other; the exit status is the server's.
enum FilterProxy {
    static func run(_ arguments: [String]) -> Never {
        guard let invocation = ToolFilterCore.invocation(arguments: arguments) else {
            fail("usage: mcpock-mcp filter --hide-file <path> -- <command> [arguments]", status: 64)
        }
        signal(SIGPIPE, SIG_IGN)

        let hide = HideFile(path: invocation.hideFile)
        let output = LockedHandle(FileHandle.standardOutput)
        let serverInPipe = Pipe()
        let serverOutPipe = Pipe()
        let serverDone = DispatchSemaphore(value: 0)
        let process = Process()
        // Started directly, by its full path: `/usr/bin/env` would read a
        // path with "=" in it as a variable (review 22 Nov).
        guard let executable = resolve(invocation.command) else {
            fail("could not find \(invocation.command)", status: 127)
        }
        process.executableURL = executable
        process.arguments = invocation.arguments
        process.standardInput = serverInPipe
        process.standardOutput = serverOutPipe
        process.standardError = FileHandle.standardError
        // Set before it starts: a server that exits at once is still seen.
        process.terminationHandler = { finished in
            _ = serverDone.wait(timeout: .now() + 2)
            exit(finished.terminationReason == .exit ? finished.terminationStatus : 1)
        }
        do {
            try process.run()
        } catch {
            fail("could not start \(invocation.command)", status: 127)
        }
        let child = process.processIdentifier
        // The agent stops the filter: the server stops with it, and whatever
        // the server started (`npx` and `uvx` run the real server as their
        // own child). The child leads its own process group, so the whole
        // group is signalled, then forced after a short wait.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                stopGroup(child)
                exit(128 + sig)
            }
            source.resume()
            filterSignalSources.append(source)
        }

        // Server to agent, on its own thread.
        let reader = Thread {
            var splitter = FilterLineSplitter()
            let handle = serverOutPipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                for line in splitter.feed(chunk) {
                    output.writeLine(filtered(line, hidden: hide.current()))
                }
            }
            if let rest = splitter.finish() { output.writeLine(filtered(rest, hidden: hide.current())) }
            serverDone.signal()
        }
        reader.stackSize = 1 << 20
        reader.start()

        // Agent to server, here.
        let serverInput = serverInPipe.fileHandleForWriting
        var splitter = FilterLineSplitter()
        let input = FileHandle.standardInput
        func pass(_ line: Data) {
            let hidden = hide.current()
            if !hidden.isEmpty {
                switch ToolFilterCore.fromClient(String(decoding: line, as: UTF8.self), hidden: hidden) {
                case .forward: break
                case .answer(let reply):
                    output.writeLine(Data(reply.utf8))
                    return
                case .drop: return
                }
            }
            try? serverInput.write(contentsOf: line + Data([0x0A]))
        }
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            splitter.feed(chunk).forEach(pass)
        }
        if let rest = splitter.finish() { pass(rest) }

        // The agent closed its side: let the server see the end and leave.
        try? serverInput.close()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { stopGroup(child) }
        _ = serverDone.wait(timeout: .now() + 1)
        exit(process.isRunning ? 1 : (process.terminationReason == .exit ? process.terminationStatus : 1))
    }

    /// SIGTERM to the server's whole process group, SIGKILL to what is left
    /// after a second and a half. Falls back to the one process when it
    /// leads no group.
    private static func stopGroup(_ pid: pid_t) {
        guard pid > 0 else { return }
        if kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
        var waited = 0
        while waited < 30, kill(-pid, 0) == 0 || kill(pid, 0) == 0 {
            usleep(50_000)
            waited += 1
        }
        if kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
    }

    /// The command's executable: a path as it is (a relative one from this
    /// folder), a bare name looked up on PATH like a shell would.
    private static func resolve(_ command: String) -> URL? {
        let fm = FileManager.default
        if command.contains("/") {
            let url = URL(fileURLWithPath: command, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)).standardizedFileURL
            return fm.isExecutableFile(atPath: url.path) ? url : nil
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for folder in path.split(separator: ":") where !folder.isEmpty {
            let candidate = URL(fileURLWithPath: String(folder)).appendingPathComponent(command)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// One server line, filtered only when something is hidden.
    private static func filtered(_ line: Data, hidden: Set<String>) -> Data {
        guard !hidden.isEmpty else { return line }
        let text = String(decoding: line, as: UTF8.self)
        let result = ToolFilterCore.fromServer(text, hidden: hidden)
        return result == text ? line : Data(result.utf8)
    }

    private static func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data("mcpock-mcp filter: \(message)\n".utf8))
        exit(status)
    }
}

/// Kept for the life of the process, or the signals would go unheard.
private var filterSignalSources: [DispatchSourceSignal] = []

/// The hidden tools, read again when the file's change date moves. A file
/// that goes missing or breaks keeps the last good list (`HideList`).
private final class HideFile: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var stamp: Date?
    private var loaded = false
    private var list = ToolFilterCore.HideList()

    init(path: String) {
        self.path = path
    }

    func current() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let changed = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        if !loaded || changed != stamp {
            list.update(fileText: try? String(contentsOfFile: path, encoding: .utf8))
            stamp = changed
            loaded = true
        }
        return list.names
    }
}

/// Whole lines only, one writer at a time: the server's lines and the
/// filter's own answers come from two threads.
private final class LockedHandle: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func writeLine(_ line: Data) {
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: line + Data([0x0A]))
    }
}
