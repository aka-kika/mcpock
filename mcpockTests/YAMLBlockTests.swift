import XCTest
@testable import mcpock

/// `YAMLBlock` is the one YAML reader behind the Goose and Hermes shapes (zero
/// third-party dependencies, so no YAML library). 1.5.0 read only the first line
/// of a value, so Hermes' wrapped `command:` for Safari Technology Preview came out
/// as `/Applications/Safari Technology` and the server showed as broken, and a
/// `command:` whose value starts on the next line was dropped entirely. The
/// fixtures below are copied from the real config shapes (paths and values
/// sanitised); the expected scalars were checked against PyYAML.
final class YAMLBlockTests: XCTestCase {

    // MARK: - Real shapes

    /// `~/.hermes/config.yaml` as Hermes (PyYAML) writes it: long values wrap onto
    /// a deeper line, a value may start on the line after its key (note the space
    /// after `command:`), lists sit one level deeper than their key.
    private let hermesReal = """
    model:
      default: some-model
    mcp_servers:
      mcpock:
        command: /Applications/mcpock.app/Contents/Helpers/mcpock-mcp
        args: []
      desktop-commander:
        args:
          - /Users/k/.agent/node/lib/node_modules/@wonderwhy-er/desktop-commander/dist/index.js
        command: /Users/k/.local/bin/node
      firecrawl:
        args: []
        command: /Users/k/.local/bin/firecrawl-mcp
        env:
          FIRECRAWL_API_KEY: fc-test
          FIRECRAWL_API_URL: https://firecrawl.example.com
      notes-vault:
        args:
          - /Users/k/_INFRA/mcp/servers/notes-vault-mcp/server.py
        command:\u{20}
          /Users/k/_INFRA/mcp/servers/notes-vault-mcp/.venv/bin/python
        env:
          VAULT_READ_ONLY: 'false'
          VAULT_VAULT_PATH: /Users/k/Vault
      reed-md:
        headers:
          Authorization: Bearer test-token
        type: http
        url: http://127.0.0.1:8742/mcp
      safari-mcp-stp:
        args:
          - --mcp
        command: /Applications/Safari Technology\u{20}
          Preview.app/Contents/MacOS/safaridriver
      shared-agent-memory:
        args: []
        command:\u{20}
          /Users/k/_INFRA/agent-memory/Shared-Agent-Memory-V1/scripts/run-memory-mcp.sh
        connect_timeout: 60
        timeout: 120
      wake:
        args: []
        command: /Applications/Wake.app/Contents/MacOS/wake-mcp
    platform_toolsets:
      cli:
        - browser
    """

    func testHermesWrappedCommandIsJoinedWithOneSpace() {
        let safari = MCPServersYAML.servers(fromYAML: hermesReal)["safari-mcp-stp"]
        XCTAssertEqual(safari?["command"] as? String,
                       "/Applications/Safari Technology Preview.app/Contents/MacOS/safaridriver")
        XCTAssertEqual(safari?["args"] as? [String], ["--mcp"])
    }

    func testHermesCommandStartingOnTheNextLineIsRead() {
        let servers = MCPServersYAML.servers(fromYAML: hermesReal)
        XCTAssertEqual(servers["notes-vault"]?["command"] as? String,
                       "/Users/k/_INFRA/mcp/servers/notes-vault-mcp/.venv/bin/python")
        XCTAssertEqual((servers["notes-vault"]?["env"] as? [String: String])?["VAULT_READ_ONLY"], "false")
        XCTAssertEqual(servers["shared-agent-memory"]?["command"] as? String,
                       "/Users/k/_INFRA/agent-memory/Shared-Agent-Memory-V1/scripts/run-memory-mcp.sh")
    }

