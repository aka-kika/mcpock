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
        let process = Process()
        // Through env, so a bare command ("npx") is found on the agent's PATH.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [invocation.command] + invocation.arguments
        process.standardInput = serverInPipe
        process.standardOutput = serverOutPipe
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            fail("could not start \(invocation.command)", status: 127)
        }
        filterChildPID = process.processIdentifier
        // The agent stops the filter: the server stops with it.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig) { _ in
                if filterChildPID > 0 { kill(filterChildPID, SIGTERM) }
            }
        }

        // Server to agent, on its own thread.
        let serverDone = DispatchSemaphore(value: 0)
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

        // The server ended on its own: finish its output, then end too.
        process.terminationHandler = { finished in
            _ = serverDone.wait(timeout: .now() + 2)
            exit(finished.terminationReason == .exit ? finished.terminationStatus : 1)
        }

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
        if process.isRunning {
            process.terminate()
            usleep(300_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        _ = serverDone.wait(timeout: .now() + 1)
        exit(process.isRunning ? 1 : (process.terminationReason == .exit ? process.terminationStatus : 1))
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

/// The server's pid, for the signal handlers (which can capture nothing).
private var filterChildPID: pid_t = 0

/// The hidden tools, read again when the file's change date moves.
private final class HideFile: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var stamp: Date?
    private var loaded = false
    private var hidden: Set<String> = []

    init(path: String) {
        self.path = path
    }

    func current() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let changed = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        if !loaded || changed != stamp {
            hidden = ToolFilterCore.hidden(fromFileText: try? String(contentsOfFile: path, encoding: .utf8))
            stamp = changed
            loaded = true
        }
        return hidden
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
