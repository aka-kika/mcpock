import XCTest
@testable import mcpock

/// The footer's Copy All Problems: the report the agents read, from the
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
}
