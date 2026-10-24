import XCTest
@testable import mcpock

/// r3 bdfd: no lsof when nothing listens, and a stuck one is stopped.
final class ListeningPortsTests: XCTestCase {
    func testClosedPortSkipsLsof() {
        let start = Date()
        XCTAssertEqual(ListeningPorts.pids(port: 1), [])
        XCTAssertFalse(ListeningPorts.isOpen(port: 0))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testOpenPortIsSeen() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(listen(fd, 1), 0)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        XCTAssertTrue(ListeningPorts.isOpen(port: Int(UInt16(bigEndian: bound.sin_port))))
    }

    func testStuckLsofIsKilled() {
        let start = Date()
        XCTAssertEqual(ListeningPorts.lsof(["30"], timeout: 0.3, executable: "/bin/sleep"), "")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
