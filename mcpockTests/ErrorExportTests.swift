import XCTest
@testable import mcpock

/// Settings "Copy All" / "Export…": the report the agents read, from the
/// same snapshot as `status.json` (Argon 2026-10-17 #12).
final class ErrorExportTests: XCTestCase {
    private let now = MCPockStatus.decoderDate("2027-01-15T08:02:00Z")

    /// One broken, one sign-in, one set up differently, one fine, one hidden broken.
    private var sample: MCPockStatus {
        try! MCPockStatus.decoder().decode(MCPockStatus.self, from: Data(MCPStatusServerTests.fixtureJSON.utf8))
    }

    private var allFine: MCPockStatus {
        var status = sample
        status.servers = status.servers.filter { !$0.needsAttention }
        return status
    }

    func testFailingIsWhatTheAgentsSee() {
        XCTAssertEqual(ErrorExport.failing(sample).map(\.name), ["firecrawl", "figma", "wake"],
                       "set up differently counts, hidden and fine ones don't")
    }

    func testMarkdownIsTheAgentsReport() {
        let md = ErrorExport.markdown(from: sample, now: now)
        XCTAssertTrue(md.hasPrefix("# mcpock error report"))
        XCTAssertTrue(md.contains(StatusReport.problemLines(sample, now: now).joined(separator: "\n")), md)
        XCTAssertTrue(md.contains("/Users/k/.cursor/mcp.json"), "config paths are in it")
        XCTAssertTrue(md.contains("wake — set up differently"), md)
        XCTAssertTrue(md.contains("Claude Code"), "agents by their full names")
        XCTAssertFalse(md.contains("old-thing —"), "a hidden server is only named, not listed")
        XCTAssertFalse(md.contains("tinycast"), "a fine server is left out")
    }

    func testMarkdownWhenNothingNeedsAttention() {
        let md = ErrorExport.markdown(from: allFine, now: now)
        XCTAssertTrue(md.contains("Nothing needs attention."), md)
        XCTAssertFalse(md.contains("automated health report from mcpock"), md)
    }

    func testMarkdownIncludesFramingExplainer() {
        let md = ErrorExport.markdown(from: sample, now: now)
        XCTAssertTrue(md.contains(ServerGroup.reportPreamble(plural: true)), md)
    }

    func testJSONCarriesConfigPathsAndDiffers() throws {
        let jsonString = ErrorExport.json(from: sample, now: now)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(jsonString.utf8)) as? [String: Any])
        XCTAssertEqual(obj["failingCount"] as? Int, 3)
        XCTAssertEqual(obj["totalCount"] as? Int, 5)
        let servers = try XCTUnwrap(obj["servers"] as? [[String: Any]])
        XCTAssertEqual(servers.map { $0["name"] as? String }, ["firecrawl", "figma", "wake"])
        XCTAssertEqual(servers[0]["configPaths"] as? [String], ["/Users/k/.cursor/mcp.json", "/Users/k/.claude.json"])
        XCTAssertEqual(servers[2]["differs"] as? String, "Grok points at a different command than Cursor.")
    }

    func testFormatFromExtension() {
        XCTAssertEqual(ErrorExport.format(forExtension: "json"), .json)
        XCTAssertEqual(ErrorExport.format(forExtension: "JSON"), .json)
        XCTAssertEqual(ErrorExport.format(forExtension: "md"), .markdown)
        XCTAssertEqual(ErrorExport.format(forExtension: "txt"), .markdown)
    }

    func testFileStampIsFilesystemSafe() {
        let stamp = ErrorExport.fileStamp(now)
        XCTAssertFalse(stamp.contains(":"))
        XCTAssertFalse(stamp.contains(" "))
        XCTAssertFalse(stamp.contains("/"))
    }
}
