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

    func testSecondPassEntriesResolve() {
        XCTAssertEqual(ServerIcons.lookUp(name: "monday", targets: []), .asset("server-monday"))
        XCTAssertEqual(ServerIcons.lookUp(name: "x", targets: ["https://mcp.monday.com/mcp"]), .asset("server-monday"))
        XCTAssertEqual(ServerIcons.lookUp(name: "icon-composer", targets: []), .symbol("square.3.layers.3d"))
        XCTAssertEqual(ServerIcons.lookUp(name: "iconcomposer", targets: []), .symbol("square.3.layers.3d"))
        // Brands whose mark has no clear license stay on the plain icon (22 Nov).
        for name in ["slack", "openai", "azure", "aws", "salesforce", "twilio", "canva", "apify", "ahrefs", "postiz"] {
            XCTAssertEqual(ServerIcons.lookUp(name: name, targets: []), .fallback, name)
        }
    }

    /// Her own icons come from a folder on her Mac, by server name, and win
    /// over the table. With no folder set (demo mode, tests) nothing is read.
    func testOwnIconsComeFromTheFolderByServerName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-own-icons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            ServerIcons.userDirectory = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><rect x=\"4\" y=\"4\" width=\"16\" height=\"16\"/></svg>"
        for file in ["My_Notes.svg", "github.png", "zzqq.txt"] {
            try svg.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        XCTAssertNil(ServerIcons.userDirectory, "nothing is read until the app says where")
        XCTAssertEqual(ServerIcons.icon(name: "github", targets: []), .asset("server-github"))

        ServerIcons.userDirectory = folder
        XCTAssertEqual(ServerIcons.icon(name: "my-notes", targets: []), .file(folder.appendingPathComponent("My_Notes.svg").path))
        XCTAssertEqual(ServerIcons.icon(name: "my-notes-mcp", targets: []), .file(folder.appendingPathComponent("My_Notes.svg").path),
                       "the same name rules as the table")
        XCTAssertEqual(ServerIcons.icon(name: "github", targets: []), .file(folder.appendingPathComponent("github.png").path),
                       "her own picture wins over the table")
        XCTAssertEqual(ServerIcons.icon(name: "zzqq", targets: []), .fallback, "only svg, pdf and png count")
        XCTAssertEqual(ServerIcons.icon(name: "notion", targets: []), .asset("server-notion"))

        ServerIcons.userDirectory = nil
        XCTAssertEqual(ServerIcons.icon(name: "github", targets: []), .asset("server-github"), "the folder is not read any more")
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
