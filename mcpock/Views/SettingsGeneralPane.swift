import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The General pane (round 8): a native grouped form, like System Settings.
/// Look (appearance, scroll bars), checking (interval, Open at Login), a small
/// Status section (last check, what was found, the status file agents read),
/// errors. The form scrolls itself inside the fixed window.
struct SettingsGeneralPane: View {
    /// The app's single health monitor, so Export can read the current errors.
    var monitor: HealthMonitor?
    let theme: ThemeColors
    /// The file `mcpock-mcp` reads; shown in Status.
    var statusFilePath: String = MCPockStatus.defaultDirectory()
        .appendingPathComponent(MCPockStatus.fileName).path

    @AppStorage(AppPreferences.themeKey) private var themeRaw = AppPreferences.defaultTheme.rawValue
    @AppStorage(AppPreferences.probeIntervalKey) private var probeIntervalRaw = ProbeInterval.default.rawValue
    @AppStorage(AppPreferences.hideScrollBarsKey) private var hideScrollBars = AppPreferences.defaultHideScrollBars
    @AppStorage(AppPreferences.usageWindowKey) private var usageWindowRaw = UsageWindow.default.rawValue
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var exportNote: String?
    /// The slider's live position while dragging (and while it snaps); nil
    /// at rest. The stored interval changes only when the knob is let go, so
    /// a drag across the track doesn't restart the timer seven times.
    @State private var dragPosition: Double?
    /// True between the slider's editing-began and editing-ended.
    @State private var isDragging = false
    /// The short snap to the nearest stop after a drag.
    @State private var snapTask: Task<Void, Never>?

    static let hideScrollBarsTitle = "Hide scroll bars"
    static let hideScrollBarsHelp = "Lists still scroll with the trackpad or mouse wheel."
    static let sliderWidth: CGFloat = 190
    /// Fixed to the widest stop label ("Manual", "15 min"), so the text
    /// beside the slider never changes width or wraps while dragging and the
    /// row never reflows (round 9: "Every 15 min" wrapped to two lines).
    static let valueWidth: CGFloat = {
        let widest = ProbeInterval.allCases.map { valueTextWidth($0.title) }.max() ?? 0
        return ceil(widest) + 2
    }()

