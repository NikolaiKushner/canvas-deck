import AppKit
import Combine
import os

/// Whether Claude Code is installed here, where, and which version. Checked
/// once in the background at launch and again on "Check Again"; every place
/// that starts Claude Code asks this first instead of failing in a shell.
@MainActor
final class ClaudeCLI: ObservableObject {
    static let shared = ClaudeCLI()

    /// The oldest version with everything the canvas passes: `--settings`
    /// hooks incl. `PermissionDenied` (2.1.89), `rate_limits` (2.1.80),
    /// `--name` (2.1.76), status line `refreshInterval` (2.1.97).
    static let minimumVersion = "2.1.97"
    static let installURL = URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!

    enum State: Equatable {
        case unknown
        case checking
        case missing
        case found(path: String, version: String?)
    }

    @Published private(set) var state: State = .unknown
    private static let log = Logger(subsystem: "app.canvasdeck", category: "agent")
    private var checking: Task<Void, Never>?

    var path: String? {
        if case .found(let path, _) = state { return path }
        return nil
    }

    var version: String? {
        if case .found(_, let version) = state { return version }
        return nil
    }

    /// The CLI path, checking first if nobody has yet.
    func pathWhenKnown() async -> String? {
        if path == nil, state == .unknown || state == .checking { await refresh() }
        return path
    }

    /// True only when the version is known and older than `minimumVersion`.
    var isOutdated: Bool {
        guard let version else { return false }
        return Self.compare(version, Self.minimumVersion) == .orderedAscending
    }

    func refresh() async {
        if let checking { return await checking.value }
        state = .checking
        let task = Task {
            // Development: `--simulate-no-claude` shows what a Mac without Claude Code sees.
            let simulateMissing = CommandLine.arguments.contains("--simulate-no-claude")
            guard !simulateMissing, let path = await ClaudeAccount.cliPath() else {
                state = .missing
                return
            }
            let output = try? await ClaudeAccount.run(path, ["--version"], timeout: 10)
            state = .found(path: path, version: output.flatMap(Self.parseVersion))
            if isOutdated {
                Self.log.notice("Claude Code \(self.version ?? "?", privacy: .public) is older than \(Self.minimumVersion, privacy: .public)")
            }
        }
        checking = task
        await task.value
        checking = nil
    }

    /// Runs `body` if Claude Code is installed; otherwise explains and offers
    /// to install or check again.
    func whenInstalled(_ body: @escaping () -> Void) {
        Task {
            if path == nil { await refresh() }
            if path != nil { return body() }
            let alert = NSAlert()
            alert.messageText = "Claude Code is not installed"
            alert.informativeText = "Canvas Deck runs the claude command line tool in a terminal card. Install Claude Code, then check again."
            alert.addButton(withTitle: "Check Again")
            alert.addButton(withTitle: "How to Install…")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                await refresh()
                if path != nil { body() } else { whenInstalled(body) }
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(Self.installURL)
            default:
                break
            }
        }
    }

    /// "2.1.284 (Claude Code)" → "2.1.284".
    nonisolated static func parseVersion(_ output: String) -> String? {
        output.split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map(String.init)
            .first { $0.first?.isNumber == true && $0.contains(".") }
    }

    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let left = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let right = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