    func testHermesRealShapeFindsEveryServer() {
        let servers = MCPServersYAML.servers(fromYAML: hermesReal)
        XCTAssertEqual(Set(servers.keys), ["mcpock", "desktop-commander", "firecrawl", "notes-vault",
                                           "reed-md", "safari-mcp-stp", "shared-agent-memory", "wake"])
        XCTAssertEqual((servers["reed-md"]?["headers"] as? [String: String])?["Authorization"], "Bearer test-token")

        let configs = ConfigDiscovery.configs(
            from: MCPServersYAML.shapeEntries(hermesReal)!, source: ServerSource(label: "Hermes"), idPrefix: "hermes")
        let safari = configs.first { $0.name == "safari-mcp-stp" }
        XCTAssertEqual(safari?.transport, .stdio)
        XCTAssertEqual(safari?.command, "/Applications/Safari Technology Preview.app/Contents/MacOS/safaridriver")
    }

    /// `~/.config/goose/config.yaml` as Goose writes it: lists level with their
    /// key, `envs: {}`, quoted descriptions with `''`, and (defensively) a wrapped
    /// `cmd:` and description.
    private let gooseReal = """
    extensions:
      personal-ops-manual:
        enabled: true
        type: stdio
        name: personal-ops-manual
        description: 'Personal Ops Manual, read-only: list_categories, get_document over the ops pages.'
        cmd: /Users/k/.agent/node/bin/node
        args:
        - /Users/k/_INFRA/apps/ops-manual/mcp/server.mjs
        envs: {}
        env_keys: []
        timeout: 300
        cwd: null
        bundled: null
      safari-mcp-stp:
        enabled: true
        type: stdio
        name: Safari (Technology Preview)
        description: 'Drive Safari Technology Preview through safaridriver. 17 tools: navigate_to_url,
          get_page_content, page_info'
        cmd: /Applications/Safari Technology
          Preview.app/Contents/MacOS/safaridriver
        args:
        - --mcp
        envs: {}
        timeout: 300
      reed-md:
        enabled: true
        type: streamable_http
        name: reed-md
        uri: http://127.0.0.1:8742/mcp
        envs: {}
        headers:
          Authorization: Bearer test-token
      todo:
        enabled: true
        type: platform
        name: todo
        description: Enable a todo list for goose so it can keep track of what it is doing
        bundled: true
      playwright:
        enabled: false
        type: stdio
        name: Playwright
        cmd: npx
        args:
        - '@playwright/mcp@latest'
    GOOSE_TELEMETRY_ENABLED: false
    """

    func testGooseRealShape() {
        let servers = GooseConfig.servers(fromYAML: gooseReal)
        XCTAssertEqual(Set(servers.keys), ["personal-ops-manual", "safari-mcp-stp", "reed-md"])
        XCTAssertEqual(servers["personal-ops-manual"]?["args"] as? [String],
                       ["/Users/k/_INFRA/apps/ops-manual/mcp/server.mjs"])
        XCTAssertEqual(servers["safari-mcp-stp"]?["command"] as? String,
                       "/Applications/Safari Technology Preview.app/Contents/MacOS/safaridriver")
        XCTAssertEqual(servers["safari-mcp-stp"]?["args"] as? [String], ["--mcp"])
        XCTAssertEqual(servers["reed-md"]?["url"] as? String, "http://127.0.0.1:8742/mcp")
    }

    func testGooseQuotedDescriptionsFold() {
        let ext = YAMLBlock.entries(in: gooseReal, under: "extensions")
        XCTAssertEqual(ext["personal-ops-manual"]?["description"]?.scalar,
                       "Personal Ops Manual, read-only: list_categories, get_document over the ops pages.")
        XCTAssertEqual(ext["safari-mcp-stp"]?["description"]?.scalar,
                       "Drive Safari Technology Preview through safaridriver. 17 tools: navigate_to_url, get_page_content, page_info")
    }

    // MARK: - Continuations never become keys or list items

