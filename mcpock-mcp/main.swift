import Foundation

// mcpock-mcp: mcpock's read-only MCP server (round 7). Speaks MCP over stdio
// (newline-delimited JSON-RPC) and answers from the status file the app writes,
// ~/Library/Application Support/mcpock/status.json. It never probes a server and
// never writes a file. `MCPOCK_STATUS_FILE` points it at another file (tests);
// the old `MCPBAR_STATUS_FILE` (1.6.0 transition) is still read as a fallback.
//
// Bundled at mcpock.app/Contents/Helpers/mcpock-mcp; Settings > Connect copies
// the snippet each agent needs.

let environment = ProcessInfo.processInfo.environment
let statusURL: URL = (environment["MCPOCK_STATUS_FILE"] ?? environment["MCPBAR_STATUS_FILE"])
    .map { URL(fileURLWithPath: $0) }
    ?? MCPockStatus.defaultDirectory().appendingPathComponent(MCPockStatus.fileName)

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("""
        mcpock-mcp: mcpock's read-only MCP server (stdio).
        Add it to an agent's MCP config as a stdio server with this file's path as the command.
        Tools: mcpock_status, mcpock_problems, mcpock_server.
        Reads: \(statusURL.path)
        """)
    exit(0)
}

let server = MCPStatusServer(loadStatus: { StatusLoad.read(from: statusURL) })
let output = FileHandle.standardOutput

while let line = readLine(strippingNewline: true) {
    guard let reply = server.handle(line: line) else { continue }
    output.write(Data((reply + "\n").utf8))
}
