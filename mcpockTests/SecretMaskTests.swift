import XCTest
@testable import mcpock

/// Round 7: nothing secret may reach `status.json`. These pin down the masking
/// of command lines, URLs and free text.
final class SecretMaskTests: XCTestCase {
    private let dots = SecretMask.dots

    func testSecretFlagValuesAreMasked() {
        let line = SecretMask.commandLine(
            command: "npx",
            args: ["-y", "firecrawl-mcp", "--api-key", "fc-1234567890abcdef1234", "--token=abc123secret", "--port", "8080"]
        )
        XCTAssertEqual(line, "npx -y firecrawl-mcp --api-key \(dots) --token=\(dots) --port 8080")
    }

    func testHeaderArgumentsKeepNamesOnly() {
        let line = SecretMask.commandLine(
            command: "npx",
            args: ["mcp-remote", "https://mcp.example.com/sse", "--header", "Authorization: Bearer abcdef123456"]
        )
        XCTAssertEqual(line, "npx mcp-remote https://mcp.example.com/sse --header Authorization: \(dots)")
        XCTAssertFalse(line.contains("abcdef123456"))
    }

    func testEnvStyleArgumentsAreMasked() {
        let line = SecretMask.commandLine(command: "env", args: ["GITHUB_TOKEN=ghp_abcdefghijklmnop1234", "DEBUG=1", "server"])
        XCTAssertEqual(line, "env GITHUB_TOKEN=\(dots) DEBUG=1 server")
    }

    func testTokenLookingArgumentsAreMasked() {
        let line = SecretMask.commandLine(command: "run", args: ["sk-proj-abcdefghijklmnopqrstuvwxyz", "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8"])
        XCTAssertEqual(line, "run \(dots) \(dots)")
    }

    func testOrdinaryArgumentsAndPathsStay() {
        let args = ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Documents/some-long-folder-name-here", "--stdio"]
        XCTAssertEqual(SecretMask.commandLine(command: "npx", args: args), "npx " + args.joined(separator: " "))
    }

    func testKnownValuesAreMaskedWhereverTheyAppear() {
        let known = SecretMask.knownSecrets(env: ["API_KEY": "hunter2hunter2", "PORT": "8080", "HOME_DIR": "/Users/k"],
                                            headers: ["Authorization": "Bearer tok_live_998877"])
        XCTAssertTrue(known.contains("hunter2hunter2"))
        XCTAssertTrue(known.contains("tok_live_998877"), "the bearer token alone is known too")
        XCTAssertFalse(known.contains("8080"), "short values are left alone")
        XCTAssertFalse(known.contains("/Users/k"))

        let line = SecretMask.commandLine(command: "server", args: ["--x", "prefix-hunter2hunter2"], known: known)
        XCTAssertFalse(line.contains("hunter2hunter2"))
        let text = SecretMask.scrub("Auth failed for tok_live_998877", known: known)
        XCTAssertFalse(text.contains("tok_live_998877"))
    }

    func testURLsKeepHostAndPathButLoseSecrets() {
        XCTAssertEqual(SecretMask.url("http://127.0.0.1:8742/mcp"), "http://127.0.0.1:8742/mcp")
        let masked = SecretMask.url("https://user:pa55word@example.com/mcp?api_key=abc123&mode=x#frag")
        XCTAssertFalse(masked.contains("pa55word"))
        XCTAssertFalse(masked.contains("abc123"))
        XCTAssertTrue(masked.contains("example.com/mcp"))
        XCTAssertTrue(masked.contains("api_key=\(dots)"))
        let pathToken = SecretMask.url("https://mcp.zapier.com/api/mcp/s/ZjA1YTk0NDEtYWM0ZC00ODk2LWE1ZDAtOTk2/sse")
        XCTAssertEqual(pathToken, "https://mcp.zapier.com/api/mcp/s/\(dots)/sse")
    }

    func testFreeTextScrubsBearerKeyValueAndURLs() {
        let text = SecretMask.scrub(
            "HTTP 401: invalid token=abcd1234efgh, sent Authorization: Bearer xyz987654321 to https://h.io/x?key=zzz999"
        )
        XCTAssertFalse(text.contains("abcd1234efgh"))
        XCTAssertFalse(text.contains("xyz987654321"))
        XCTAssertFalse(text.contains("zzz999"))
        XCTAssertTrue(text.hasPrefix("HTTP 401: invalid token="))
    }

    func testPlainReasonsSurvive() {
        let reasons = [
            "Spawn error: Command not found: xapi-mcp",
            "Non-zero exit (1) — Error: Cannot find module '/Users/k/server/index.js'",
            "Needs authentication (HTTP 401)",
            "Timed out after 10s",
        ]
        for reason in reasons {
            XCTAssertEqual(SecretMask.scrub(reason), reason)
        }
    }

    /// Argon 2026-10-16 #10: a key in the URL's user name was kept whenever a
    /// password was there too.
    func testURLUserIsMaskedEvenWithAPassword() {
        let masked = SecretMask.url("https://sk_live_abcdef1234567890:x-oauth-basic@api.example.com/mcp")
        XCTAssertFalse(masked.contains("sk_live_abcdef1234567890"))
        XCTAssertFalse(masked.contains("x-oauth-basic"))
        XCTAssertTrue(masked.contains("api.example.com/mcp"))
    }

    /// A URL-valued env var (`WEBHOOK_URL`) carries its secrets into places
    /// where the URL itself never appears.
    func testURLEnvValuesYieldTheirSecretParts() {
        let known = SecretMask.knownSecrets(
            env: ["WEBHOOK_URL": "https://hooks.example.com/in?sig=s1gn4ture99", "DB": "postgres://admin:pa55w0rdX@db/x"],
            headers: [:]
        )
        let text = SecretMask.scrub("posted s1gn4ture99, then pa55w0rdX failed", known: known)
        XCTAssertFalse(text.contains("s1gn4ture99"))
        XCTAssertFalse(text.contains("pa55w0rdX"))
    }

    /// r3 ed08: plain values under plain names stay readable, even in a URL.
    func testPlainEnvValuesAreNotMasked() {
        let known = SecretMask.knownSecrets(env: ["AWS_REGION": "us-east-1", "NODE_ENV": "staging",
                                                  "GITHUB_TOKEN": "ghp_short1"], headers: [:])
        XCTAssertFalse(known.contains("us-east-1"))
        XCTAssertFalse(known.contains("staging"))
        XCTAssertTrue(known.contains("ghp_short1"))
        XCTAssertEqual(SecretMask.scrub("https://s3.us-east-1.amazonaws.com", known: known),
                       "https://s3.us-east-1.amazonaws.com")
    }

    /// r3 d791: a short key in the server's own URL is masked in every error
    /// text, and a reply body is masked before it is kept.
    func testURLSecretsReachEveryScrub() {
        let config = ServerConfig(id: "x", name: "x", source: ServerSource(label: "Code"), projectPath: nil,
                                  transport: .http, command: nil, args: [], env: [:],
                                  url: "https://mcp.example.com/mcp?k=abc123xyz", headers: [:])
        let known = SecretMask.knownSecrets(of: config)
        XCTAssertTrue(known.contains("abc123xyz"))
        XCTAssertFalse(SecretMask.scrub("Protocol error: bad session for abc123xyz", known: known).contains("abc123xyz"))
        let reply = ProbeError.httpError(500, "Authorization: Bearer sk-abcdefghijklmnop1234").errorDescription ?? ""
        XCTAssertFalse(reply.contains("sk-abcdefghijklmnop1234"))
    }
}
