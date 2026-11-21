import XCTest
@testable import mcpock

/// Which glyph a server row gets: name, package, host, keywords, fallback.
final class ServerIconsTests: XCTestCase {
    private func icon(_ name: String, _ targets: [String] = []) -> ServerIcon {
        ServerIcons.icon(name: name, targets: targets)
    }

    func testExactName() {
        XCTAssertEqual(icon("github"), .asset("server-github"))
        XCTAssertEqual(icon("Filesystem"), .symbol("folder"))
    }

    func testNormalizedName() {
        XCTAssertEqual(icon("github-mcp"), .asset("server-github"))
        XCTAssertEqual(icon("mcp-server-fetch"), .symbol("arrow.down.circle"))
        XCTAssertEqual(icon("Brave_Search"), .asset("server-brave"))
        XCTAssertEqual(icon("notion mcp server"), .asset("server-notion"))
    }

    func testPackageInCommandLine() {
        XCTAssertEqual(icon("ctx", ["npx -y @upstash/context7-mcp@latest"]), .asset("server-upstash"))
        XCTAssertEqual(icon("x", ["uvx mcp-server-time"]), .symbol("clock"))
        // A substring of a token is not a match.
        XCTAssertEqual(icon("x", ["npx not-mcp-server-time-extra"]), .fallback)
    }

    func testURLHostAndSubdomain() {
        XCTAssertEqual(icon("remote", ["https://mcp.linear.app/sse"]), .asset("server-linear"))
        XCTAssertEqual(icon("cf", ["https://docs.mcp.cloudflare.com/mcp"]), .asset("server-cloudflare"))
        // A parent of a table host does not match.
        XCTAssertEqual(icon("x", ["https://linear.app/x"]), .fallback)
    }

    func testKeywordOrder() {
        XCTAssertEqual(icon("apple-notes"), .symbol("note.text"))
        XCTAssertEqual(icon("apple-docs"), .asset("server-apple"))
        XCTAssertEqual(icon("my-obsidian-vault"), .asset("server-obsidian"))
        // Whole parts only: "notesy" is not "notes".
        XCTAssertEqual(icon("notesy"), .fallback)
    }

    func testUnknownIsFallback() {
        XCTAssertEqual(icon("zzz-unknown", ["npx -y something"]), .fallback)
    }

    func testEveryAssetNameHasAFolder() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let catalog = root.appendingPathComponent("mcpock/Assets.xcassets")
        var names = Set<String>()
        for e in ServerIcons.table { if case .asset(let n) = e.icon { names.insert(n) } }
        for k in ServerIcons.keywords { if case .asset(let n) = k.icon { names.insert(n) } }
        XCTAssertFalse(names.isEmpty)
        for n in names {
            let dir = catalog.appendingPathComponent("\(n).imageset")
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "missing \(n).imageset")
        }
    }
}
