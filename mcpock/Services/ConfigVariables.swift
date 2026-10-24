import Foundation

/// Fills in the variables agents expand in a server entry before they start
/// it (review 2026-10-20, 0d87), so the check runs what the agent runs:
///
/// - `${VAR}` and `${VAR:-default}`: Claude Code's `.mcp.json` and
///   `~/.claude.json`;
/// - `${env:VAR}`: VS Code and Cursor;
/// - `${workspaceFolder}`, `${workspaceFolderBasename}`: the project folder,
///   known only for a project-scoped entry; `${userHome}`, `${pathSeparator}`.
///
/// Applied to the command, args, env values, URL and header values, for the
/// probe only: the config itself is never changed and the panel, Compare and
/// Copy keep the text as written. Values come from the login shell's
/// environment (`ShellEnvironment`), like a terminal agent's. A variable that can't be filled
/// (`${input:…}` asks the user, a workspace folder with no project open, a
/// variable mcpock's environment does not have) in the command, args, URL or
/// headers leaves the server unchecked with that reason instead of starting
/// it with the literal text; in an env value it is only kept as written.
enum ConfigVariables {
    struct Expanded {
        let config: ServerConfig
        /// Variables left as written, as they appear (`${GITHUB_TOKEN}`), in order.
        let unresolved: [String]
    }

    static func expand(
        _ config: ServerConfig,
        environment: [String: String] = ShellEnvironment.current
    ) -> Expanded {
        var missing: [String] = []
        func fill(_ text: String) -> String {
            expand(text, environment: environment, projectPath: config.projectPath, missing: &missing)
        }
        // An env value mcpock can't fill keeps its text and the server still
        // starts, as before 1.10.9: most servers start without their key and
        // ask for it only when a tool runs, so their check stays meaningful.
        func fillEnv(_ text: String) -> String {
            var ignored: [String] = []
            return expand(text, environment: environment, projectPath: config.projectPath, missing: &ignored)
        }
        var copy = ServerConfig(
            id: config.id, name: config.name, source: config.source, projectPath: config.projectPath,
            transport: config.transport,
            command: config.command.map(fill),
            args: config.args.map(fill),
            env: config.env.mapValues(fillEnv),
            url: config.url.map(fill),
            headers: config.headers.mapValues(fill),
            builtin: config.builtin
        )
        copy.headersHelper = config.headersHelper
        var seen = Set<String>()
        return Expanded(config: copy, unresolved: missing.filter { seen.insert($0).inserted })
    }

    /// One string with every `${…}` it knows replaced; unknown ones stay and
    /// are added to `missing`.
    static func expand(
        _ text: String, environment: [String: String], projectPath: String?, missing: inout [String]
    ) -> String {
        guard text.contains("${") else { return text }
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "${") {
            result += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].firstIndex(of: "}") else {
                result += rest[start.lowerBound...]
                return result
            }
            let name = String(rest[start.upperBound..<end])
            let whole = "${\(name)}"
            if let value = value(of: name, environment: environment, projectPath: projectPath) {
                result += value
            } else {
                result += whole
                missing.append(whole)
            }
            rest = rest[rest.index(after: end)...]
        }
        return result + rest
    }

    private static func value(of name: String, environment: [String: String], projectPath: String?) -> String? {
        let project = projectPath.map(PathResolver.expandTilde).flatMap { $0.isEmpty ? nil : $0 }
        switch name {
        case "workspaceFolder", "workspaceRoot": return project
        case "workspaceFolderBasename": return project.map { ($0 as NSString).lastPathComponent }
        case "userHome": return NSHomeDirectory()
        case "pathSeparator", "/": return "/"
        default: break
        }
        if name.hasPrefix("env:") { return environment[String(name.dropFirst(4))] }
        if name.contains(":") && !name.contains(":-") { return nil }   // ${input:…}, ${config:…}, ${command:…}
        // `${VAR:-default}`: the default when VAR is unset or empty.
        if let dash = name.range(of: ":-") {
            let variable = String(name[..<dash.lowerBound])
            guard isVariableName(variable) else { return nil }
            if let set = environment[variable], !set.isEmpty { return set }
            return String(name[dash.upperBound...])
        }
        guard isVariableName(name) else { return nil }
        return environment[name]
    }

    private static func isVariableName(_ name: String) -> Bool {
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// Every reason below starts with this; `ServerGroup.needsVariable` reads it.
    static let reasonPrefix = "Uses ${"

    /// The reason a server with unfilled variables was not checked.
    static func reason(for unresolved: [String]) -> String {
        let list = unresolved.joined(separator: ", ")
        if unresolved.contains(where: { $0.hasPrefix("${input:") }) {
            return "Uses \(list): your agent asks you for it when it starts the server, so mcpock does not check it"
        }
        if unresolved.contains(where: { $0.hasPrefix("${workspaceFolder") || $0 == "${workspaceRoot}" }) {
            return "Uses \(list): filled in only inside an open project, so mcpock does not check it"
        }
        return "Uses \(list), which is not set where mcpock runs, so it was not checked. Your agent fills it in from its own environment"
    }
}
