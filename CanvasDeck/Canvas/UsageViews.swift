import AppKit
import SwiftUI
import Usage

/// How the usage views refer to sessions on the canvas.
struct UsageContext {
    var openNodes: () -> Set<UUID>
    var title: (String) -> String
    var openCard: () -> Void
    var focusNode: (UUID) -> Void
    /// The card's content height changed: the card grows or shrinks to it.
    var contentHeight: (CGFloat) -> Void = { _ in }
}

/// Colour by what is left: more than 35% green, more than 10% orange, else red.
private func limitColor(used: Double) -> Color {
    let left = 100 - used
    if left > 35 { return .green }
    if left > 10 { return .orange }
    return .red
}

private func percent(_ value: Double) -> String {
    "\(Int(max(0, value).rounded()))%"
}

/// "Resets in 16 min", "Resets in 3 h 20 min", "Resets Tue 2:00 PM".
private func resetText(_ date: Date, now: Date) -> String {
    let minutes = Int(date.timeIntervalSince(now) / 60)
    if date.timeIntervalSince(now) <= 0 { return "Reset, new figures on the next refresh" }
    if minutes < 60 { return "Resets in \(minutes) min" }
    if minutes < 24 * 60 {
        let rest = minutes % 60
        return rest == 0 ? "Resets in \(minutes / 60) h" : "Resets in \(minutes / 60) h \(rest) min"
    }
    return "Resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

/// Claude's brand orange, as on the Claude Code icon: the account the toolbar shows.
private let claudeOrange = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

// MARK: - Usage card

/// Content of the Usage card, laid out like Claude's own usage panel.
struct UsageCardView: View {
    @ObservedObject var store: UsageStore
    let context: UsageContext

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    limits(now: timeline.date)
                    Divider().padding(.vertical, 16)
                    sessions
                    Divider().padding(.vertical, 16)
                    HStack {
                        Button("See detailed breakdown") {
                            if let url = URL(string: "https://claude.ai/settings/usage") { NSWorkspace.shared.open(url) }
                        }
                        Spacer()
                    }
                }
                .padding(20)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { context.contentHeight(geometry.size.height) }
                        .onChange(of: geometry.size.height) { _, height in context.contentHeight(height) }
                })
                Spacer(minLength: 0)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func limits(now: Date) -> some View {
        Text("Your usage limits")
            .font(.title3)
            .foregroundStyle(.secondary)
            .padding(.bottom, 12)
        if !store.cardAccounts.isEmpty, store.accounts.values.contains(where: { !$0.windows.isEmpty }) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(store.cardAccounts, id: \.self) { account in
                    accountBox(account, now: now)
                }
                notCarried.padding(.top, 4)
            }
        } else {
            Text(noLimitsText)
                .font(.callout)
                .foregroundStyle(.secondary)
            if store.cliMissing {
                Button("How to Install Claude Code…") { NSWorkspace.shared.open(ClaudeCLI.installURL) }
                    .padding(.top, 8)
            }
        }
    }

    /// What `/usage` shows that a status line does not carry.
    private var notCarried: some View {
        Text(Settings.refreshLimitsWithUsageCommand
             ? "From Claude Code's /usage every 5 minutes and from sessions on the canvas. Usage credits are not shown: /usage lists them only in an interactive session."
             : "From sessions on the canvas only: per-model weekly limits and usage credits are missing. Turn on Settings → Claude Code → Refresh limits every 5 minutes, or run /usage in a Claude Code card.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var noLimitsText: String {
        if store.cliMissing {
            return "Claude Code is not installed, so there are no limits to show."
        }
        if store.planReportsLimits == false {
            let plan = store.planDescription.map { " (\($0))" } ?? ""
            return "Claude Code reports 5-hour and weekly limits for Claude subscriptions, not for API keys or cloud providers. This account\(plan) has none to show; the cost of canvas sessions is below."
        }
        return "Limits come from Claude Code after its first reply in a session, on Claude subscriptions. Turn on Settings → Claude Code → Limits to get them from every session, not only canvas cards."
    }

    /// Each account in its own box; the toolbar's one edged in Claude orange.
    private func accountBox(_ account: String, now: Date) -> some View {
        let shown = account == store.shownAccount && store.cardAccounts.count > 1
        return accountLimits(account, now: now)
            .padding(14)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(shown ? claudeOrange.opacity(0.55) : Color.primary.opacity(0.09), lineWidth: 1)
            )
    }

    /// One account's windows, under its name and email.
    private func accountLimits(_ account: String, now: Date) -> some View {
        let windows = store.accounts[account]?.windows ?? [:]
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if store.showsAccountNames {
                    Text(store.name(of: account)).font(.headline)
                }
                if account == store.shownAccount, store.cardAccounts.count > 1 {
                    Text("in the toolbar").font(.caption).foregroundStyle(claudeOrange)
                }
                Text(store.detail(of: account))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                if let at = store.accounts[account]?.at {
                    Text("Updated \(at, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if windows.isEmpty {
                Text("No limits from this account yet: they arrive after a reply in a Claude Code session signed in to it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(LimitKey.sorted(windows.keys), id: \.self) { key in
                if let window = windows[key], let used = window.usedPercentage {
                    let ended = window.resetsAt.map { Date(timeIntervalSince1970: $0) <= now } ?? false
                    row(key: key, used: ended ? 0 : used, window: window, account: account, now: now)
                }
            }
        }
    }

    private func row(key: String, used: Double, window: StatuslinePayload.Window, account: String, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(LimitKey.title(key)).font(.title3)
                Spacer()
                if let resets = window.resetsAt {
                    Text(resetText(Date(timeIntervalSince1970: resets), now: now))
                        .foregroundStyle(.secondary)
                }
                Text(percent(used))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            bar(used: used)
            if let forecast = store.forecast(key, account: account, now: now), forecast.fillsBeforeReset, let full = forecast.fullAt {
                Text("At this pace it runs out in \(StatuslineText.untilReset(full, now: now) ?? "—"), before the reset")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func bar(used: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(limitColor(used: used))
                    .frame(width: geometry.size.width * min(max(used, 0), 100) / 100)
            }
        }
        .frame(height: 6)
    }

    @ViewBuilder
    private var sessions: some View {
        let open = store.open(nodes: context.openNodes())
        HStack {
            Text("Sessions on the canvas").font(.title3).foregroundStyle(.secondary)
            Spacer()
            let costs = open.compactMap(\.figures.costUSD)
            if !costs.isEmpty {
                Text(StatuslineText.usd(costs.reduce(0, +)))
                    .font(.title3.monospacedDigit())
            }
        }
        .padding(.bottom, 10)
        if open.isEmpty {
            Text("No Claude Code card on the canvas has reported yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Session"); Text("Model"); Text("Context"); Text("Lines"); Text("Cost")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(open, id: \.id) { item in
                    GridRow {
                        Button(context.title(item.id)) { context.focusNode(item.figures.nodeID) }
                            .buttonStyle(.link)
                            .lineLimit(1)
                        Text(item.figures.model ?? "—").foregroundStyle(.secondary)
                        Text(item.figures.contextPercentage.map(percent) ?? "—")
                        Text(item.figures.linesChanged > 0 ? "\(item.figures.linesChanged)" : "—")
                        Text(item.figures.costUSD.map(StatuslineText.usd) ?? "—")
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
    }
}
