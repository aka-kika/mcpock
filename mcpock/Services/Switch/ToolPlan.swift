import Foundation

/// Plans for hiding or showing single tools of one server (Part 2,
/// 2026-11-10): the same sheet, writer, backups and checks as the server
/// switch, each agent's own setting. Building a plan reads files and changes
/// nothing.
enum ToolPlanner {
    /// The plan for hiding `hide` and showing `show` in every declaration in
    /// `configs` (one server's, already narrowed to the agents she kept).
    /// `allTools` is the server's own list from its last check.
    static func plan(
        server: String,
        configs: [ServerConfig],
        hide: [String],
        show: [String],
        allTools: [String],
        claudeSettingsPath: String,
        read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> SwitchPlan {
        struct Step { let mechanism: ToolMechanism; let name: String; let agent: String }
        var order: [String] = []
        var steps: [String: [Step]] = [:]
        var skipped: [String] = []

        for config in configs {
            let agent = AgentBadge.displayLabel(config.source.label)
            guard let mechanism = ToolSwitch.mechanism(agent: config.source.label, configID: config.id, builtin: config.builtin) else {
                if !skipped.contains(agent) { skipped.append(agent) }
                continue
            }
            let path = mechanism == .claudeDeny ? claudeSettingsPath : config.source.path
            if steps[path] == nil { order.append(path) }
            // Claude Code's rules go by name: two projects with it are one step.
            if steps[path]?.contains(where: { $0.name == config.name }) == true { continue }
            steps[path, default: []].append(Step(mechanism: mechanism, name: config.name, agent: config.source.label))
        }

        let hideSet = Set(hide), showSet = Set(show)
        var changes: [SwitchChange] = []
        var problems: [String] = []
        for path in order {
            guard let fileSteps = steps[path], let first = fileSteps.first else { continue }
            let agent = AgentBadge.displayLabel(first.agent)
            let before = read(path)
            do {
                var text = before
                for step in fileSteps {
                    text = try ToolSwitch.edited(text, mechanism: step.mechanism, server: step.name,
                                                 hide: hideSet, show: showSet, allTools: allTools)
                }
                guard let after = text, after != before else { continue }
                changes.append(SwitchChange(
                    agents: [agent],
                    path: path,
                    before: before,
                    after: after,
                    what: what(first.mechanism, hiding: !hide.isEmpty, server: server),
                    when: when(agent: first.agent, hiding: !hide.isEmpty),
                    // Any way but parking: the plain changed lines.
                    diff: SwitchPlanner.diff(before: before, after: after, mechanism: .claudeDeny, server: first.name, turnOn: false)
                ))
            } catch {
                problems.append("\(agent): mcpock can't change its file safely, so it is left alone.")
            }
        }
        return SwitchPlan(server: server, turnOn: hide.isEmpty, changes: changes, skipped: skipped, problems: problems,
                          tools: ToolEdit(hide: hide, show: show))
    }

    /// What happens in the file, in plain words.
    static func what(_ mechanism: ToolMechanism, hiding: Bool, server: String) -> String {
        switch mechanism {
        case .claudeDeny:
            return hiding ? "Goes on Claude Code's deny list." : "Comes off Claude Code's deny list."
        case .codex, .grok, .hermes:
            return hiding ? "Goes on the server's hidden-tools list." : "Comes off the server's hidden-tools list."
        case .openCode:
            return hiding ? "A deny rule for it goes in OpenCode's permissions." : "Its deny rule leaves OpenCode's permissions."
        case .goose:
            return hiding
                ? "Leaves the list of tools Goose may use. A tool \(server) adds later stays hidden in Goose until you show it."
                : "Back on the list of tools Goose may use."
        }
    }

    /// When the agent notices. `agent` is a `ServerSource.label`.
    static func when(agent: String, hiding: Bool) -> String {
        let word = hiding ? "Hidden" : "Back"
        switch agent {
        case AgentRegistry.claudeCodeLabel, "Goose":
            return "\(word) in new sessions"
        case "Hermes":
            return "\(word) after Hermes reloads its servers"
        default:
            return "\(word) from its next run"
        }
    }

    // MARK: Reading

    /// Per declaration of one server (`ServerConfig.id`): the tools hidden
    /// there, or nil when the agent has no way mcpock reads.
    static func hiddenTools(
        configs: [ServerConfig],
        allTools: [String],
        claudeSettingsPath: String,
        read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> [String: Set<String>] {
        var cache: [String: String?] = [:]
        var result: [String: Set<String>] = [:]
        for config in configs {
            guard let mechanism = ToolSwitch.mechanism(agent: config.source.label, configID: config.id, builtin: config.builtin) else {
                continue
            }
            let path = mechanism == .claudeDeny ? claudeSettingsPath : config.source.path
            if cache[path] == nil { cache[path] = .some(read(path)) }
            let text = cache[path] ?? nil
            if let hidden = ToolSwitch.hidden(in: text, mechanism: mechanism, server: config.name, allTools: allTools) {
                result[config.id] = hidden
            }
        }
        return result
    }
}
