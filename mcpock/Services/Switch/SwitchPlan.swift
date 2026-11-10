import AppKit
import Foundation

/// One file the switch is about to change, as the sheet shows it.
struct SwitchChange: Identifiable, Equatable, Sendable {
    var id: String { path }
    /// The agents this file belongs to, as the sheet names them ("Claude Code").
    let agents: [String]
    let path: String
    /// The file as it was read for the sheet; nil when it is not there yet.
    /// A file that changed since is not written.
    let before: String?
    let after: String
    /// "Goes on Claude Code's blocked list."
    let what: String
    /// "Off in new sessions"
    let when: String
    /// The changed lines, `- old` and `+ new`, secrets masked.
    let diff: [String]
    /// Entries that move to or from mcpock's own folder with this change.
    var parked: [ParkedEdit] = []
}

/// The tools a plan hides or shows.
struct ToolEdit: Equatable, Sendable {
    let hide: [String]
    let show: [String]
}

/// One server moving into `ParkedStore` (off) or out of it (on).
struct ParkedEdit: Equatable, Sendable {
    /// The agent's label ("Claude Desktop").
    let agent: String
    let configPath: String
    let name: String
    /// The entry's JSON as the config wrote it; set when it moves in.
    let raw: String?
    var movesIn: Bool { raw != nil }
}

/// Everything one flip of the switch would do: shown first, written only on
/// her click (1.14). Building it reads files and changes nothing.
struct SwitchPlan: Equatable, Sendable {
    let server: String
    let turnOn: Bool
    let changes: [SwitchChange]
    /// Agents that have the server but no switch mcpock can use.
    let skipped: [String]
    /// Agents whose file mcpock would not change, and why.
    let problems: [String]
    /// Set when the plan hides or shows single tools (Part 2) instead of
    /// turning the server off or on.
    var tools: ToolEdit? = nil

    var isEmpty: Bool { changes.isEmpty }

    /// "Turn off openrouter everywhere?" / "Turn on openrouter in Cursor?" /
    /// "Hide delete_repository in github?" / "Show 3 tools of github?"
    var title: String {
        if let tools {
            let names = tools.hide.isEmpty ? tools.show : tools.hide
            let what = names.count == 1 ? names[0] : "\(names.count) tools"
            return tools.hide.isEmpty ? "Show \(what) of \(server) again?" : "Hide \(what) in \(server)?"
        }
        let names = changes.flatMap(\.agents)
        let scope = names.count == 1 ? "in \(names[0])" : "everywhere"
        return "Turn \(turnOn ? "on" : "off") \(server) \(scope)?"
    }

    /// The sheet's button.
    var confirmTitle: String {
        if let tools { return tools.hide.isEmpty ? "Show" : "Hide" }
        return turnOn ? "Turn On" : "Turn Off"
    }

    var reassuranceText: String {
        guard let tools else { return Self.reassurance }
        let names = tools.hide.isEmpty ? tools.show : tools.hide
        if names.count > 1 {
            let lead = tools.hide.isEmpty ? "Your agents see them again" : "Nothing is deleted. Your agents just stop seeing them"
            return lead + ": " + CardText.list(names) + "."
        }
        return tools.hide.isEmpty ? "Your agents see \(tools.show.count == 1 ? "it" : "them") again."
            : "Nothing is deleted. Your agents just stop seeing \(tools.hide.count == 1 ? "it" : "them"). Show \(tools.hide.count == 1 ? "it" : "them") again with one click."
    }

    static let reassurance = "Nothing is deleted. Turning it on puts it back as it was."
    static let backupLine = "A backup of each file is saved first."
}

enum SwitchPlanner {
    /// Apps that read their config only when they start: bundle ids to look for.
    static let appBundleIDs: [String: [String]] = [
        "Claude Desktop": ["com.anthropic.claudefordesktop"],
        "Cursor": ["com.todesktop.230313mzl4w4u92"],
    ]