    func testContinuationLinesStayInTheirScalar() {
        let yaml = """
        mcp_servers:
          tricky:
            command: /opt/my tool
              - not-a-list-item
            args:
              - one
              - two
                continued
              - 'three
                quoted'
            env:
              KEY: "a
                b"
        extensions:
          wrapped:
            type: stdio
            cmd: /opt/my
              tool
            args:
            - --mcp
            - long
              arg
            envs: {}
        """
        let hermes = MCPServersYAML.servers(fromYAML: yaml)["tricky"]
        XCTAssertEqual(hermes?["command"] as? String, "/opt/my tool - not-a-list-item")
        XCTAssertEqual(hermes?["args"] as? [String], ["one", "two continued", "three quoted"])
        XCTAssertEqual((hermes?["env"] as? [String: String])?["KEY"], "a b")

        let goose = GooseConfig.servers(fromYAML: yaml)["wrapped"]
        XCTAssertEqual(goose?["command"] as? String, "/opt/my tool")
        XCTAssertEqual(goose?["args"] as? [String], ["--mcp", "long arg"])
        XCTAssertNil(goose?["env"], "envs: {} is an empty map, not a field")
    }

    func testPlainScalarBlankLineBecomesLineBreak() {
        let yaml = "a: one\n  two\n\n  three\n\n\n  four\nb: x\n"
        XCTAssertEqual(scalar(yaml, "a"), "one two\nthree\n\nfour")
        XCTAssertEqual(scalar(yaml, "b"), "x")
    }

    func testCommentsAreDropped() {
        let yaml = """
        # top
        a: # after a key
          # inside
          b: 1 # trailing
          # between
          c: '#not a comment' # trailing
          url: http://x:80/p#frag
        """
        XCTAssertEqual(scalar(yaml, "a", "b"), "1")
        XCTAssertEqual(scalar(yaml, "a", "c"), "#not a comment")
        XCTAssertEqual(scalar(yaml, "a", "url"), "http://x:80/p#frag")
    }

    // MARK: - Quoted scalars

