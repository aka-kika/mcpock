import SwiftUI
import AppKit
import Carbon.HIToolbox

/// The General pane (round 8): a native grouped form, like System Settings.
/// Look and checking, nothing else (1.13: the status file moved to Connect, the
/// counts are the panel footer's tooltip). The form scrolls itself inside the
/// fixed window.
struct SettingsGeneralPane: View {
    /// The app's single health monitor.
    var monitor: HealthMonitor?
    let theme: ThemeColors

    @AppStorage(AppPreferences.themeKey, store: AppPreferences.store) private var themeRaw = AppPreferences.defaultTheme.rawValue
    @AppStorage(AppPreferences.probeIntervalKey, store: AppPreferences.store) private var probeIntervalRaw = ProbeInterval.default.rawValue
    @AppStorage(AppPreferences.usageWindowKey, store: AppPreferences.store) private var usageWindowRaw = UsageWindow.default.rawValue
    @AppStorage(AppPreferences.openPanelHotKeyKey, store: AppPreferences.store) private var openPanelHotKey = AppPreferences.defaultOpenPanelHotKey
    /// The saved shortcut's data; empty means ⌃⌥M (`PanelShortcut.standard`).
    @AppStorage(AppPreferences.panelShortcutKey, store: AppPreferences.store) private var panelShortcutData = Data()
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var launchNeedsApproval = LaunchAtLogin.needsApproval
    /// The slider's live position while dragging (and while it snaps); nil
    /// at rest. The stored interval changes only when the knob is let go, so
    /// a drag across the track doesn't restart the timer seven times.
    @State private var dragPosition: Double?
    /// True between the slider's editing-began and editing-ended.
    @State private var isDragging = false
    /// The short snap to the nearest stop after a drag.
    @State private var snapTask: Task<Void, Never>?

    static let hotKeyTitle = "Open with a shortcut"
    static func hotKeyHelp(_ shortcut: PanelShortcut) -> String {
        "\(shortcut.spokenText) opens and closes the panel from any app. "
            + "Then use the arrow keys, Return and Escape."
    }
    static let recordingText = "Type a shortcut"
    static let recordingHelp = "Press keys with Control, Option or Command. Escape cancels."
    static let widgetsUnavailableText = "Widgets can't get data: mcpock can't open its App Group folder."
    static func hotKeyTakenText(_ shortcut: PanelShortcut) -> String {
        "Another app already uses \(shortcut.displayText), so mcpock can't. Pick another one."
    }
    static let sliderWidth: CGFloat = 190

    private var panelShortcut: PanelShortcut {
        (try? JSONDecoder().decode(PanelShortcut.self, from: panelShortcutData)) ?? .standard
    }

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
                            launchNeedsApproval = LaunchAtLogin.needsApproval
                            launchError = nil
                        } catch {
                            launchAtLogin = LaunchAtLogin.isEnabled
                            launchNeedsApproval = LaunchAtLogin.needsApproval
                            launchError = error.localizedDescription
                        }
                    }
                ))
                // One row: the shortcut button, then the switch (the pane must
                // open without scrolling, SettingsWindowSizingTests).
                LabeledContent(Self.hotKeyTitle) {
                    HStack(spacing: 10) {
                        ShortcutRecorder(shortcut: panelShortcut) { picked in
                            AppPreferences.savePanelShortcut(picked)
                        }
                        .disabled(!openPanelHotKey)
                        Toggle(Self.hotKeyTitle, isOn: $openPanelHotKey)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                .help(Self.hotKeyHelp(panelShortcut))
            } footer: {
                if let launchError {
                    Text(launchError)
                        .font(Theme.caption)
                        .foregroundStyle(theme.statusBroken)
                } else if launchNeedsApproval {
                    Text(LaunchAtLogin.approvalText)
                        .font(Theme.caption)
                        .foregroundStyle(theme.statusDegraded)
                } else if openPanelHotKey && GlobalHotKey.shared.isTaken {
                    Text(Self.hotKeyTakenText(panelShortcut))
                        .font(Theme.caption)
                        .foregroundStyle(theme.statusDegraded)
                } else if AppGroup.containerURL == nil {
                    // (r3 7183) An unsigned or ad-hoc build has no App Group: the
                    // widgets would show nothing, and nothing said why.
                    Text(Self.widgetsUnavailableText)
                        .font(Theme.caption)
                        .foregroundStyle(theme.statusDegraded)
                } else {
                    footerText(shownInterval == .manual
                        ? "Checks only when you press Refresh in the panel."
                        : "Refresh in the panel checks right away, and a changed config is checked by itself.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .panelScrollIndicators()
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            launchNeedsApproval = LaunchAtLogin.needsApproval
        }
        .onChange(of: probeIntervalRaw) { _, _ in
            monitor?.probeIntervalChanged()
        }
        .onChange(of: usageWindowRaw) { _, _ in
            guard let monitor else { return }
            SettingsLauncher.usageStore?.usageWindowChanged(knownServers: MCPockApp.knownServerNames(monitor))
        }
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
}

/// The shortcut as a button (1.12): click it, press the new keys, done.
/// Escape or a click elsewhere cancels; Reset brings back ⌃⌥M.
struct ShortcutRecorder: View {
    let shortcut: PanelShortcut
    let onPick: (PanelShortcut) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 10) {
            if shortcut != .standard && !isRecording {
                Button("Reset") { onPick(.standard) }
                    .buttonStyle(.link)
                    .help("Back to \(PanelShortcut.standard.displayText)")
            }
            Button(isRecording ? SettingsGeneralPane.recordingText : shortcut.displayText) {
                isRecording ? stop() : start()
            }
            .help(isRecording ? SettingsGeneralPane.recordingHelp : "Click, then press a new shortcut.")
            .accessibilityLabel(isRecording ? SettingsGeneralPane.recordingText : "Shortcut \(shortcut.spokenText)")
        }
        .onDisappear { stop() }
    }

    private func start() {
        isRecording = true
        GlobalHotKey.shared.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            guard event.type == .keyDown else {
                stop()
                return event
            }
            if Int(event.keyCode) == kVK_Escape {
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if let picked = PanelShortcut.from(keyCode: event.keyCode, flags: flags,
                                               characters: event.charactersIgnoringModifiers) {
                onPick(picked)
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        GlobalHotKey.shared.isRecording = false
    }
}