    /// The value text's font: the form's body size with fixed-width digits.
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    static func valueTextWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: valueFont]).width
    }
    static let statusFooter = "Agents you connect in the Connect tab read this file. mcpock updates it after every check."

    private var storedInterval: ProbeInterval { ProbeInterval.fromStored(probeIntervalRaw) }

    /// What the value text and caption show: the stop under the knob while
    /// dragging, else the saved one.
    private var shownInterval: ProbeInterval {
        dragPosition.map(ProbeInterval.nearest(toSliderPosition:)) ?? storedInterval
    }

    var body: some View {
        Form {
            Section {
                // An HStack, not LabeledContent: the segments have no text
                // baseline to line the label up with, so centre both.
                HStack {
                    Text("Appearance")
                    Spacer(minLength: 12)
                    NeutralSegments(
                        options: AppTheme.allCases.map { ($0.rawValue, $0.title) },
                        selection: $themeRaw,
                        theme: theme,
                        accessibilityLabel: "Appearance",
                        trackFill: theme.rowHighlight
                    )
                    // 240, not 200: four stops now (Glass, 1.8), same width as
                    // the Usage segments below so neither row crowds its text.
                    .frame(width: 240)
                }
                Toggle(Self.hideScrollBarsTitle, isOn: $hideScrollBars)
                    .help(Self.hideScrollBarsHelp)
                HStack {
                    Text("Usage")
                    Spacer(minLength: 12)
                    NeutralSegments(
                        options: UsageWindow.allCases.map { ($0.rawValue, $0.title) },
                        selection: $usageWindowRaw,
                        theme: theme,
                        accessibilityLabel: "Usage",
                        trackFill: theme.rowHighlight
                    )
                    .frame(width: 240)
                }
                .help("How many times each agent called each server, next to its name in the Agents tab.")
            }

            Section {
                LabeledContent("Check servers") { intervalSlider }
                Toggle("Open at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        do {
                            try LaunchAtLogin.setEnabled(newValue)
                            launchAtLogin = LaunchAtLogin.isEnabled
                            launchError = nil
                        } catch {
                            launchAtLogin = LaunchAtLogin.isEnabled
                            launchError = error.localizedDescription
                        }
                    }
                ))
            } footer: {
                if let launchError {
                    Text(launchError)
                        .font(Theme.caption)
                        .foregroundStyle(theme.statusBroken)
                } else {
                    footerText(shownInterval == .manual
                        ? "Checks only when you press Refresh in the panel."
                        : "Refresh in the panel checks right away, too.")
                }
            }

            Section {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    LabeledContent("Last check") {
                        Text(lastCheckText(now: context.date))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                LabeledContent("Servers") {
                    Text(serversText)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                LabeledContent("Agents") {
                    Text(agentsText)
                        .foregroundStyle(theme.textSecondary)
                }
                // Errors live with the status (round 8): the same report the
                // agents read, for pasting by hand.
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Errors")
                        if let exportNote {
                            Text(exportNote)
                                .font(Theme.caption)
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 12)
                    Button("Copy All") { copyAllErrors() }
                        .help("Copy a report of every failing server, ready to paste to an agent")
                    Button("Export\u{2026}") { exportErrors() }
                        .help("Save the same report as Markdown or JSON")
                }
                // Last, right above the footer that talks about it. An HStack
                // so a long path truncates instead of dropping under the label.
                HStack(spacing: 16) {
                    Text("Status file")
                        .fixedSize()
                    Spacer(minLength: 0)
                    ConfigPathRow(path: statusFilePath, theme: theme, openTitle: MenuText.openFileTitle,
                                  font: .system(size: 11.5, design: .monospaced))
                        .padding(.trailing, -5)
                }
            } header: {
                Text("Status")
            } footer: {
                footerText(Self.statusFooter)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .panelScrollIndicators()
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
        .onChange(of: probeIntervalRaw) { _, _ in
            monitor?.probeIntervalChanged()
        }
    }

    // MARK: - Status texts

    private func lastCheckText(now: Date) -> String {
        guard let monitor else { return "Not checked yet" }
        if monitor.isRefreshing { return "Checking\u{2026}" }
        guard let date = ServerGroup.newestCheck(monitor.groups) else { return "Not checked yet" }
        return Self.lastCheckText(date, now: now)
    }

    /// "3 min ago, at 14:05". Pure.
    nonisolated static func lastCheckText(_ date: Date, now: Date) -> String {
        let clock = date.formatted(date: .omitted, time: .shortened)
        return PanelText.ago(date, now: now) + ", at " + clock
    }

    private var serversText: String {
        guard let monitor else { return "None yet" }
        return PanelText.summary(monitor.groups)
    }

    private var agentsText: String {
        let entries = SettingsAgentsPane.entries(from: monitor?.groups ?? [])
        return SettingsAgentsPane.countText(entries)
    }

    // MARK: - Pieces

    private func footerText(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(theme.textTertiary)
    }

    /// 1 min … 4 h, then Manual at the right end. The knob follows the pointer
    /// continuously, the value beside it names the nearest stop live, and on
    /// release the knob glides to that stop, then saves.
    private var intervalSlider: some View {
        let stops = Double(ProbeInterval.allCases.count - 1)
        return HStack(alignment: .center, spacing: 10) {
            Slider(
                value: Binding(
                    get: { dragPosition ?? Double(storedInterval.sliderIndex) },
                    set: { sliderMoved(to: $0) }
                ),
                in: 0...stops,
                label: { Text("Check servers") },
                ticks: {
                    SliderTickContentForEach(ProbeInterval.allCases.map { Double($0.sliderIndex) }, id: \.self) { position in
                        // Dots only: labels under seven stops crowd each other,
                        // and the value beside the slider names the stop.
                        SliderTick(position)
                    }
                },
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing { snapAndSave() }
                }
            )
            .labelsHidden()
            // Neutral, like the rest of Settings: an accent bar reads as
            // "more is better", and Manual (the right end) is the quietest.
            .tint(theme.textTertiary)
            .frame(width: Self.sliderWidth)
            .accessibilityValue(shownInterval.title)
            Text(shownInterval.title)
                .font(Font(Self.valueFont))
                .lineLimit(1)
                .foregroundStyle(theme.textSecondary)
                .frame(width: Self.valueWidth, alignment: .trailing)
        }
        .fixedSize()
    }

    /// A value from the slider. A pointer drag just moves the knob (saved on
    /// release). Keyboard and VoiceOver send small steps with no drag: those
    /// move one whole stop in their direction and save at once, or they would
    /// snap back to the stop they started from.
    private func sliderMoved(to position: Double) {
        snapTask?.cancel()
        snapTask = nil
        if isDragging || NSEvent.pressedMouseButtons & 1 != 0 {
            dragPosition = position
            return
        }
        let stop = ProbeInterval.stepped(from: storedInterval, toward: position)
        dragPosition = nil
        save(stop)
    }

    /// Glide from where the knob was let go to the nearest stop (a short
    /// ease-out, about 0.15 s), then save it.
    private func snapAndSave() {
        guard let start = dragPosition else { return }
        let stop = ProbeInterval.nearest(toSliderPosition: start)
        let frames = ProbeInterval.snapFrames(from: start, to: Double(stop.sliderIndex))
        snapTask?.cancel()
        snapTask = Task { @MainActor in
            for position in frames {
                dragPosition = position
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }
            }
            save(stop)
            dragPosition = nil
            snapTask = nil
        }
    }

    private func save(_ stop: ProbeInterval) {
        if stop.rawValue != probeIntervalRaw { probeIntervalRaw = stop.rawValue }
    }

    /// Put the same report "Export…" writes onto the clipboard — the panel's
    /// per-row "Copy errors" is one server; this is all of them at once.
    private func copyAllErrors() {
        let groups = monitor?.groups ?? []
        let failing = ErrorExport.failing(groups).count
        guard failing > 0 else {
            exportNote = "No errors to copy"
            return
        }
        let report = ErrorExport.markdown(from: groups, totalCount: groups.count, generated: Date())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        exportNote = "Copied \(failing) error\(failing == 1 ? "" : "s")"
    }

    /// Save a report of every failing server to a Markdown or JSON file (chosen by
    /// the save panel's file type). Writes the whole current error set, not just one.
    private func exportErrors() {
        let groups = monitor?.groups ?? []
        let total = groups.count
        let now = Date()

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "Export MCP errors"
        panel.nameFieldStringValue = "mcpock-errors-\(ErrorExport.fileStamp(now)).md"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let markdownType = UTType(filenameExtension: "md") ?? .plainText
        panel.allowedContentTypes = [markdownType, .json]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let format = ErrorExport.format(forExtension: url.pathExtension)
        let contents = ErrorExport.string(format, from: groups, totalCount: total, generated: now)
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            let failing = ErrorExport.failing(groups).count
            exportNote = "Exported \(failing) error\(failing == 1 ? "" : "s") → \(url.lastPathComponent)"
        } catch {
            exportNote = "Export failed: \(error.localizedDescription)"
        }
    }
}
