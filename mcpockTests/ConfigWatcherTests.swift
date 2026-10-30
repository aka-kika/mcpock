import XCTest
@testable import mcpock

/// 1.13: a changed config file is noticed, however it was saved, and nothing
/// else is.
final class ConfigWatcherTests: XCTestCase {
    private var dir: URL!
    private var watcher: ConfigWatcher?

    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.withLock { n } }
        func add() { lock.withLock { n += 1 } }
    }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-watch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        watcher?.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private func start(_ paths: [URL], gap: TimeInterval = 0) throws -> Count {
        let count = Count()
        let watcher = ConfigWatcher(settle: .milliseconds(100), minimumGap: gap) { count.add() }
        watcher.watch(paths.map(\.path))
        self.watcher = watcher
        Thread.sleep(forTimeInterval: 0.1)
        return count
    }

    private func waitFor(_ count: Count, atLeast n: Int, seconds: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while count.value < n, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThanOrEqual(count.value, n)
    }

    func testAWriteInPlaceIsNoticed() async throws {
        let file = dir.appendingPathComponent("mcp.json")
        try Data("{}".utf8).write(to: file)
        let count = try start([file])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" ".utf8))
        try handle.close()
        try await waitFor(count, atLeast: 1)
    }

    /// Editors and agents save by writing a copy and renaming it over: the
    /// old descriptor never hears of it, and a second save must be seen too.
    func testAnAtomicSaveIsNoticedEveryTime() async throws {
        let file = dir.appendingPathComponent("mcp.json")
        try Data("{}".utf8).write(to: file)
        let count = try start([file])
        try Data("{ }".utf8).write(to: file, options: .atomic)
        try await waitFor(count, atLeast: 1)
        try Data("{  }".utf8).write(to: file, options: .atomic)
        try await waitFor(count, atLeast: 2)
    }

    func testAFileThatDoesNotExistYetIsNoticedWhenItAppears() async throws {
        let folder = dir.appendingPathComponent("later")
        let file = folder.appendingPathComponent("mcp.json")
        let count = try start([file])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(count.value, 0, "the folder alone is no change")
        try Data("{}".utf8).write(to: file)
        try await waitFor(count, atLeast: 1)
    }

    func testOtherFilesInTheFolderAreIgnored() async throws {
        let file = dir.appendingPathComponent("mcp.json")
        try Data("{}".utf8).write(to: file)
        let count = try start([file])
        try Data("x".utf8).write(to: dir.appendingPathComponent("other.txt"))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(count.value, 0)
    }

    func testAFileThatRewritesAllDayFiresAtMostOncePerGap() async throws {
        let file = dir.appendingPathComponent(".claude.json")
        try Data("{}".utf8).write(to: file)
        let count = try start([file], gap: 30)
        for i in 0..<3 {
            try Data("{\(i)}".utf8).write(to: file, options: .atomic)
            try await Task.sleep(for: .milliseconds(250))
        }
        try await waitFor(count, atLeast: 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(count.value, 1)
    }

    func testNothingFiresAfterStop() async throws {
        let file = dir.appendingPathComponent("mcp.json")
        try Data("{}".utf8).write(to: file)
        let count = try start([file])
        watcher?.stop()
        try Data("{ }".utf8).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(count.value, 0)
    }

    func testPureParts() {
        let a = ConfigWatcher.Signature(inode: 1, size: 2, modified: timespec(tv_sec: 3, tv_nsec: 4))
        let b = ConfigWatcher.Signature(inode: 1, size: 2, modified: timespec(tv_sec: 3, tv_nsec: 5))
        let none: ConfigWatcher.Signature? = nil
        XCTAssertEqual(ConfigWatcher.changed(from: ["x": a, "y": a, "z": none], to: ["x": a, "y": b, "z": none]), ["y"])
        XCTAssertEqual(ConfigWatcher.changed(from: ["x": none], to: ["x": a]), ["x"], "appeared")
        XCTAssertEqual(ConfigWatcher.changed(from: ["x": a], to: ["x": none]), ["x"], "removed")
        XCTAssertEqual(ConfigWatcher.nearestFolder(of: "/a/b/c/f.json", exists: { $0 == "/a" }), "/a")
        XCTAssertEqual(ConfigWatcher.nearestFolder(of: "/a/b/f.json", exists: { $0 == "/a/b" }), "/a/b")
    }
}
