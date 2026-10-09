import XCTest
@testable import mcpock

/// Regression: an MCP server whose command is a GUI app-bundle binary
/// (Electron "run my script as Node" style, e.g. MiniMax Code's builtin
/// `matrix`) must be probed with `ELECTRON_RUN_AS_NODE=1`. Without it the
/// probe booted the full app every cycle and then killed it — the user-visible
/// "app keeps opening and crashing while mcpock runs" loop.
final class AppBundleProbeTests: XCTestCase {

    func testIsAppBundleExecutable() {
        XCTAssertTrue(PathResolver.isAppBundleExecutable(
            "/Applications/MiniMax Code.app/Contents/MacOS/MiniMax Code"))
        XCTAssertTrue(PathResolver.isAppBundleExecutable(
            "/Applications/Foo.app/Contents/MacOS/helpers/foo-helper"))
        XCTAssertFalse(PathResolver.isAppBundleExecutable("/usr/local/bin/node"))
        XCTAssertFalse(PathResolver.isAppBundleExecutable("/opt/homebrew/bin/uv"))
        XCTAssertFalse(PathResolver.isAppBundleExecutable(
            "/Applications/Foo.app/Contents/Resources/cli.js"))
    }

    /// The fake "app binary" only speaks MCP when ELECTRON_RUN_AS_NODE=1 —
    /// otherwise it exits 66 (standing in for "the GUI booted instead").
    /// A healthy probe therefore proves the runner injected the variable.
    func testAppBundleCommandIsProbedAsNode() async throws {
        let config = try makeFakeAppBundleConfig(id: "test:electron", configEnv: [:])
        defer { removeFakeBundle(for: config) }

        let result = await StdioProbe.probe(config: config, fetchTools: true)
        XCTAssertEqual(
            result.state, .healthy,
            "app-bundle command must be run with ELECTRON_RUN_AS_NODE=1, got \(result.state): \(result.failureReason ?? "")"
        )
        XCTAssertEqual(result.tools?.first?.name, "echo")
    }

    /// A config that sets ELECTRON_RUN_AS_NODE itself must win over the
    /// injection — here it forces "0", the fake binary "boots the GUI"
    /// (exit 66), and the probe reports broken.
    func testConfigProvidedElectronVarIsNotOverridden() async throws {
        let config = try makeFakeAppBundleConfig(
            id: "test:electron-override",
            configEnv: ["ELECTRON_RUN_AS_NODE": "0"]
        )
        defer { removeFakeBundle(for: config) }

        let result = await StdioProbe.probe(config: config, fetchTools: false)
        XCTAssertEqual(result.state, .broken,
                       "config-set ELECTRON_RUN_AS_NODE must be respected verbatim")
        XCTAssertTrue(result.failureReason?.contains("66") == true,
                      "expected the fake GUI-boot exit code, got: \(result.failureReason ?? "nil")")
    }

    // MARK: - Fixture

    /// Builds `<tmp>/<uuid>/Fake.app/Contents/MacOS/fake`: a script that answers
    /// the MCP handshake only under ELECTRON_RUN_AS_NODE=1 and exits 66 otherwise.
    private func makeFakeAppBundleConfig(id: String, configEnv: [String: String]) throws -> ServerConfig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-fakeapp-\(UUID().uuidString)")
        let macOSDir = root.appendingPathComponent("Fake.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)

        let responder = macOSDir.appendingPathComponent("responder.py")
        let mcpScript = """
        #!/usr/bin/env python3
        import sys, json

        def write_message(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            method = msg.get('method')
            mid = msg.get('id')
            if method == 'initialize':
                write_message({'jsonrpc': '2.0', 'id': mid, 'result': {
                    'protocolVersion': '2024-11-05', 'capabilities': {},
                    'serverInfo': {'name': 'fake-electron', 'version': '0'}}})
            elif method == 'tools/list':
                write_message({'jsonrpc': '2.0', 'id': mid, 'result': {
                    'tools': [{'name': 'echo', 'description': 'Echo'}]}})
                break
        """
        try mcpScript.write(to: responder, atomically: true, encoding: .utf8)

        let binary = macOSDir.appendingPathComponent("fake")
        let launcher = """
        #!/bin/sh
        if [ "$ELECTRON_RUN_AS_NODE" = "1" ]; then
            exec /usr/bin/python3 "\(responder.path)"
        fi
        echo "GUI booted instead of MCP server" >&2
        exit 66
        """
        try launcher.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        return ServerConfig(
            id: id,
            name: "fake-electron",
            source: .code,
            projectPath: nil,
            transport: .stdio,
            command: binary.path,
            args: [],
            env: configEnv,
            url: nil,
            headers: [:]
        )
    }

    private func removeFakeBundle(for config: ServerConfig) {
        guard let command = config.command else { return }
        // …/<uuid>/Fake.app/Contents/MacOS/fake → remove the <uuid> root.
        let root = URL(fileURLWithPath: command)
            .deletingLastPathComponent()  // MacOS
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // Fake.app
            .deletingLastPathComponent()  // <uuid>
        try? FileManager.default.removeItem(at: root)
    }
}