    func testDoubleQuotedFoldsAndUnescapes() {
        let yaml = #"""
        a: "one
          two

           three\
           four \
          five\t\u00e9\x41 \"q\" \\"
        b: 1
        """#
        XCTAssertEqual(scalar(yaml, "a"), "one two\nthreefour five\t\u{e9}A \"q\" \\")
        XCTAssertEqual(scalar(yaml, "b"), "1")
    }

    func testDoubleQuotedEscapedSpaceBeforeBreakIsKept() {
        XCTAssertEqual(scalar("a: \"x\\ \n  y\"\n", "a"), "x  y")
    }

    func testSingleQuotedFoldsAndUnescapesQuotes() {
        XCTAssertEqual(scalar("a: 'it''s\n   folded\n\n   here '\nb: 2\n", "a"), "it's folded\nhere ")
    }

    /// A quote that never closes must not swallow the rest of the file.
    func testUnterminatedQuoteIsReadAsPlainText() {
        let yaml = "a:\n  b: \"oops\n  c: 1\n"
        XCTAssertEqual(scalar(yaml, "a", "b"), "\"oops")
        XCTAssertEqual(scalar(yaml, "a", "c"), "1")
    }

    // MARK: - Block scalars

    func testLiteralBlockScalarAndChomping() {
        XCTAssertEqual(scalar("a: |\n  line1\n   line2\n\n  line3\nb: 1\n", "a"), "line1\n line2\n\nline3\n")
        XCTAssertEqual(scalar("a: |-\n  line1\n  line2\n\n\nb: 1\n", "a"), "line1\nline2")
        XCTAssertEqual(scalar("a: |+\n  line1\n\n\nb: 1\n", "a"), "line1\n\n\n")
        XCTAssertEqual(scalar("a: |\nb: 1\n", "a"), "")
        XCTAssertEqual(scalar("a: |\nb: 1\n", "b"), "1")
    }

    func testFoldedBlockScalar() {
        let yaml = "a: >\n  one\n  two\n\n  three\n    more\n    indented\n  back\n\n\nb: 1\n"
        XCTAssertEqual(scalar(yaml, "a"), "one two\nthree\n  more\n  indented\nback\n")
        XCTAssertEqual(scalar("a: >+\n  x\n\n", "a"), "x\n\n")
        XCTAssertEqual(scalar("a: >2-\n    leading\n  base\nb: 1\n", "a"), "  leading\nbase")
    }

    func testBlockScalarAtEndOfFileWithoutNewline() {
        XCTAssertEqual(scalar("a: |\n  x\n  y", "a"), "x\ny")
    }

    // MARK: - Collections

    func testFlowCollectionsAcrossLinesWithComments() {
        let yaml = "a: [\n  x, # c\n  'y z',\n  {k: v, j: \"w\"}\n]\nb: {p: [1, 2], q: }\n"
        guard case .sequence(let items)? = YAMLBlock.parse(yaml)?["a"] else { return XCTFail("a is a list") }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0], .scalar("x"))
        XCTAssertEqual(items[1], .scalar("y z"))
        XCTAssertEqual(items[2]["j"], .scalar("w"))
        XCTAssertEqual(YAMLBlock.parse(yaml)?["b"]?["q"], .scalar(""))
    }

    func testCompactListItems() {
        let yaml = "l:\n- name: a\n  cmd: b\n  args: [1, 2]\n- - x\n  - y\n- plain\n  wrapped\n"
        guard case .sequence(let items)? = YAMLBlock.parse(yaml)?["l"] else { return XCTFail("l is a list") }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0]["cmd"], .scalar("b"))
        XCTAssertEqual(items[0]["args"], .sequence([.scalar("1"), .scalar("2")]))
        XCTAssertEqual(items[1], .sequence([.scalar("x"), .scalar("y")]))
        XCTAssertEqual(items[2], .scalar("plain wrapped"))
    }

    func testQuotedKeysAndColonsInValues() {
        let yaml = "\"a b\": 1\n'c: d': 2\ne:f: 3\n"
        XCTAssertEqual(scalar(yaml, "a b"), "1")
        XCTAssertEqual(scalar(yaml, "c: d"), "2")
        XCTAssertEqual(scalar(yaml, "e:f"), "3")
    }

    func testTagsAndAnchorsAreDropped() {
        let yaml = "a: &x foo\nb: !tag bar\nc: &m\n  k: v\n"
        XCTAssertEqual(scalar(yaml, "a"), "foo")
        XCTAssertEqual(scalar(yaml, "b"), "bar")
        XCTAssertEqual(scalar(yaml, "c", "k"), "v")
    }

    func testWindowsLineEndings() {
        let yaml = "a:\r\n  b: 1\r\n  c: \"x\r\n    y\"\r\n"
        XCTAssertEqual(scalar(yaml, "a", "b"), "1")
        XCTAssertEqual(scalar(yaml, "a", "c"), "x y")
    }

    // MARK: - Safety

    /// The scan offers every JSON and TOML file to the YAML shapes. A big JSON
    /// file once made the flow reader quadratic and malformed flow looped (caught
    /// by a 10-minute test run); both must now come back at once.
    func testLargeJSONAndMalformedFlowFinishFast() {
        let entries = (0..<3000).map { "\t\t{ \"name\": \"rule-\($0)\", \"options\": [\"a\", 'b', {\"c\": [1, 2]}] }" }
        let json = "{\n\t\"rules\": [\n" + entries.joined(separator: ",\n") + "\n\t]\n}\n"
        let start = Date()
        XCTAssertNil(GooseConfig.shapeEntries(json))
        XCTAssertNil(MCPServersYAML.shapeEntries(json))
        XCTAssertNotNil(YAMLBlock.parse(json), "a whole JSON document parses as one flow map")
        for broken in ["{a: ]}", "[a, }", "{[: x}", "a: {b: [c, {d", "a: \"x", "- [", "{", "a: |9\n", "? x\n"] {
            _ = YAMLBlock.parse(broken)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "no quadratic path, no endless loop")
    }

    // MARK: - Helpers

    private func scalar(_ yaml: String, _ path: String...) -> String? {
        var node = YAMLBlock.parse(yaml)
        for key in path { node = node?[key] }
        return node?.scalarValue
    }

    /// Thousands of nested `- ` on one line recursed once per level and could
    /// overflow a scan thread's stack (review, 2026-09-26). Parsed here on a
    /// thread with a small stack, as the config scan would.
    func testDeepNestingDoesNotOverflowTheStack() {
        let text = "mcp_servers:\n  x:\n    args: " + String(repeating: "- ", count: 20_000) + "end\n"
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            _ = YAMLBlock.parse(text)
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
    }
}
