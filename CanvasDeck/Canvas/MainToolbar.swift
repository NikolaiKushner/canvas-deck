import AppKit
import SwiftUI
import Usage

/// What the toolbar shows about the agents on the canvas.
@MainActor
final class ToolbarModel: ObservableObject {
    @Published var working = 0
    @Published var waiting = 0
    @Published var done = 0
}

/// The window's 52 pt toolbar (App design → Toolbar): the title at the left,
/// the ⌘K field in the middle, then agents, limits and settings.
@MainActor
final class MainToolbar: NSObject, NSToolbarDelegate {
    struct Actions {
        var jump: () -> Void
        var nextWaiting: () -> Void
        var openUsage: () -> Void
        var openSettings: () -> Void
    }

    private static let title = NSToolbarItem.Identifier("title")
    private static let jump = NSToolbarItem.Identifier("jump")
    private static let agents = NSToolbarItem.Identifier("agents")
    private static let limits = NSToolbarItem.Identifier("limits")
    private static let settings = NSToolbarItem.Identifier("settings")

    let model = ToolbarModel()
    let toolbar = NSToolbar(identifier: "CanvasDeckMain")
    private let usage: UsageStore
    private let actions: Actions

    init(usage: UsageStore, actions: Actions) {
        self.usage = usage
        self.actions = actions
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        toolbar.centeredItemIdentifiers = [Self.jump]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.title, .flexibleSpace, Self.jump, .flexibleSpace, Self.agents, Self.limits, Self.settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.isBordered = false
        switch id {
        case Self.title:
            item.label = "Canvas Deck"
            let label = NSTextField(labelWithString: "Canvas Deck")
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = CanvasPalette.text
            item.view = label
        case Self.jump:
            item.label = "Go to"
            item.view = host(JumpFieldView(action: actions.jump))
        case Self.agents:
            item.label = "Agents"
            item.view = host(AgentsSummaryView(model: model, action: actions.nextWaiting))
        case Self.limits:
            item.label = "Limits"
            item.view = host(LimitsChipView(store: usage, openUsage: actions.openUsage))
        case Self.settings:
            item.label = "Settings"
            let button = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!, target: self, action: #selector(openSettings))
            button.isBordered = false
            button.contentTintColor = CanvasPalette.secondaryText
            button.toolTip = "Settings  ⌘,"
            item.view = button
        default:
            return nil
        }
        return item
    }

    @objc private func openSettings() { actions.openSettings() }

    private func host<V: View>(_ view: V) -> NSView {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        return hosting
    }
}

/// The toolbar's background: the bar colour and a hairline under it.
final class ToolbarBackdrop: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        CanvasPalette.bar.setFill()
        bounds.fill()
        CanvasPalette.line.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Items

private struct JumpFieldView: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                Text("Jump to a card, session or issue")
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                Text("⌘K")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: CanvasPalette.card), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: CanvasPalette.chipStrong).opacity(1.5), lineWidth: 1))
            }
            .foregroundStyle(Color(nsColor: CanvasPalette.secondaryText))
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(width: 440, height: 32)
            .background(Color(nsColor: CanvasPalette.chip).opacity(1.2), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help("Go to a card, a session, an issue or a command  ⌘K")
    }
}

private struct AgentsSummaryView: View {
    @ObservedObject var model: ToolbarModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                count(model.working, CanvasPalette.working)
                count(model.waiting, CanvasPalette.permission)
                count(model.done, CanvasPalette.done)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color(nsColor: CanvasPalette.chip), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("\(model.working) working · \(model.waiting) waiting for you · \(model.done) done — click for the next waiting agent (⌘J)")
    }

    private func count(_ value: Int, _ color: NSColor) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Color(nsColor: color)).frame(width: 8, height: 8)
            Text("\(value)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color(nsColor: CanvasPalette.text))
        }
        .opacity(value == 0 ? 0.4 : 1)
    }
}

/// "◔ 5h 42%  ◔ 7d 18%  work ▾": used share of each window as a ring.
private struct LimitsChipView: View {
    @ObservedObject var store: UsageStore
    let openUsage: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            content(now: timeline.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let stale = store.limitsAt.map { now.timeIntervalSince($0) > 15 * 60 } ?? false
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                if store.hasLimits {
                    if let five = store.fiveHour, let used = five.usedPercentage {
                        meter("5h", used: used, resetsAt: five.resetsAt, base: CanvasPalette.working, now: now)
                    }
                    if let seven = store.sevenDay, let used = seven.usedPercentage {
                        meter("7d", used: used, resetsAt: seven.resetsAt, base: CanvasPalette.done, now: now)
                    }
                } else {
                    Text(store.cliMissing ? "Claude Code not installed" : store.signedOut ? "Not signed in" : store.planReportsLimits == false ? "No limits on this plan" : "Limits after the first reply")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: CanvasPalette.secondaryText))
                }
            }
            .opacity(stale ? 0.55 : 1)
            .contentShape(Rectangle())
            .onTapGesture(perform: openUsage)
            .help(store.shownAccount.map { "Claude Code limits of \(store.detail(of: $0)) — click for details" } ?? "Claude Code limits — click for details")
            if let shown = store.shownAccount {
                accountMenu(shown)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 28)
        .background(Color(nsColor: CanvasPalette.chip), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }

    private func meter(_ label: String, used: Double, resetsAt: Double?, base: NSColor, now: Date) -> some View {
        // The window it came from has ended: its figure says nothing any more.
        let ended = resetsAt.map { Date(timeIntervalSince1970: $0) <= now } ?? false
        let used = ended ? 0 : min(max(used, 0), 100)
        let left = 100 - used
        let color: Color = left > 35 ? Color(nsColor: base) : left > 10 ? .orange : .red
        let reset = resetsAt.flatMap { StatuslineText.untilReset(Date(timeIntervalSince1970: $0), now: now) }
        return HStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color(nsColor: CanvasPalette.text).opacity(0.12), lineWidth: 2.5)
                Circle().trim(from: 0, to: used / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            Text("\(label) \(Int(used.rounded()))%")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Color(nsColor: CanvasPalette.text))
        }
        .help(ended ? "\(label): reset" : "\(label): \(Int(used.rounded()))% used, \(Int(left.rounded()))% left" + (reset.map { " · resets in \($0)" } ?? ""))
    }

    private func accountMenu(_ shown: String) -> some View {
        Menu {
            Button {
                Settings.titleBarAccount = nil
            } label: {
                Text("Signed-in account")
                if Settings.titleBarAccount == nil { Image(systemName: "checkmark") }
            }
            let known = Settings.knownClaudeAccounts
            if !known.isEmpty { Divider() }
            ForEach(known.keys.sorted(), id: \.self) { folder in
                Button {
                    Settings.titleBarAccount = folder
                } label: {
                    Text("\(store.name(of: folder)) — \(known[folder] ?? "")")
                    if Settings.titleBarAccount.map { ClaudeConfigPath.normalize($0) } == ClaudeConfigPath.normalize(folder) { Image(systemName: "checkmark") }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.name(of: shown)).font(.system(size: 11.5, weight: .medium))
                Text("▾").font(.system(size: 9))
                    .foregroundStyle(Color(nsColor: CanvasPalette.secondaryText))
            }
            .foregroundStyle(Color(nsColor: CanvasPalette.text))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color(nsColor: CanvasPalette.card), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: CanvasPalette.chipStrong).opacity(1.2), lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Whose limits the toolbar shows")
    }
}
