import Foundation

/// Who listens on a local TCP port, for aka's check and `HostApps`.
///
/// lsof ran with no timeout on every refresh, even with nothing on the port,
/// so a stuck lsof froze Refresh and Check again (r3 bdfd). Now a quick
/// connect comes first: nothing answering means no lsof at all; otherwise
/// lsof gets `timeout` seconds and is killed after that.
enum ListeningPorts {
    static func pids(port: Int, timeout: TimeInterval = 3) -> [pid_t] {
        guard isOpen(port: port) else { return [] }
        return lsof(["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"], timeout: timeout)
            .split(whereSeparator: \.isNewline).compactMap { pid_t($0) }.filter { $0 > 0 }
    }

    /// True when something accepts a connection on 127.0.0.1 or ::1 within
    /// `wait` seconds.
    static func isOpen(port: Int, wait: TimeInterval = 0.3) -> Bool {
        guard (1...65535).contains(port) else { return false }
        return connects(family: AF_INET, port: port, wait: wait) || connects(family: AF_INET6, port: port, wait: wait)
    }

    private static func connects(family: Int32, port: Int, wait: TimeInterval) -> Bool {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let started: Int32
        if family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            started = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        } else {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            addr.sin6_addr = in6addr_loopback
            started = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        if started == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(wait * 1000)) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }

    /// lsof's output, or "" when it fails or runs past `timeout` (then killed).
    /// Output goes to a file, so a full pipe can never hold lsof up.
    static func lsof(_ arguments: [String], timeout: TimeInterval,
                     executable: String = "/usr/sbin/lsof") -> String {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-lsof-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil),
              let out = try? FileHandle(forWritingTo: outURL) else { return "" }
        defer {
            try? out.close()
            try? FileManager.default.removeItem(at: outURL)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        guard (try? task.run()) != nil else { return "" }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            if done.wait(timeout: .now() + 0.5) == .timedOut { kill(task.processIdentifier, SIGKILL) }
            return ""
        }
        return (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
    }
}
