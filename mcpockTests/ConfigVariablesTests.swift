import XCTest
@testable import mcpock

/// Review 2026-10-20 (0d87): `${VAR}`, `${env:VAR}` and `${workspaceFolder}`
/// are filled in before a check, as the agent does; one that can't be leaves
/// the server unchecked (amber, with the reason), never started with the
/// literal text.
final class ConfigVariablesTests: XCTestCase {
    private let env = ["TOKEN": "t0k", "HOME": "/Users/k", "EMPTY": ""]

    private func expand(_ text: String, project: String? = nil) -> (String, [String]) {
        var missing: [String] = []
        let out = ConfigVariables.expand(text, environment: env, projectPath: project, missing: &missing)
        return (out, missing)
    }

    func testSpellings() {
        XCTAssertEqual(expand("Bearer ${TOKEN}").0, "Bearer t0k")
        XCTAssertEqual(expand("${env:TOKEN}").0, "t0k")
        XCTAssertEqual(expand("${NOPE:-fallback}").0, "fallback")
        XCTAssertEqual(expand("${EMPTY:-fallback}").0, "fallback")
        XCTAssertEqual(expand("${TOKEN:-fallback}").0, "t0k")
        XCTAssertEqual(expand("${workspaceFolder}/src", project: "/p/app").0, "/p/app/src")
        XCTAssertEqual(expand("${workspaceFolderBasename}", project: "/p/app").0, "app")
        XCTAssertEqual(expand("no vars, $TOKEN stays").0, "no vars, $TOKEN stays")
        XCTAssertEqual(expand("broken ${TOKEN").0, "broken ${TOKEN")
        XCTAssertEqual(expand("${HOME}:${TOKEN}").0, "/Users/k:t0k")
    }

    func testWhatCannotBeFilledIsKept() {
        XCTAssertEqual(expand("${NOPE}").0, "${NOPE}")
        XCTAssertEqual(expand("${NOPE}").1, ["${NOPE}"])
        XCTAssertEqual(expand("${input:apiKey}").1, ["${input:apiKey}"])
        XCTAssertEqual(expand("${workspaceFolder}").1, ["${workspaceFolder}"], "no project open")
        XCTAssertEqual(expand("${env:NOPE}").1, ["${env:NOPE}"])
    }

    func testWholeConfigAndReasons() {
        var config = ServerConfig(
            id: "x", name: "gh", source: .code, projectPath: "/p/app", transport: .stdio,
            command: "${workspaceFolder}/bin/server", args: ["--token", "${TOKEN}"],
            env: ["KEY": "${env:TOKEN}"], url: nil, headers: [:])
        config.headersHelper = "echo ${TOKEN}"
        let done = ConfigVariables.expand(config, environment: env)
        XCTAssertTrue(done.unresolved.isEmpty)
        XCTAssertEqual(done.config.command, "/p/app/bin/server")
        XCTAssertEqual(done.config.args, ["--token", "t0k"])
        XCTAssertEqual(done.config.env, ["KEY": "t0k"])
        XCTAssertEqual(done.config.headersHelper, "echo ${TOKEN}", "the helper's shell expands its own")

        let http = ServerConfig(
            id: "y", name: "api", source: .cursor, projectPath: nil, transport: .http,
            command: nil, args: [], env: [:], url: "https://x.test/${NOPE}",
            headers: ["Authorization": "Bearer ${NOPE}", "X": "${input:k}"])
        let left = ConfigVariables.expand(http, environment: env)
        XCTAssertEqual(Set(left.unresolved), ["${NOPE}", "${input:k}"])
        XCTAssertEqual(left.unresolved.filter { $0 == "${NOPE}" }.count, 1, "named once")
        let envOnly = ServerConfig(
            id: "e", name: "e", source: .cursor, projectPath: nil, transport: .stdio,
            command: "npx", args: [], env: ["KEY": "${env:NOPE}", "OK": "${TOKEN}"], url: nil, headers: [:])
        let started = ConfigVariables.expand(envOnly, environment: env)
        XCTAssertTrue(started.unresolved.isEmpty, "a missing env value does not stop the check")
        XCTAssertEqual(started.config.env, ["KEY": "${env:NOPE}", "OK": "t0k"])
        XCTAssertTrue(ConfigVariables.reason(for: ["${input:k}"]).contains("asks you"))
        XCTAssertTrue(ConfigVariables.reason(for: ["${workspaceFolder}"]).contains("open project"))
        XCTAssertTrue(ConfigVariables.reason(for: ["${NOPE}"]).hasPrefix(ConfigVariables.reasonPrefix))
    }

    /// A server whose variable is missing is never started.
    func testUnfilledServerIsNotStarted() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-var-\(UUID().uuidString)")
        let config = ServerConfig(
            id: "z", name: "z", source: .code, projectPath: nil, transport: .stdio,
            command: "/usr/bin/touch", args: [marker.path, "${MCPOCK_SURELY_UNSET_VAR}"], env: [:],
            url: nil, headers: [:])
        let result = await HealthMonitor.probeServer(config: config, fetchTools: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "not started")
        XCTAssertTrue(result.needsAttention)
        XCTAssertEqual(HealthMonitor.smoothedState(probe: result.state, transientFailure: false,
                                                   needsAttention: true, priorFailures: 0).state, .degraded)
        let reason = try XCTUnwrap(result.failureReason)
        XCTAssertEqual(ShortReason.from(reason, state: .degraded), "Not checked: uses ${MCPOCK_SURELY_UNSET_VAR}")

        let group = ServerGroup(
            name: "z", state: .degraded, sourceLabels: ["Code"], tools: [],
            issues: [ServerIssue(label: "Code", reason: reason, command: "x")], variantCount: 1, differs: [],
            lastChecked: nil)
        XCTAssertTrue(group.needsVariable)
        XCTAssertFalse(group.needsSignIn)
        XCTAssertEqual(PanelText.summary([group]), "1 server \u{00B7} 1 not checked")
        XCTAssertEqual(StatusSnapshot.statusWords(group), "not checked")
        XCTAssertEqual(CardText.whyTitle(for: group), "Why it is not checked")
    }
}
