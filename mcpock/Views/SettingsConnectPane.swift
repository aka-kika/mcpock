import SwiftUI
import AppKit

/// Settings > Connect (round 7; a grouped form since round 8): hand agents
/// mcpock's read-only MCP server so "check my mcpock" works instead of
/// copy-pasting errors one by one.
///
/// Round 8: the main button is "Copy for Claude", onboarding done BY Claude
/// Code: a prompt that finds every agent config on the Mac, backs each one up,
/// adds the server where it's missing, verifies and reports a table. The
/// per-agent snippets are copy icons (the manual way). Round 9: the one-agent
/// "Copy Prompt" row is gone; the Claude button is the normal grey button and
/// turns Claude orange with "Copied" for 2 s. 1.10.7: each agent mcpock reads
/// has a row saying whether it already has mcpock (`AgentHost`, the list from
/// Kartina, read-only here). Nothing here writes another app's config.
struct SettingsConnectPane: View {
    let theme: ThemeColors
    var helperPath: String = ConnectSnippets.helperPath()

    /// Which copy button just ran, for its short "Copied" / checkmark state.
    @State private var copiedID: String?
    @State private var resetTask: Task<Void, Never>?
    /// Each agent: connected, not connected, or not on this Mac (read off the main thread).
    @State private var statuses: [String: AgentHost.Status] = [:]

    private static let claudeID = "claude"

    /// How long each button shows its "Copied" state.
    static let claudeCopiedSeconds: Double = 2
    static let rowCopiedSeconds: Double = 1.6

    static let claudeTitle = "Copy for Claude"
    static let claudeText = "Paste it into Claude Code. It finds your agents\u{2019} configs, backs each one up, "
        + "adds mcpock where it\u{2019}s missing, checks that it works and shows you a table."
    static let footerText = "mcpock never edits your agents\u{2019} configs. The server only reads mcpock\u{2019}s own status file."
    /// The agents without a status row keep their plain copy rows.
    static var otherTargets: [ConnectSnippets.Target] {
        ConnectSnippets.targets.filter { target in !AgentHost.all.contains { $0.name == target.name } }
    }

    private var helperExists: Bool { FileManager.default.isExecutableFile(atPath: helperPath) }

