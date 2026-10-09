import Foundation

/// The one-line reason under a "Needs you" row (v1.5): "Could not start: command
/// not found", "Needs sign-in", "Set up differently in Grok". The full text lives
/// in the detail card; this is only what you need to scan the list.
///
/// It maps the known `ProbeError` wordings (plus the stdio probe's " — <stderr>"
/// tail) to plain words, and falls back to the first 60 characters for anything
/// it doesn't recognise, so a new failure never shows up blank. Pure.
enum ShortReason {
    /// Longest fallback line before it is cut with an ellipsis.
    static let fallbackLength = 60

    /// The short line for a whole row, or nil when the row doesn't need one.
    /// Uses the first failing source's reason; a row that only differs names the
    /// odd one out.
    static func line(for group: ServerGroup) -> String? {
        switch group.state {
        case .broken, .degraded:
            if let reason = group.issues.first?.reason {
                return from(reason, state: group.state)
            }
            return group.state == .broken ? "Broken" : "Slow"
        case .healthy:
            return group.differsNeedsAttention ? differs(group.differs) : nil
        // Unknown rows sit in their normal section with the unknown ring (they
        // never need you), so they get no second line.
        case .unknown, .selfManaged, .paused:
            return nil
        }
    }

    /// Map one `failureReason` to a short line. `state` only changes the wording of
    /// a timeout: the first one is amber ("Slow"), a repeat is red.
    static func from(_ reason: String, state: HealthState) -> String {
        // The stdio probe appends " — <stderr tail>" to its head; the head is the
        // part with a known shape.
        let head = reason.components(separatedBy: " — ").first ?? reason
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("Needs authentication") {
            return "Needs sign-in"
        }
        if let rest = trimmed.dropPrefix("Spawn error: ") {
            if rest.hasPrefix("Command not found") { return "Could not start: command not found" }
            if rest.hasPrefix("Not executable") { return "Could not start: not executable" }
            if rest.hasPrefix("Missing command") { return "Could not start: no command set" }
            return clip("Could not start: \(rest)")
        }
        if let rest = trimmed.dropPrefix("Timed out after ") {
            var seconds = rest.hasSuffix("s") ? String(rest.dropLast()) : rest
            // The HTTP probe writes "10.0s", the stdio probe "10s": read both as "10 s".
            if seconds.hasSuffix(".0") { seconds = String(seconds.dropLast(2)) }
            return state == .degraded
                ? "Slow: no answer in \(seconds) s"
                : "No answer in \(seconds) s"
        }
        if let rest = trimmed.dropPrefix("Non-zero exit (") {
            let code = rest.hasSuffix(")") ? String(rest.dropLast()) : rest
            return "Quit on start (exit \(code))"
        }
        if trimmed.hasPrefix("Handshake rejected") {
            return "Refused the handshake"
        }
        if trimmed.hasPrefix("Invalid URL") {
            return "Bad address in config"
        }
        if trimmed.hasPrefix("Protocol error") {
            return "Unexpected reply"
        }
        if trimmed.hasPrefix("No response from server") {
            return "No response"
        }
        if let rest = trimmed.dropPrefix("HTTP ") {
            let code = rest.prefix { $0.isNumber }
            if !code.isEmpty { return "Server error (HTTP \(code))" }
        }
        return clip(reason)
    }

    /// "Set up differently in Grok", "… in Grok and Cursor", "… in 3 agents".
    /// Labels read as people say them: "Claude Code", not the registry's "Code".
    static func differs(_ notes: [DiffNote]) -> String {
        let names = notes.map { AgentBadge.displayLabel($0.label) }
        switch notes.count {
        case 0: return "Set up the same everywhere"
        case 1: return "Set up differently in \(names[0])"
        case 2: return "Set up differently in \(names[0]) and \(names[1])"
        default: return "Set up differently in \(notes.count) agents"
        }
    }

    /// First line, at most `fallbackLength` characters, ellipsis when cut.
    static func clip(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let line = firstLine.trimmingCharacters(in: .whitespaces)
        guard line.count > fallbackLength else { return line }
        return String(line.prefix(fallbackLength)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
