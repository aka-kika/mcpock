import CryptoKit
import Foundation

/// "Set up differently" detection for one display row (v1.5 spec, Phase 1 item 2).
///
/// A server name declared in several agents usually launches the same thing
/// everywhere. When one agent points somewhere else (an old build path, another
/// URL), the row can still look healthy while that agent quietly runs a different
/// server. This names the odd one out so the panel can say "Set up differently in
/// Grok" instead of leaving you to diff five config files by hand.
///
/// What counts is the **launch target** only: stdio compares command + args
/// (after `PathResolver.normalizedLaunchCommand`), http/sse compares the URL.
/// Env and headers are ignored on purpose (API keys legitimately differ per agent),
/// and so is `projectPath` (a per-project working directory is not a different
/// server). A plain enum: every function here is pure and nonisolated.
///
/// Round 6: agents that launch servers their own way (aka: every bare package
/// name runs through `bun x -y`, see `AkaSource`) never take part. Their
/// declarations are neither the odd one out nor part of the majority; their
/// real errors still show like any other source's.
enum Differs {
    /// Source labels left out of the comparison (round 6: aka).
    static let ownLaunchAgents: Set<String> = [AkaSource.label]

    /// False for an agent that launches servers its own way.
    static func isCompared(agent: String) -> Bool {
        !ownLaunchAgents.contains(agent)
    }

    /// The declarations that take part. A `builtin` server runs inside its
    /// own app, so its declaration says nothing about how it launches: never
    /// compared (review, 2026-10-14).
    static func compared(_ configs: [ServerConfig]) -> [ServerConfig] {
        configs.filter { !$0.builtin && isCompared(agent: $0.source.label) }
    }

    /// A normalised launch target. Two declarations with equal targets launch the
    /// same thing, whatever their env, headers or working directory.
    struct LaunchTarget: Hashable, Sendable {
        let parts: [String]
    }

    /// Runtimes and package runners that launch something else (1.9.0,
    /// 2026-10-03). Which copy runs them is the agent's business: one agent may
    /// use its own bundled `~/.agent/node/bin/npx` where the others say `npx`, and both start the
    /// same package. For these only the file name counts; the args still do.
    static let launchers: Set<String> = [
        "node", "npx", "bun", "bunx", "uv", "uvx", "python", "python3", "deno",
    ]

    /// The command as the comparison sees it: a known launcher by its name
    /// alone, anything else by its normalised path.
    static func comparedCommand(_ command: String) -> String {
        let normalized = PathResolver.normalizedLaunchCommand(command)
        let name = (normalized as NSString).lastPathComponent
        return launchers.contains(name) ? name : normalized
    }

    /// Secrets are masked before comparing (Argon 2026-10-16 #9): two agents
    /// that pass their own API key (`--api-key`, `?apiKey=`) launch the same
    /// server, and Compare shows both as the same masked line.
    static func launchTarget(_ config: ServerConfig) -> LaunchTarget {
        let known = SecretMask.knownSecrets(of: config)
        switch config.transport {
        case .stdio:
            let command = comparedCommand(config.command ?? "")
            var previous: String?
            let args = runnerArgs(config.args, command: command).map { arg -> String in
                defer { previous = arg }
                return SecretMask.maskArgument(PathResolver.expandTilde(arg), after: previous, known: known)
            }
            return LaunchTarget(parts: ["stdio", command] + args)
        case .http, .sse:
            // http and sse share one key: the same URL is the same server even
            // when one agent spells the transport differently.
            return LaunchTarget(parts: ["url", normalizedURL(SecretMask.url(config.url ?? "", known: known))])
        }
    }

    /// Package runners' spelling that changes nothing about what runs (r3
    /// e59e): `npx -y pkg` and `npx pkg@latest` start the same server, so
    /// `-y` / `--yes` and a trailing `@latest` are left out of the comparison.
    static func runnerArgs(_ args: [String], command: String) -> [String] {
        guard ["npx", "bunx", "bun", "pnpm", "uvx"].contains(command) else { return args }
        return args
            .filter { $0 != "-y" && $0 != "--yes" }
            .map { $0.hasSuffix("@latest") && $0.count > "@latest".count ? String($0.dropLast("@latest".count)) : $0 }
    }