    @MainActor
    static func isRunning(_ agent: String) -> Bool {
        (appBundleIDs[agent] ?? []).contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// The plan for turning `configs` (declarations of one server) on or off.
    /// Declarations already in that state are left out.
    static func plan(
        server: String,
        configs: [ServerConfig],
        turnOn: Bool,
        claudeSettingsPath: String,
        running: (String) -> Bool,
        parkedDirectory: URL = ParkedStore.defaultDirectory,
        read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> SwitchPlan {
        struct Step { let mechanism: SwitchMechanism; let name: String; let agent: String }
        var order: [String] = []
        var steps: [String: [Step]] = [:]
        var skipped: [String] = []

        for config in configs where config.turnedOff == turnOn {
            let agent = AgentBadge.displayLabel(config.source.label)
            guard let mechanism = ServerSwitch.mechanism(agent: config.source.label, configID: config.id, builtin: config.builtin) else {
                if !skipped.contains(agent) { skipped.append(agent) }
                continue
            }
            let path = mechanism == .claudeDeny ? claudeSettingsPath : config.source.path
            if steps[path] == nil { order.append(path) }
            // Claude Code's list goes by name: two projects with it are one step.
            if steps[path]?.contains(where: { $0.name == config.name }) == true { continue }
            steps[path, default: []].append(Step(mechanism: mechanism, name: config.name, agent: config.source.label))
        }

        var changes: [SwitchChange] = []
        var problems: [String] = []
        for path in order {
            guard let fileSteps = steps[path], let first = fileSteps.first else { continue }
            let agent = AgentBadge.displayLabel(first.agent)
            let before = read(path)
            do {
                var text = before
                var parked: [ParkedEdit] = []
                for step in fileSteps {
                    var parkedValue: String?
                    if step.mechanism == .parkOutside {
                        if turnOn {
                            parkedValue = ParkedStore.entries(agent: step.agent, configPath: path, directory: parkedDirectory)[step.name]
                            parked.append(ParkedEdit(agent: step.agent, configPath: path, name: step.name, raw: nil))
                        } else {
                            guard let raw = text.flatMap({ ServerSwitch.entryText(in: $0, server: step.name) }) else {
                                throw ServerSwitch.SwitchError.cannotEdit
                            }
                            parked.append(ParkedEdit(agent: step.agent, configPath: path, name: step.name, raw: raw))
                        }
                    }
                    text = try ServerSwitch.edited(text, mechanism: step.mechanism, server: step.name, turnOn: turnOn,
                                                   parkedValue: parkedValue)
                }
                guard let after = text, after != before else { continue }
                changes.append(SwitchChange(
                    agents: [agent],
                    path: path,
                    before: before,
                    after: after,
                    what: what(first.mechanism, turnOn: turnOn),
                    when: when(agent: first.agent, turnOn: turnOn, running: running(first.agent)),
                    diff: diff(before: before, after: after, mechanism: first.mechanism, server: first.name, turnOn: turnOn,
                               agent: first.agent),
                    parked: parked
                ))
            } catch {
                problems.append("\(agent): mcpock can't change its file safely, so it is left alone.")
            }
        }
        return SwitchPlan(server: server, turnOn: turnOn, changes: changes, skipped: skipped, problems: problems)
    }

    /// What happens in the file, in plain words.
    static func what(_ mechanism: SwitchMechanism, turnOn: Bool) -> String {
        switch mechanism {
        case .claudeDeny:
            return turnOn ? "Comes off Claude Code's blocked list." : "Goes on Claude Code's blocked list."
        case .openCode, .toml, .yaml:
            return turnOn ? "Marked on in its config." : "Marked off in its config."
        case .park:
            return turnOn ? "Moved back to where it was." : "Parked inside its config, keys and all."
        case .parkOutside:
            return turnOn ? "Moved back into its config from mcpock's folder."
                : "Moved out of its config into mcpock's own folder, keys and all, so the app can't lose it when it rewrites its file."
        }
    }

    /// When the agent notices. `agent` is a `ServerSource.label`.
    static func when(agent: String, turnOn: Bool, running: Bool) -> String {
        let word = turnOn ? "On" : "Off"
        switch agent {
        case AgentRegistry.claudeCodeLabel, "Goose":
            return "\(word) in new sessions"
        case "Hermes":
            return "\(word) after Hermes reloads its servers"
        case "Claude Desktop":
            return running ? "Claude Desktop is open: \(word.lowercased()) after you quit and open it again"
                : "\(word) the next time Claude Desktop opens"
        case "Cursor":
            return running ? "Cursor is open: \(word.lowercased()) after it reopens" : "\(word) the next time Cursor opens"
        default:
            return "\(word) from its next run"
        }
    }

    /// The changed lines, for "Show the exact change". A parked entry is
    /// shown folded: its lines hold the server's keys.
    static func diff(before: String?, after: String, mechanism: SwitchMechanism, server: String, turnOn: Bool,
                     agent: String = "") -> [String] {
        if mechanism == .park {
            let name = JSONSpanEditor.quoted(server)
            let active = "\"mcpServers\": { \(name): {\u{2026}} }"
            let parked = "\"\(ServerSwitch.parkedKey)\": { \(name): {\u{2026}} }"
            return turnOn ? ["- " + parked, "+ " + active] : ["- " + active, "+ " + parked]
        }
        if mechanism == .parkOutside {
            let name = JSONSpanEditor.quoted(server)
            let active = "\"mcpServers\": { \(name): {\u{2026}} }"
            let kept = "mcpock/parked/\(ParkedStore.fileName(forAgent: agent)): \(name)"
            return turnOn ? ["- " + kept, "+ " + active] : ["- " + active, "+ " + kept]
        }
        let old = (before ?? "").components(separatedBy: "\n")
        let new = after.components(separatedBy: "\n")
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        func lines(_ all: [String], _ sign: String) -> [String] {
            all[prefix..<(all.count - suffix)]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { sign + " " + SecretMask.scrub($0) }
        }
        return Array((lines(old, "-") + lines(new, "+")).prefix(10))
    }
}

/// Writes a plan: the only place mcpock changes another app's file. Each file
/// is checked against what the sheet showed, copied to a backup, then
/// replaced in one step.
enum SwitchWriter {
    enum WriteError: Error, Equatable {
        /// The file is not what the sheet showed any more.
        case fileChanged(String)
        case failed(String)
    }

    struct Outcome: Equatable {
        /// The files written, in order.
        var written: [String] = []
        var error: WriteError?
    }

    /// `~/Library/Application Support/mcpock/backups/`
    static var backupDirectory: URL {
        MCPockStatus.defaultDirectory().appendingPathComponent("backups", isDirectory: true)
    }

    /// How many backups stay; the oldest go first.
    static let keptBackups = 60

    /// Stops at the first file that can't be written; the ones before it stay
    /// written (each is whole and backed up).
    static func apply(_ plan: SwitchPlan, backups: URL = backupDirectory, parked: URL = ParkedStore.defaultDirectory,
                      now: Date = Date()) -> Outcome {
        var outcome = Outcome()
        for change in plan.changes {
            do {
                // An entry that leaves its config is in mcpock's folder first,
                // so no failure in between can lose it.
                guard change.parked.isEmpty || allowed(parked) else { throw WriteError.failed(change.path) }
                let movingIn = change.parked.filter(\.movesIn)
                for edit in movingIn {
                    try ParkedStore.add(name: edit.name, raw: edit.raw ?? "", agent: edit.agent, configPath: edit.configPath,
                                        directory: parked)
                }
                do {
                    try write(change, backups: backups, now: now)
                } catch {
                    for edit in movingIn { try? ParkedStore.remove(name: edit.name, agent: edit.agent, directory: parked) }
                    throw error
                }
                // Back in its config: it leaves the folder.
                for edit in change.parked where !edit.movesIn {
                    try? ParkedStore.remove(name: edit.name, agent: edit.agent, directory: parked)
                }
                outcome.written.append(change.path)
            } catch let error as WriteError {
                outcome.error = error
                break
            } catch {
                outcome.error = .failed(change.path)
                break
            }
        }
        prune(backups)
        return outcome
    }

    static func write(_ change: SwitchChange, backups: URL, now: Date) throws {
        let fm = FileManager.default
        // A config kept as a symlink (dotfiles) is changed where it really is.
        let target = URL(fileURLWithPath: change.path).resolvingSymlinksInPath()
        guard allowed(target) else { throw WriteError.failed(change.path) }
        let exists = fm.fileExists(atPath: target.path)
        let current = exists ? try? String(contentsOf: target, encoding: .utf8) : nil
        guard current == change.before, exists == (change.before != nil) else { throw WriteError.fileChanged(change.path) }

        var permissions: NSNumber = 0o600
        if exists {
            permissions = (try? fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber) ?? 0o600
            try fm.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let copy = backups.appendingPathComponent(backupName(for: target, agent: change.agents.first ?? "", now: now))
            let copyTemp = backups.appendingPathComponent(".\(copy.lastPathComponent).mcpock-\(UUID().uuidString)")
            do {
                try writeNew(Data(contentsOf: target), to: copyTemp, mode: 0o600)
                guard rename(copyTemp.path, copy.path) == 0 else { throw WriteError.failed(change.path) }
            } catch {
                try? fm.removeItem(at: copyTemp)
                throw WriteError.failed(change.path)
            }
        } else {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        removeLeftovers(of: target, now: now)
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).mcpock-\(UUID().uuidString)")
        do {
            try writeNew(Data(change.after.utf8), to: temp, mode: mode_t(permissions.uint16Value))
            guard rename(temp.path, target.path) == 0 else { throw WriteError.failed(change.path) }
        } catch {
            try? fm.removeItem(at: temp)
            throw WriteError.failed(change.path)
        }
    }

    /// A new file made 0600 from its first byte (the config may hold keys),
    /// set to `mode` only once it is whole. It must not exist yet; on any
    /// failure it is removed (review 10 Nov, fable-6 / mcode-6).
    static func writeNew(_ data: Data, to url: URL, mode: mode_t) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WriteError.failed(url.path) }
        var done = false
        defer {
            close(fd)
            if !done { unlink(url.path) }
        }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let wrote = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if wrote < 0 {
                    if errno == EINTR { continue }
                    throw WriteError.failed(url.path)
                }
                offset += wrote
            }
        }
        guard fsync(fd) == 0, fchmod(fd, mode & 0o7777) == 0 else { throw WriteError.failed(url.path) }
        done = true
    }

    /// Temp files of an earlier write that never finished (mcpock quit
    /// between write and rename): ".<name>.mcpock-<uuid>", at least a minute old.
    static func removeLeftovers(of target: URL, now: Date) {
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        let prefix = ".\(target.lastPathComponent).mcpock-"
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil {
            let file = folder.appendingPathComponent(name)
            let changed = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? now
            if now.timeIntervalSince(changed) >= 60 { try? fm.removeItem(at: file) }
        }
    }

    /// "20261110-101500-claude-code-settings.json"
    static func backupName(for file: URL, agent: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let slug = agent.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "\(formatter.string(from: now))-\(String(slug))-\(file.lastPathComponent)"
    }

    private static func prune(_ backups: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: backups.path) else { return }
        // Names start with the time, so sorted is oldest first.
        for name in names.sorted().dropLast(keptBackups) {
            try? fm.removeItem(at: backups.appendingPathComponent(name))
        }
    }

    /// While the app hosts its unit tests it runs on the developer's own Mac:
    /// only files in a temporary folder may be written, never a real config.
    static func allowed(_ file: URL) -> Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else { return true }
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return file.path.hasPrefix(temp.hasSuffix("/") ? temp : temp + "/")
    }
}
