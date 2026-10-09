import XCTest
@testable import mcpock

final class ConfigScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcpock-scan-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }
    private func write(_ rel: String, _ contents: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testFindsMCPFilesAndIgnoresDecoys() throws {
        try write("agentA/mcp.json", #"{"mcpServers":{"a":{"command":"a"}}}"#)
        try write("agentB/config.yaml", "extensions:\n  b:\n    enabled: true\n    type: stdio\n    name: b\n    cmd: b\n    args: []\n")
        try write("agentC/settings.json", #"{"theme":"dark"}"#)                 // decoy: not MCP
        try write("node_modules/pkg/mcp.json", #"{"mcpServers":{"x":{"command":"x"}}}"#) // excluded dir

        let found = ConfigScanner.scan(roots: [root.path], maxDepth: 2)
        let labels = Set(found.map { $0.label })
        XCTAssertTrue(labels.contains("agentA"))
        XCTAssertTrue(labels.contains("agentB"))
        XCTAssertFalse(labels.contains("agentC"), "non-MCP JSON must be ignored")
        XCTAssertFalse(found.contains { $0.path.contains("node_modules") }, "node_modules excluded")
    }

    /// Regression: `excludedDirs` held `Caches`/`Cache` but not lowercase `cache`, so
    /// XDG-style cache dirs were walked. A stale Langflow artifact at
    /// `~/.langflow/cache/<uuid>/_mcp_servers_<uuid>.json` was discovered and probed as a
    /// real server, reporting broken forever (2026-08-03).
    func testExcludesCacheDirectoriesRegardlessOfCase() throws {
        try write("agentA/mcp.json", #"{"mcpServers":{"a":{"command":"a"}}}"#)
        try write("cache/proj/_mcp_servers_proj.json", #"{"mcpServers":{"lf":{"command":"uvx"}}}"#)
        try write("Cache/proj/mcp.json", #"{"mcpServers":{"lf2":{"command":"uvx"}}}"#)
        try write("CACHE/proj/mcp.json", #"{"mcpServers":{"lf3":{"command":"uvx"}}}"#)
        try write("Caches/proj/mcp.json", #"{"mcpServers":{"lf4":{"command":"uvx"}}}"#)

        let found = ConfigScanner.scan(roots: [root.path], maxDepth: 3)
        XCTAssertTrue(found.contains { $0.label == "agentA" }, "real config still found")
        XCTAssertFalse(found.contains { $0.path.lowercased().contains("/cache") },
                       "cache dirs must be skipped in every casing")
    }

    /// Regression: Hermes keeps dated copies of its config under `state-snapshots/`
    /// and archived profiles under `_archived_…/`; both were discovered as agents
    /// named after the folder once the YAML shape was supported.
    func testExcludesSnapshotAndArchiveDirectories() throws {
        try write("agent/config.yaml", "mcp_servers:\n  a:\n    command: a\n")
        try write("agent/state-snapshots/20260718-pre-update/config.yaml", "mcp_servers:\n  a:\n    command: a\n")
        try write("agent/profiles/_archived_2026-08-27/x/config.yaml", "mcp_servers:\n  a:\n    command: a\n")
        try write("agent/history/config.yaml", "mcp_servers:\n  a:\n    command: a\n")

        let found = ConfigScanner.scan(roots: [root.path], maxDepth: 4)
        XCTAssertEqual(found.map(\.label), ["agent"], "only the live config, none of its copies")
    }

    /// 1.5.1: MiniMax loads only `~/.minimax/mcp.json`. `~/.minimax/mcp/mcp.json`
    /// is not a config it reads, so the scan must skip it (it made playwright and
    /// recall show as "set up differently" for MiniMax).
    func testSkipsMiniMaxInnerMCPFile() throws {
        try write(".minimax/mcp.json", #"{"mcpServers":{"feed":{"command":"feed"}}}"#)
        try write(".minimax/mcp/mcp.json", #"{"mcpServers":{"playwright":{"command":"npx"}}}"#)

        let found = ConfigScanner.scan(roots: [root.appendingPathComponent(".minimax").path], maxDepth: 2)
        XCTAssertEqual(found.map { ($0.path as NSString).lastPathComponent }, ["mcp.json"])
        XCTAssertEqual(found.first?.entries.map(\.name), ["feed"])
        XCTAssertTrue(ConfigScanner.isExcludedFile("/Users/k/.minimax/mcp/mcp.json"))
        XCTAssertFalse(ConfigScanner.isExcludedFile("/Users/k/.minimax/mcp.json"))
    }

    /// Other excluded names are matched case-insensitively too.
    func testExclusionIsCaseInsensitiveForOtherNames() throws {
        try write("Node_Modules/pkg/mcp.json", #"{"mcpServers":{"x":{"command":"x"}}}"#)
        try write("Build/mcp.json", #"{"mcpServers":{"y":{"command":"y"}}}"#)
        try write("Logs/mcp.json", #"{"mcpServers":{"z":{"command":"z"}}}"#)

        let found = ConfigScanner.scan(roots: [root.path], maxDepth: 3)
        XCTAssertTrue(found.isEmpty, "excluded dir names must match regardless of case")
    }

    func testDeriveLabelStripsDotAndUsesFolder() {
        XCTAssertEqual(ConfigScanner.deriveLabel(fromPath: "/x/.someagent/mcp.json"), "someagent")
        XCTAssertEqual(ConfigScanner.deriveLabel(fromPath: "/x/Application Support/Foo/config.json"), "Foo")
    }

    func testDoesNotFollowSymlinkedDirectories() throws {
        let safe = root.appendingPathComponent("safe")
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        try write("outside/agent/mcp.json", #"{"mcpServers":{"secret":{"command":"s"}}}"#)
        try FileManager.default.createSymbolicLink(
            at: safe.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("outside"))
        let found = ConfigScanner.scan(roots: [safe.path], maxDepth: 3)
        XCTAssertFalse(found.contains { $0.entries.contains { $0.name == "secret" } },
                       "must not descend through a symlink into an outside tree")
    }

    func testDoesNotFollowSymlinkedRoot() throws {
        try write("outside/agent/mcp.json", #"{"mcpServers":{"secret":{"command":"s"}}}"#)
        let linkRoot = root.appendingPathComponent("linkroot")
        try FileManager.default.createSymbolicLink(
            at: linkRoot, withDestinationURL: root.appendingPathComponent("outside"))
        let found = ConfigScanner.scan(roots: [linkRoot.path], maxDepth: 3)
        XCTAssertFalse(found.contains { $0.entries.contains { $0.name == "secret" } },
                       "a symlinked root must not be walked")
    }

    func testDefaultRootsAreTCCSafe() {
        for r in ConfigScanner.defaultRoots {
            for protected in ["/Documents", "/Desktop", "/Downloads", "Mobile Documents"] {
                XCTAssertFalse(r.contains(protected), "default root \(r) must not touch \(protected)")
            }
        }
    }
}
