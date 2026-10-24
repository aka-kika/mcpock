import XCTest
@testable import mcpock

final class ProcessTreeTests: XCTestCase {
    private func entry(_ pid: Int32, _ parent: Int32) -> ProcessRunner.ProcessEntry {
        ProcessRunner.ProcessEntry(pid: pid, parent: parent, started: timeval(tv_sec: Int(pid), tv_usec: 0))
    }

    /// r3 a557: the tree comes out of one table, deepest first, root excluded.
    func testDescendantsAreDeepestFirstAndSkipOtherBranches() {
        let table = [entry(10, 1), entry(11, 10), entry(12, 11), entry(13, 10), entry(20, 1), entry(21, 20)]
        let pids = ProcessRunner.descendants(of: 10, in: table).map(\.pid)
        XCTAssertEqual(Set(pids), [11, 12, 13])
        XCTAssertLessThan(pids.firstIndex(of: 12)!, pids.firstIndex(of: 11)!, "a child before its parent")
    }

    func testDescendantsSurviveALoopInTheTable() {
        let table = [entry(10, 1), entry(11, 10), entry(12, 11), entry(11, 12)]
        XCTAssertEqual(Set(ProcessRunner.descendants(of: 10, in: table).map(\.pid)), [11, 12])
    }

    /// The live table lists a real child with its own start time.
    func testLiveTableFindsAChild() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30 & wait"]
        try process.run()
        defer { process.stopForTest() }
        var found: [Int32] = []
        for _ in 0..<100 where found.isEmpty {
            usleep(20_000)
            found = ProcessRunner.descendants(of: process.processIdentifier, in: ProcessRunner.processTable()).map(\.pid)
        }
        XCTAssertEqual(found.count, 1)
        found.forEach { kill($0, SIGKILL) }
    }
}