    /// Trims whitespace and a trailing slash, so `…/mcp` and `…/mcp/` match.
    static func normalizedURL(_ url: String) -> String {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    /// The sources whose target differs from the majority, one note per display
    /// label, in input order. Empty when every declaration agrees (or there is only
    /// one). With no strict majority (a 1-vs-1 or 2-vs-2 split) there is no "right"
    /// setup to measure against, so every source is named.
    static func detect(_ allConfigs: [ServerConfig]) -> [DiffNote] {
        let configs = compared(allConfigs)
        guard configs.count > 1 else { return [] }
        let targets = configs.map(launchTarget)
        guard Set(targets).count > 1 else { return [] }
        let majority = majorityTarget(targets)

        var notes: [DiffNote] = []
        var seen = Set<String>()
        for (config, target) in zip(configs, targets) where target != majority {
            guard seen.insert(config.displaySource).inserted else { continue }
            notes.append(DiffNote(label: config.displaySource, target: SecretMask.target(of: config)))
        }
        return notes
    }

    /// The one target most declarations share, or nil on a tie.
    static func majorityTarget(_ targets: [LaunchTarget]) -> LaunchTarget? {
        var counts: [LaunchTarget: Int] = [:]
        for target in targets { counts[target, default: 0] += 1 }
        let top = counts.values.max() ?? 0
        let leaders = counts.filter { $0.value == top }.map(\.key)
        return leaders.count == 1 ? leaders[0] : nil
    }

    // MARK: - Marked as intended (1.5.2)

    /// A short, one-way fingerprint of one launch target: the first 16 hex
    /// digits of the SHA-256 of its parts. Hashed so the saved preference never
    /// holds a command line or URL (a URL can carry a token in its query), and
    /// built from exactly what `launchTarget` compares, so env and header values
    /// never take part.
    static func fingerprint(_ target: LaunchTarget) -> String {
        let joined = target.parts.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The SET of launch targets behind one row, as sorted fingerprints: what
    /// "Mark as intended" remembers. Only the sources `detect` compares count
    /// (aka is left out), and a target shared by several agents counts once, so
    /// a new agent that copies an existing setup keeps the acknowledgement while
    /// a new, removed or changed target breaks it.
    static func fingerprints(_ configs: [ServerConfig]) -> [String] {
        let compared = Self.compared(configs)
        return Set(compared.map { fingerprint(launchTarget($0)) }).sorted()
    }

    // MARK: - Marked as intended, per agent (1.9.0)

    /// One agent's setup as "Mark as intended" remembers it since 1.9.0:
    /// "<fingerprint>:<display label>". Per agent, so the mark no longer falls
    /// off when an agent is removed (a 1.5.2 mark on a server with four
    /// per-agent wrappers fell off when one wrapper went away): only an agent whose own setup is new or
    /// changed brings the note back, and only for that agent.
    static func acknowledgement(_ config: ServerConfig) -> String {
        fingerprint(launchTarget(config)) + ":" + config.displaySource
    }

    /// Every compared agent's acknowledgement for one row, sorted, once each.
    /// Marking saves all of them, the majority too, so a later split (an agent
    /// removed, no majority left) still reads as intended.
    static func acknowledgements(_ configs: [ServerConfig]) -> [String] {
        let compared = Self.compared(configs)
        return Set(compared.map(acknowledgement)).sorted()
    }

    /// Splits `detect`'s notes into the ones still open and the ones she marked
    /// as intended. A note is marked when every declaration behind its label
    /// is in `saved`, as "<fingerprint>:<label>" or, for a mark saved before
    /// 1.9.0 (bare fingerprints, no label), by its fingerprint alone, and the
    /// setup it differs from (the majority) is one she saw when marking: an
    /// agent that kept its old setup while the others moved to a new one used
    /// to stay quiet (Argon 2026-10-17 #14).
    static func split(
        _ notes: [DiffNote],
        configs: [ServerConfig],
        saved: [String]?
    ) -> (open: [DiffNote], acknowledged: [DiffNote]) {
        guard let saved, !saved.isEmpty, !notes.isEmpty else { return (notes, []) }
        let savedSet = Set(saved)
        let compared = Self.compared(configs)
        let savedFingerprints = Set(saved.map { $0.split(separator: ":", maxSplits: 1).first.map(String.init) ?? $0 })
        let majorityKnown = majorityTarget(compared.map(launchTarget))
            .map { savedFingerprints.contains(fingerprint($0)) } ?? true
        var open: [DiffNote] = []
        var acknowledged: [DiffNote] = []
        for note in notes {
            let mine = compared.filter { $0.displaySource == note.label }
            let marked = majorityKnown && !mine.isEmpty && mine.allSatisfy {
                savedSet.contains(acknowledgement($0)) || savedSet.contains(fingerprint(launchTarget($0)))
            }
            if marked { acknowledged.append(note) } else { open.append(note) }
        }
        return (open, acknowledged)
    }

    /// What marking a row saves: today's acknowledgements, plus the saved
    /// ones of agents that are away right now (an app not installed on this
    /// Mac today), so they keep their mark. An agent here now gets only its
    /// setup of today: its older ones are replaced, so going back to an old
    /// setup brings the note back (Argon 2026-10-17 #14). Pre-1.9.0 bare
    /// fingerprints are dropped: the new entries cover what is there now.
    static func marking(_ configs: [ServerConfig], over saved: [String]?) -> [String] {
        let present = Set(compared(configs).map(\.displaySource))
        let kept = (saved ?? []).filter { entry in
            guard let colon = entry.firstIndex(of: ":") else { return false }
            return !present.contains(String(entry[entry.index(after: colon)...]))
        }
        return Set(kept + acknowledgements(configs)).sorted()
    }
}