    var body: some View {
        Form {
            Section {
                claudeRow
            } header: {
                SettingsFormHeader(
                    title: "Connect your agents",
                    text: ConnectSnippets.intro + " Add mcpock as an MCP server, then say \u{201C}check my mcpock\u{201D}.",
                    theme: theme
                )
            }

            if ConnectSnippets.isTemporaryLocation(helperPath) {
                Section {
                    Text(ConnectSnippets.moveText)
                        .foregroundStyle(theme.statusBroken)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text(ConnectSnippets.moveTitle)
                }
            }

            Section {
                // An HStack, not LabeledContent: a long path must truncate on
                // the row, not drop under its label.
                HStack(spacing: 16) {
                    Text("Helper")
                        .fixedSize()
                    Spacer(minLength: 0)
                    if helperExists {
                        ConfigPathRow(path: helperPath, theme: theme, openTitle: nil,
                                      font: .system(size: 11.5, design: .monospaced))
                            .padding(.trailing, -5)
                    } else {
                        Text("Missing from this copy of mcpock")
                            .foregroundStyle(theme.statusBroken)
                    }
                }
                ForEach(AgentHost.all) { host in
                    agentRow(host)
                }
                ForEach(Self.otherTargets) { target in
                    row(target)
                }
            } header: {
                Text("Your agents, or copy the line for one")
            } footer: {
                Text(Self.footerText)
                    .font(Theme.caption)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .panelScrollIndicators()
        .onAppear { refreshStatuses() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refreshStatuses() }
    }

    // MARK: - Agent rows (1.10.7)

    /// One agent: its badge, its name, whether it has mcpock, and the line to copy.
    private func agentRow(_ host: AgentHost) -> some View {
        let status = statuses[host.id]
        let copied = copiedID == host.id
        let shownFile = host.fileURL(home: Self.home).path.replacingOccurrences(of: Self.home.path + "/", with: "")
        let destination = host.format.isClaudeCode ? "Run in Terminal (adds it for every project)" : "~/" + shownFile
        return HStack(spacing: 10) {
            AgentBadgeView(badge: AgentBadge.forLabel(host.name), theme: theme, size: 22)
                .opacity(status == .notInstalled ? 0.5 : 1)
            Text(host.name)
                .foregroundStyle(status == .notInstalled ? theme.textTertiary : theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            switch status {
            case .connected:
                HStack(spacing: 5) {
                    Circle().fill(theme.statusHealthy).frame(width: 7, height: 7)
                    Text("Connected").font(Theme.caption).foregroundStyle(theme.textSecondary)
                }
            case .turnedOff:
                Text("Turned off").font(Theme.caption).foregroundStyle(theme.textSecondary)
                    .help("The mcpock entry is there but switched off in this file")
            case .notConnected:
                Text("Not connected").font(Theme.caption).foregroundStyle(theme.textSecondary)
            case .notInstalled:
                Text("Not on this Mac").font(Theme.caption).foregroundStyle(theme.textTertiary)
            case nil:
                ProgressView().controlSize(.mini)
            }
            Button {
                copy(host.setup(helper: helperPath), id: host.id, for: Self.rowCopiedSeconds)
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: copied ? .semibold : .regular))
                    .foregroundStyle(copied ? theme.statusHealthy : theme.textSecondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Copy the line for \(host.name). Goes in: \(destination). Then: \(host.after)")
            .accessibilityLabel("Copy the line for \(host.name)")
        }
    }

    nonisolated private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Read again whenever Settings comes to the front, so a line pasted meanwhile shows.
    private func refreshStatuses() {
        Task.detached {
            let home = Self.home
            let found = Dictionary(uniqueKeysWithValues: AgentHost.all.map { ($0.id, $0.status(home: home)) })
            await MainActor.run { statuses = found }
        }
    }

    // MARK: - Rows

    /// The main way: Claude Code does the whole setup. The button sits under
    /// the text, where the eye lands after reading it.
    private var claudeRow: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentBadgeView(badge: AgentBadge.forLabel(AgentRegistry.claudeCodeLabel), theme: theme, size: 28)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Let Claude set it up")
                        .fontWeight(.medium)
                        .foregroundStyle(theme.textPrimary)
                    Text(Self.claudeText)
                        .font(Theme.caption)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                claudeButton
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    /// The app's normal grey button at the large size. A copy fades in a
    /// Claude-orange capsule with "Copied" on top of it for 2 s, then eases
    /// back. An overlay, not a style swap: the native bezel and the width
    /// stay exactly as they are, and a click can't land on the overlay.
    private var claudeButton: some View {
        let copied = copiedID == Self.claudeID
        return Button {
            copy(ConnectSnippets.claudeSetupPrompt(path: helperPath), id: Self.claudeID,
                 for: Self.claudeCopiedSeconds)
        } label: {
            Label(Self.claudeTitle, systemImage: "doc.on.doc")
                .frame(minWidth: 132)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .overlay {
            ZStack {
                Capsule().fill(Theme.claudeOrange)
                Label("Copied", systemImage: "checkmark")
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
            }
            .opacity(copied ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .help("Copy a prompt for Claude Code that connects mcpock to every agent on this Mac")
        .accessibilityLabel(copied ? "Copied" : Self.claudeTitle)
    }

    private func row(_ target: ConnectSnippets.Target) -> some View {
        let copied = copiedID == target.id
        let help = ConnectSnippets.copyHelp(target)
        return HStack(spacing: 10) {
            AgentBadgeView(badge: AgentBadge.forLabel(target.badgeLabel), theme: theme, size: 22)
            // One line, like the Agents pane: the name, then what it copies.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(target.name)
                    .foregroundStyle(theme.textPrimary)
                Text(target.format.caption)
                    .font(Theme.caption)
                    .foregroundStyle(theme.textTertiary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                copy(ConnectSnippets.snippet(target.format, path: helperPath), id: target.id,
                     for: Self.rowCopiedSeconds)
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: copied ? .semibold : .regular))
                    .foregroundStyle(copied ? theme.statusHealthy : theme.textSecondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(help + ". Goes in: " + target.destination)
            .accessibilityLabel(help)
        }
    }

    private func copy(_ text: String, id: String, for seconds: Double) {
        PanelState.copyToPasteboard(text)
        withAnimation(.easeOut(duration: 0.15)) { copiedID = id }
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) { copiedID = nil }
        }
    }
}
