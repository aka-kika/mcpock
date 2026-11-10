import AppKit
import SwiftUI

/// One agent's ask on the server's card (1.16, Kika's design): who asks,
/// what, its reason, and Yes / No. Yes opens the usual sheet; nothing is
/// written until she confirms there.
struct AskRow: View {
    let ask: AgentAsk
    let theme: ThemeColors
    /// Shows the server's name too (the window that lists every ask).
    var namesServer = false
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                AgentBadgeView(badge: AgentBadge.forLabel(CardText.agentLabel(forDisplay: ask.agent)), theme: theme, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AskText.title(ask, namesServer: namesServer))
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(AskText.reason(ask))
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(AskText.when(ask, now: Date()))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            HStack(spacing: 6) {
                CardButton(title: "Yes", help: "See what changes first: nothing is written until you confirm", theme: theme) {
                    answer(true)
                }
                CardButton(title: "No", help: "Nothing changes; the agent reads that you said no", theme: theme) {
                    answer(false)
                }
            }
            .padding(.leading, 28)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.fieldFill)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The words of an ask, shared by the card, the window and the notification.
enum AskText {
    /// "Claude Code asks to hide delete_repository" (on the card), or with
    /// "in github" where the server is not otherwise named.
    static func title(_ ask: AgentAsk, namesServer: Bool) -> String {
        let what: String
        switch ask.action {
        case .hideTool: what = "hide \(ask.tool ?? "a tool")" + (namesServer ? " in \(ask.server)" : "")
        case .showTool: what = "show \(ask.tool ?? "a tool") again" + (namesServer ? " in \(ask.server)" : "")
        case .turnOff: what = "turn \(namesServer ? ask.server : "this server") off"
        case .turnOn: what = "turn \(namesServer ? ask.server : "this server") on"
        }
        return "\(ask.agent) asks to \(what)"
    }

    /// The agent's own words, quoted.
    static func reason(_ ask: AgentAsk) -> String {
        "\u{201C}\(ask.reason)\u{201D}"
    }

    /// "Asked 5 min ago · ends in 23 h if you don't answer".
    static func when(_ ask: AgentAsk, now: Date) -> String {
        let left = max(0, ask.asked.addingTimeInterval(AgentAsk.lifetime).timeIntervalSince(now))
        let hours = Int(left / 3600)
        let ends = hours >= 1 ? "\(hours) h" : "\(max(1, Int(left / 60))) min"
        return "Asked \(RelativeAge.text(since: ask.asked, now: now)) \u{00B7} ends in \(ends) if you don't answer"
    }

    /// The notification's body.
    static func notification(_ ask: AgentAsk) -> String {
        title(ask, namesServer: true) + ": " + reason(ask)
    }
}

/// When the menu bar icon can't open the panel (hidden from the menu bar),
/// a notification's click opens this small window instead: every waiting
/// ask with Yes / No, and the usual sheet after a Yes.
@MainActor
final class AskWindowController {
    static let shared = AskWindowController()
    private var window: NSWindow?

    func show(state: PanelState, asks: AskCenter) {
        if window == nil {
            let host = NSHostingController(rootView: AskWindowView(state: state, asks: asks) { [weak self] in self?.close() })
            let window = NSWindow(contentViewController: host)
            window.title = "mcpock asks you"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: DetailCardPresenter.width, height: 420))
            self.window = window
        }
        NSApp.activate()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}

private struct AskWindowView: View {
    @Bindable var state: PanelState
    let asks: AskCenter
    let close: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ThemeColors.resolve(colorScheme)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let plan = state.pendingSwitch {
                        SwitchSheet(plan: plan, state: state, theme: theme)
                    } else if asks.waiting.isEmpty {
                        Text("Nothing is waiting for your answer.")
                            .font(Theme.caption)
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        ForEach(asks.waiting, id: \.id) { ask in
                            AskRow(ask: ask, theme: theme, namesServer: true) { state.answerAsk(ask, yes: $0) }
                        }
                    }
                }
                .padding(16)
                .frame(width: DetailCardPresenter.width, alignment: .leading)
            }
            if let plan = state.pendingSwitch {
                SwitchSheetButtons(plan: plan, state: state, theme: theme)
            }
        }
        .background(theme.background)
        .onChange(of: asks.waiting.isEmpty) { _, empty in
            if empty, state.pendingSwitch == nil { close() }
        }
    }
}
