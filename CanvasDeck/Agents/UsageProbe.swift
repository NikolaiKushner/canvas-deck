import AppKit
import Usage
import os

/// Keeps the limits current without a Claude Code session open: runs Claude
/// Code's own `/usage` (`claude -p /usage`, no model call) for each known
/// account every few minutes and when the app comes back to the front.
/// Nothing is left behind: no session is saved, the user's settings and hooks
/// and MCP servers are not loaded, and it runs in a folder of its own.
/// Settings → Claude Code → Limits can turn it off.
@MainActor
final class UsageProbe {
    static let interval: TimeInterval = 5 * 60
    /// Coming back to the app refreshes figures older than this.
    static let refreshOnActivate: TimeInterval = 60

    private let usage: UsageStore
    private var timer: Timer?
    private var running = false
    private var lastRun: Date?
    private var activation: NSObjectProtocol?
    private var retry: DispatchWorkItem?
    /// A run that brought nothing for some account is tried again this soon.
    static let retryAfter: TimeInterval = 45
    private static let log = Logger(subsystem: "app.canvasdeck", category: "usage")

    static var directory: URL {
        UsageStore.directory.appending(path: "usage-probe", directoryHint: .isDirectory)
    }

    init(usage: UsageStore) {
        self.usage = usage
    }

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfStale() }
        }
        refresh()
    }

    /// For moments someone looks at the figures: the app coming to the front,
    /// the Usage card opening.
    func refreshIfStale() {
        if lastRun.map({ Date().timeIntervalSince($0) > Self.refreshOnActivate }) ?? true { refresh() }
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.retry = nil
            self?.refresh()
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryAfter, execute: work)
    }

    func stop() {
        retry?.cancel()
        retry = nil
        timer?.invalidate()
        timer = nil
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
    }

    /// Every account the canvas knows, the Settings one first.
    func refresh() {
        guard Settings.refreshLimitsWithUsageCommand, !running else { return }
        running = true
        lastRun = Date()
        let accounts = [usage.shownAccount].compactMap { $0 } + usage.accounts.keys.filter { $0 != usage.shownAccount }.sorted()
        retry?.cancel()
        retry = nil
        Task {
            var failed: [String] = []
            defer {
                running = false
                if !failed.isEmpty { scheduleRetry() }
            }
            guard let cli = await ClaudeCLI.shared.pathWhenKnown() else { return }
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            for account in accounts {
                var environment = ClaudeConfig.environment(for: account)
                // A card's variables must not make this look like a canvas session.
                for key in ["CANVAS_NODE_ID", "CANVAS_CLAUDE_SETTINGS", "CANVAS_CLAUDE_WRAPPED"] { environment[key] = nil }
                let name = ClaudeConfigPath.shortName(account)
                let output: String
                do {
                    output = try await ClaudeAccount.run(cli, UsageCommand.arguments, timeout: 30, environment: environment, directory: Self.directory)
                } catch {
                    Self.log.notice("usage \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                    failed.append(account)
                    continue
                }
                let windows = UsageCommand.parse(output)
                if windows.isEmpty {
                    // Text only: /usage prints no credentials.
                    let head = output.split(whereSeparator: \.isNewline).prefix(3).joined(separator: " | ")
                    Self.log.notice("usage \(name, privacy: .public): nothing to read: \(String(head.prefix(200)), privacy: .public)")
                    failed.append(account)
                } else {
                    usage.applyProbe(windows, account: account, at: Date())
                }
            }
        }
    }
}
