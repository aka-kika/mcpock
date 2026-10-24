import XCTest
@testable import mcpock

/// r3 3c03: servers start with the login shell's PATH and keys.
final class ShellEnvironmentTests: XCTestCase {
    func testParseSkipsWhatAnRcFilePrintsFirst() {
        var data = Data("Welcome back!\nnvm: using node 22\n".utf8)
        data.append(Data("__MCPOCK_ENV__\0PATH=/u/.nvm/bin:/usr/bin\0GITHUB_TOKEN=abc\0MULTI=a\nb\0=bad\0".utf8))
        let env = ShellEnvironment.parse(data)
        XCTAssertEqual(env?["PATH"], "/u/.nvm/bin:/usr/bin")
        XCTAssertEqual(env?["GITHUB_TOKEN"], "abc")
        XCTAssertEqual(env?["MULTI"], "a\nb", "values may hold newlines")
        XCTAssertEqual(env?.count, 3)
        XCTAssertNil(ShellEnvironment.parse(Data("no marker\0A=1\0".utf8)))
    }

    func testMergeKeepsMcpocksSessionKeys() {
        let merged = ShellEnvironment.merge(
            process: ["PATH": "/usr/bin:/bin", "HOME": "/u", "PWD": "/"],
            login: ["PATH": "/u/.volta/bin:/usr/bin", "PWD": "/u", "SHLVL": "2", "OPENAI_API_KEY": "k"])
        XCTAssertEqual(merged["PATH"], "/u/.volta/bin:/usr/bin")
        XCTAssertEqual(merged["PWD"], "/")
        XCTAssertNil(merged["SHLVL"])
        XCTAssertEqual(merged["OPENAI_API_KEY"], "k")
        XCTAssertEqual(merged["HOME"], "/u")
        XCTAssertEqual(ShellEnvironment.merge(process: ["PATH": "/bin"], login: ["PATH": ""])["PATH"], "/bin")
    }

    func testLoginPathKeepsItsOrder() {
        let env = PathResolver.processEnvironment(
            configEnv: [:], base: ["PATH": "/u/.nvm/versions/node/v22/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"])
        XCTAssertTrue(env["PATH"]!.hasPrefix("/u/.nvm/versions/node/v22/bin:"), "nvm's node before Homebrew's")
    }

    func testReadRunsTheShellAndStopsAHungOne() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpock-shellenv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func script(_ name: String, _ body: String) throws -> String {
            let path = dir.appendingPathComponent(name).path
            try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            return path
        }
        let good = try script("good", #"echo hello; printf '__MCPOCK_ENV__\0FROM_SHELL=yes\0'"#)
        XCTAssertEqual(ShellEnvironment.read(shell: good, timeout: 5)?["FROM_SHELL"], "yes")
        let hung = try script("hung", "sleep 30")
        let start = Date()
        XCTAssertNil(ShellEnvironment.read(shell: hung, timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
