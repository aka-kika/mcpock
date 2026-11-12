import Foundation

/// The panel's small lines of text (v1.5): the footer's compact summary and its
/// tooltip (the full sentence plus "Checked 1 min ago · 2 hidden"). Pure, so
/// `PanelTextTests` covers the wording without a view.
enum PanelText {
    /// The footer's left side (round 2; two numbers since 1.13): the line
    /// people scan. "41 servers · 4 need you · 5 not checked", or "41 servers,
    /// all fine". Everything that needs her is one number, and "not checked"
    /// is paused, waiting for her OK, waiting for its app, a `${VAR}`, in the
    /// cloud, inside its app or signed in by the agent. While a check runs it
    /// counts how far along it is. The breakdown lives in the tooltip
    /// (`footerTooltip`).
    static func compactSummary(_ groups: [ServerGroup], checking: Bool = false) -> String {
        // While rows still wait for their first answer, count them (r3 2c74):
        // "Checking…" alone hid the counts for the whole first pass.
        if checking {
            let done = groups.filter { $0.state != .unknown }.count
            return done < groups.count ? "Checking \(done) of \(groups.count)" : "Checking\u{2026}"
        }
        guard !groups.isEmpty else { return "No servers found" }
        let needs = groups.filter(PanelSections.needsYou).count
        let notChecked = groups.filter { !PanelSections.needsYou($0) && $0.isNotCheckedByMcpock }.count
        let off = groups.filter(\.isOffEverywhere).count
        return twoNumbers(count(groups.count, "server", "servers"), needs: needs, notChecked: notChecked, off: off)
    }

    /// "41 servers · 4 need you · 5 not checked", "41 servers, all fine". The
    /// Agents tab says the same about its agents.
    /// 1.14: "· 2 off" for servers switched off in every agent that has them.
    static func twoNumbers(_ total: String, needs: Int, notChecked: Int, off: Int = 0) -> String {
        guard needs > 0 || notChecked > 0 || off > 0 else { return total + ", all fine" }
        var parts = [total]
        if needs > 0 { parts.append("\(needs) \(needs == 1 ? "needs" : "need") you") }
        if notChecked > 0 { parts.append("\(notChecked) not checked") }
        if off > 0 { parts.append("\(off) off") }
        return parts.joined(separator: " \u{00B7} ")
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
        if c.incomplete > 0 { parts.append("\(c.incomplete) bad config") }
        if c.signIn > 0 { parts.append("\(c.signIn) \(c.signIn == 1 ? "needs" : "need") sign-in") }
        if c.notChecked > 0 { parts.append("\(c.notChecked) not checked") }
        if c.waiting > 0 { parts.append("\(c.waiting) waiting for your OK") }
        if c.differs > 0 { parts.append("\(c.differs) set up differently") }
        if c.lost > 0 { parts.append("\(c.lost) lost in a session") }
        if c.needsApp > 0 { parts.append("\(c.needsApp) \(c.needsApp == 1 ? "needs its app" : "need their app")") }
        if c.off > 0 { parts.append("\(c.off) turned off") }
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
        let lost: Int
        let incomplete: Int
        let off: Int

        init(_ groups: [ServerGroup]) {
            broken = groups.filter { $0.state == .broken }.count
            // One word per row, in the status file's order (sign-in, not
            // checked, bad config, slow): a row whose copies have two of
            // these reasons was counted twice and took one off slow (ds-3).
            let degraded = groups.filter { $0.state == .degraded }
            signIn = degraded.filter(\.needsSignIn).count
            notChecked = degraded.filter { !$0.needsSignIn && $0.notCheckedHere }.count
            incomplete = degraded.filter { !$0.needsSignIn && !$0.notCheckedHere && $0.incompleteConfig }.count
            slow = degraded.count - signIn - notChecked - incomplete
            needsApp = groups.filter { $0.state == .needsApp }.count
            differs = groups.filter { $0.state == .healthy && $0.differsNeedsAttention }.count
            checking = groups.filter { $0.state == .unknown }.count
            waiting = groups.filter(\.waitsForFileOK).count
            lost = groups.filter(\.droppedInSession).count
            off = groups.filter(\.isOffEverywhere).count
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

    /// A config entry with neither a command nor a url (r3 e412): the config
    /// needs a fix, so it stays in Needs you, but it is not slow (review
    /// 2026-10-30, c853).
    var incompleteConfig: Bool {
        state == .degraded && issues.contains { $0.reason.hasPrefix(HealthMonitor.noEndpointReason) }
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

    /// mcpock has no answer of its own for this row, whatever the reason.
    var isNotCheckedByMcpock: Bool {
        notCheckedHere || state == .paused || state == .selfManaged || state == .needsApp || state == .unknown
    }

    /// Newest probe time across a set of rows, for the footer.
    static func newestCheck(_ groups: [ServerGroup]) -> Date? {
        groups.compactMap(\.lastChecked).max()
    }
}

/// A row's numbers, the same on the Servers and Agents tabs and on an
/// agent's own row (11 Nov, 37f0; numbers only since 12 Nov, Kika: "just the
/// number"): "9/54" when some are off or hidden, "6" when none are, then the
/// calls in the Usage window, dimmer, after a centred dot: "9/54 · 74". The
/// words live in the tooltip. On a server row the numbers are tools; on an
/// agent's row they are its servers (on / all) and its own calls.
struct RowCounts: Equatable {
    /// What the "x/N" counts.
    enum Unit: Equatable {
        case tools, servers
    }

    /// The tools it reported at its last check (or, for `.servers`, the
    /// agent's servers).
    var tools: Int
    /// Of those, hidden (on the Servers tab: by every agent that can hide
    /// tools; inside an agent: by that agent). For `.servers`: turned off.
    var hidden: Int = 0
    /// Calls in the Usage window; nil with Usage off or no record.
    var calls: Int?
    /// Why there is no call count when there could be one ("No usage record
    /// for this agent"), for the tooltip; nil otherwise.
    var noCallsReason: String? = nil
    /// The Usage window, for the tooltip.
    var window: UsageWindow = .default
    var unit: Unit = .tools

    /// "9/54", "6", or nil when there is nothing to count yet.
    var onPart: String? {
        guard tools > 0 else { return nil }
        let off = clampedHidden
        return off > 0 ? "\(tools - off)/\(tools)" : "\(tools)"
    }

    /// "74", "1.2k", or nil with no call count.
    var callsPart: String? { calls.map(UsageText.compact) }

    /// The whole label as one string: "9/54 · 74", "6", "74", or "" when
    /// there is nothing to say yet. The view draws the calls dimmer.
    var line: String {
        [onPart, callsPart].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private var clampedHidden: Int { min(max(hidden, 0), tools) }

    /// The tooltip: the same in full words.
    var help: String {
        var parts: [String] = []
        if tools > 0 {
            let off = clampedHidden
            switch unit {
            case .tools:
                parts.append(off > 0 ? "\(tools - off) of \(tools) tools on, \(off) hidden"
                                     : "\(tools) tool\(tools == 1 ? "" : "s")")
            case .servers:
                parts.append(off > 0 ? "\(tools - off) of \(tools) servers on, \(off) turned off"
                                     : "\(tools) server\(tools == 1 ? "" : "s"), all on")
            }
        }
        if let calls {
            let span = window.days.map { "in \($0) days" } ?? "all time"
            parts.append("\(calls) call\(calls == 1 ? "" : "s") \(span)")
        }
        if let noCallsReason { parts.append(noCallsReason) }
        return parts.joined(separator: ", ")
    }
}
