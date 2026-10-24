import Foundation

/// The panel's small lines of text (v1.5): the footer's compact summary and its
/// tooltip (the full sentence plus "Checked 1 min ago · 2 hidden"). Pure, so
/// `PanelTextTests` covers the wording without a view.
enum PanelText {
    /// The footer's left side (round 2): short enough to sit beside four glyphs in
    /// a 380pt panel. "44 · 3 broken · 1 sign-in · 2 differ"; with nothing to
    /// report "44 servers, all fine". While any check runs (the first pass after
    /// launch included) it reads "Checking…", next to the spinning refresh glyph.
    /// The full sentence lives in the tooltip (`footerTooltip`).
    static func compactSummary(_ groups: [ServerGroup], checking: Bool = false) -> String {
        if checking { return "Checking\u{2026}" }
        guard !groups.isEmpty else { return "No servers found" }
        let counts = Counts(groups)
        var parts: [String] = []
        if counts.broken > 0 { parts.append("\(counts.broken) broken") }
        if counts.slow > 0 { parts.append("\(counts.slow) slow") }
        if counts.signIn > 0 { parts.append("\(counts.signIn) sign-in") }
        // r3 6eef: Not checked and waiting rows were left out, so the footer
        // read "all fine" beside them.
        if counts.notChecked > 0 { parts.append("\(counts.notChecked) not checked") }
        if counts.waiting > 0 { parts.append("\(counts.waiting) waiting") }
        if counts.differs > 0 { parts.append("\(counts.differs) \(counts.differs == 1 ? "differs" : "differ")") }
        if counts.checking > 0 { parts.append("\(counts.checking) checking") }
        guard !parts.isEmpty else { return count(groups.count, "server", "servers") + ", all fine" }
        return (["\(groups.count)"] + parts).joined(separator: " \u{00B7} ")
    }

    /// The footer summary's tooltip: the full sentence on the first line, when it
    /// was checked and how many rows are hidden on the second.
    static func footerTooltip(
        _ groups: [ServerGroup],
        firstPass: Bool,
        lastChecked: Date?,
        hiddenCount: Int,
        now: Date
    ) -> String {
        summary(groups, firstPass: firstPass) + "\n" + footer(lastChecked: lastChecked, hiddenCount: hiddenCount, now: now)
    }

    /// "19 servers · 1 broken · 1 slow · 1 set up differently". Parts that are zero
    /// are left out; with nothing to report it reads "19 servers · all fine".
    /// `groups` are the visible rows (hidden servers have their own footer count).
    ///
    /// `firstPass`: mcpock's first check after launch is still running. Until it
    /// ends most rows are unknown, so instead of "18 checking" (or a premature
    /// "all fine") the line starts with "Checking…"; anything already found
    /// broken or slow is still counted after it. First, not last: a long line is
    /// cut at its end, and the word that says "not done yet" must survive.
    static func summary(_ groups: [ServerGroup], firstPass: Bool = false) -> String {
        guard !groups.isEmpty else { return firstPass ? "Checking\u{2026}" : "No servers found" }
        var parts = [count(groups.count, "server", "servers")]
        let c = Counts(groups)
        if c.broken > 0 { parts.append("\(c.broken) broken") }
        if c.slow > 0 { parts.append("\(c.slow) slow") }
        if c.signIn > 0 { parts.append("\(c.signIn) \(c.signIn == 1 ? "needs" : "need") sign-in") }
        if c.notChecked > 0 { parts.append("\(c.notChecked) not checked") }
        if c.waiting > 0 { parts.append("\(c.waiting) waiting for your OK") }
        if c.differs > 0 { parts.append("\(c.differs) set up differently") }
        if c.needsApp > 0 { parts.append("\(c.needsApp) \(c.needsApp == 1 ? "needs its app" : "need their app")") }
        if firstPass {
            parts.insert("Checking\u{2026}", at: 0)
        } else {
            if c.checking > 0 { parts.append("\(c.checking) checking") }
            if parts.count == 1 { parts.append("all fine") }
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "Checked just now", "Checked 1 min ago", "Checked 3 h ago". `nil` (nothing
    /// probed yet) reads "Not checked yet".
    static func checkedAgo(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not checked yet" }
        return "Checked " + ago(date, now: now)
    }

    /// The bare interval, shared with the detail card's "checked 1 min ago".
    static func ago(_ date: Date, now: Date) -> String {
        RelativeAge.text(since: date, now: now)
    }

    /// The footer's left side: "Checked 1 min ago · 2 hidden".
    static func footer(lastChecked: Date?, hiddenCount: Int, now: Date) -> String {
        var text = checkedAgo(lastChecked, now: now)
        if hiddenCount > 0 { text += " \u{00B7} \(hiddenCount) hidden" }
        return text
    }

    /// What the summaries count, worked out once for both wordings.
    private struct Counts {
        let broken: Int
        let slow: Int
        let signIn: Int
        let notChecked: Int
        let differs: Int
        let needsApp: Int
        let checking: Int
        let waiting: Int

        init(_ groups: [ServerGroup]) {
            broken = groups.filter { $0.state == .broken }.count
            signIn = groups.filter(\.needsSignIn).count
            notChecked = groups.filter(\.notCheckedHere).count
            slow = groups.filter { $0.state == .degraded }.count - signIn - notChecked
            needsApp = groups.filter { $0.state == .needsApp }.count
            differs = groups.filter { $0.state == .healthy && $0.differsNeedsAttention }.count
            checking = groups.filter { $0.state == .unknown }.count
            waiting = groups.filter(\.waitsForFileOK).count
        }
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }
}

extension ServerGroup {
    /// Degraded because an agent's HTTP server refused us for lack of credentials
    /// (401/403), not because it is slow. Reads "Needs sign-in" everywhere.
    var needsSignIn: Bool {
        state == .degraded && issues.contains { $0.reason.hasPrefix("Needs authentication") }
    }

    /// Degraded because its config uses a variable mcpock can't fill in
    /// (`ConfigVariables`): not checked, not slow. Reads "Not checked".
    var needsVariable: Bool {
        state == .degraded && !needsSignIn && issues.contains { $0.reason.hasPrefix(ConfigVariables.reasonPrefix) }
    }

    /// Degraded because the server wants a sign-in its agent holds (OAuth):
    /// the config has no headers, so nothing here is wrong (r3 5f42).
    var signedInByAgent: Bool {
        state == .degraded && issues.contains { $0.reason.hasPrefix(HealthMonitor.agentSignInPrefix) }
    }

    /// Not checked by mcpock for a reason that is nobody's fault here: a
    /// `${VAR}` it can't fill, or a sign-in its agent holds. Calm everywhere.
    var notCheckedHere: Bool { needsVariable || signedInByAgent }

    /// The agents behind the row, one per agent (a server declared in two Claude
    /// Code projects is still one Claude Code), in discovery order. Drives the
    /// row's badges.
    var agents: [String] {
        var seen = Set<String>()
        return sources.map(\.agent).filter { seen.insert($0).inserted }
    }

    /// Newest probe time across a set of rows, for the footer.
    static func newestCheck(_ groups: [ServerGroup]) -> Date? {
        groups.compactMap(\.lastChecked).max()
    }
}
