import XCTest
@testable import mcpock

final class ErrorExportTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_780_000_000)  // fixed, deterministic

    private func group(_ name: String, _ state: HealthState, issues: [ServerIssue], sources: [String]) -> ServerGroup {
        ServerGroup(name: name, state: state, sourceLabels: sources, tools: [], issues: issues,
                    variantCount: sources.count)
    }

    private var sample: [ServerGroup] {
        [
            group("eventkit", .broken,
                  issues: [ServerIssue(label: "Cursor", reason: "Spawn error: not found", command: "/bin/eventkit")],
                  sources: ["Code", "Cursor"]),
            group("healthy-one", .healthy, issues: [], sources: ["Code"]),  // no issues → excluded
            group("vercel", .broken,
                  issues: [ServerIssue(label: "Cursor", reason: "HTTP 401", command: "")],
                  sources: ["Cursor"]),
        ]
    }

    func testFailingExcludesHealthy() {
        let failing = ErrorExport.failing(sample)
        XCTAssertEqual(failing.map(\.name), ["eventkit", "vercel"])
    }

    func testMarkdownListsFailingServersWithReasonsAndCommand() {
        let md = ErrorExport.markdown(from: sample, totalCount: 3, generated: date)
        XCTAssertTrue(md.hasPrefix("# mcpock error report"))
        XCTAssertTrue(md.contains("Failing servers: 2 of 3"), md)
        XCTAssertTrue(md.contains("## eventkit — broken"), md)
        XCTAssertTrue(md.contains("- **Cursor**: Spawn error: not found"), md)
        XCTAssertTrue(md.contains("`/bin/eventkit`"), "command should be shown when present")
        XCTAssertTrue(md.contains("## vercel — broken"), md)
        XCTAssertFalse(md.contains("healthy-one"), "healthy servers must be excluded")
    }

    func testMarkdownEmptyWhenNoErrors() {
        let md = ErrorExport.markdown(from: [group("ok", .healthy, issues: [], sources: ["Code"])],
                                      totalCount: 1, generated: date)
        XCTAssertTrue(md.contains("Failing servers: 0 of 1"))
        XCTAssertTrue(md.contains("No failing servers."))
    }

    func testMarkdownExplainerAbsentWhenNoFailures() {
        let md = ErrorExport.markdown(from: [group("ok", .healthy, issues: [], sources: ["Code"])],
                                      totalCount: 1, generated: date)
        XCTAssertFalse(md.contains("startup health check"), md)
    }

    func testJSONIsValidAndContainsFailingServers() throws {
        let jsonString = ErrorExport.json(from: sample, totalCount: 3, generated: date)
        let obj = try JSONSerialization.jsonObject(with: Data(jsonString.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["failingCount"] as? Int, 2)
        XCTAssertEqual(obj?["totalCount"] as? Int, 3)
        let servers = obj?["servers"] as? [[String: Any]]
        XCTAssertEqual(servers?.count, 2)
        XCTAssertEqual(servers?.first?["name"] as? String, "eventkit")
        let errors = servers?.first?["errors"] as? [[String: Any]]
        XCTAssertEqual(errors?.first?["reason"] as? String, "Spawn error: not found")
    }

    func testFormatFromExtension() {
        XCTAssertEqual(ErrorExport.format(forExtension: "json"), .json)
        XCTAssertEqual(ErrorExport.format(forExtension: "JSON"), .json)
        XCTAssertEqual(ErrorExport.format(forExtension: "md"), .markdown)
        XCTAssertEqual(ErrorExport.format(forExtension: "txt"), .markdown)
    }

    func testFileStampIsFilesystemSafe() {
        let stamp = ErrorExport.fileStamp(date)
        XCTAssertFalse(stamp.contains(":"))
        XCTAssertFalse(stamp.contains(" "))
        XCTAssertFalse(stamp.contains("/"))
    }

    func testMarkdownIncludesFramingExplainer() {
        // The export shares its preamble with ServerGroup.copyText so the two
        // explanations can't drift — assert against that single source.
        let md = ErrorExport.markdown(from: sample, totalCount: 3, generated: date)
        XCTAssertTrue(md.contains(ServerGroup.reportPreamble(plural: true)), md)
        XCTAssertTrue(md.contains("automated health report from mcpock"), md)
    }
}
