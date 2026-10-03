import Combine
import Foundation
import Usage

/// Claude Code limits and per-session figures, fed by status line snapshots
/// from `canvas-notify --statusline` — from canvas cards and, when the global
/// status line is on, from any Claude Code session. Lives only in the app:
/// the current state in memory, limit samples for the forecast in
/// `usage-samples.json` (seven days, rewritten whole), and on launch the
/// latest limits `canvas-notify` saved to `last-limits.json`.
///
/// Limits belong to an account (its configuration folder, `ClaudeConfigPath`):
/// each has its own 5-hour and weekly windows. The title bar shows the account
/// signed in under Settings → Claude Code, and nothing else: another account's
/// figures there would be read as this one's.
@MainActor
final class UsageStore: ObservableObject {
    struct SessionFigures: Equatable {
        var nodeID: UUID
        var account: String?
        var model: String?
        var costUSD: Double?
        var contextPercentage: Double?
        var linesChanged: Int
        var at: Date
    }

    struct AccountLimits: Equatable {
        /// Every window by `LimitKey`: five_hour, seven_day, per-model weekly, spend.
        var windows: [String: StatuslinePayload.Window] = [:]
        var at: Date?
    }

    @Published private(set) var accounts: [String: AccountLimits] = [:]
    @Published private(set) var sessions: [String: SessionFigures] = [:]
    @Published private(set) var samples: [LimitSample] = []
    /// `claude auth status` of each account: email and plan.
    @Published private(set) var info: [String: ClaudeAccount.Status] = [:] {
        didSet { rememberAccounts() }
    }
    /// The account signed in under Settings → Claude Code; nil until known
    /// or when signed out.
    @Published private(set) var settingsAccount: String?
    @Published private(set) var signedOut = false
    /// Claude Code is not installed: nothing will ever report.
    @Published var cliMissing = false

    private var pickObserver: NSObjectProtocol?

    /// For the title bar picker in Settings.
    private func rememberAccounts() {
        var known = Settings.knownClaudeAccounts
        for (folder, status) in info where status.loggedIn {
            known[folder] = [status.email, status.planName].compactMap { $0 }.joined(separator: " · ")
        }
        if known != Settings.knownClaudeAccounts { Settings.knownClaudeAccounts = known }
    }

    /// Which account each card's session runs under, as the session said.
    private var nodeAccounts: [UUID: String] = [:]
    private var infoRequested: Set<String> = []

    static let sampleAge: TimeInterval = 7 * 24 * 3600
    /// A new sample when the reading changes, or at most this often while it does not.
    static let sampleEvery: TimeInterval = 5 * 60
    private var saveWork: DispatchWorkItem?

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CanvasDeck", directoryHint: .isDirectory)
    }
    static var samplesURL: URL { directory.appending(path: "usage-samples.json") }
    static var lastLimitsURL: URL { directory.appending(path: "last-limits.json") }

    init() {
        if let data = try? Data(contentsOf: Self.samplesURL),
           let saved = try? JSONDecoder.withDates.decode([LimitSample].self, from: data) {
            let cutoff = Date().addingTimeInterval(-Self.sampleAge)
            // Samples from before accounts were told apart could be anyone's.
            samples = saved.filter { $0.at >= cutoff && $0.account != nil }
            for sample in samples {
                guard let account = sample.account else { continue }
                var limits = accounts[account] ?? AccountLimits()
                if (limits.at ?? .distantPast) <= sample.at {
                    limits.windows[sample.window] = .init(usedPercentage: sample.usedPercentage, resetsAt: sample.resetsAt?.timeIntervalSince1970)
                    limits.at = sample.at
                }
                accounts[account] = limits
            }
        }
        loadLastLimits()
        for account in accounts.keys { requestInfo(account) }
        pickObserver = NotificationCenter.default.addObserver(forName: Settings.titleBarAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    /// `canvas-notify` keeps each account's newest limits here, even while the app is closed.
    private func loadLastLimits() {
        guard let data = try? Data(contentsOf: Self.lastLimitsURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let saved = object["accounts"] as? [String: Any] else { return }
        for (account, entry) in saved {
            guard let entry = entry as? [String: Any],
                  let at = (entry["at"] as? Double).map(Date.init(timeIntervalSince1970:)),
                  let raw = entry["rate_limits"],
                  let json = try? JSONSerialization.data(withJSONObject: ["rate_limits": raw]),
                  let payload = StatuslinePayload.decode(json) else { continue }
            applyLimits(payload, account: ClaudeConfigPath.normalize(account), at: at)
        }
    }

    // MARK: The account on show

    /// The account picked in Settings → Claude Code → Limits, else the one
    /// signed in there. Before its status is read: the default folder.
    var shownAccount: String? {
        if let picked = Settings.titleBarAccount { return ClaudeConfigPath.normalize(picked) }
        if signedOut { return nil }
        return settingsAccount ?? ClaudeConfigPath.defaultDirectory()
    }

    /// Accounts for the Usage card: the shown one first even without figures,
    /// then every other account that has reported limits.
    var cardAccounts: [String] {
        let shown = shownAccount
        let others = accounts.filter { !$0.value.windows.isEmpty && $0.key != shown }.keys.sorted()
        return (shown.map { [$0] } ?? []) + others
    }

    var windows: [String: StatuslinePayload.Window] { shownAccount.flatMap { accounts[$0]?.windows } ?? [:] }
    var limitsAt: Date? { shownAccount.flatMap { accounts[$0]?.at } }
    var hasLimits: Bool { !windows.isEmpty }
    var fiveHour: StatuslinePayload.Window? { windows[LimitKey.fiveHour] }
    var sevenDay: StatuslinePayload.Window? { windows[LimitKey.sevenDay] }

    /// Name the account in the title bar only when there is more than one.
    var showsAccountNames: Bool { Set(accounts.keys).union(nodeAccounts.values).count > 1 }

    func name(of account: String) -> String { ClaudeConfigPath.shortName(account) }

    /// "you@example.com · Max", or the folder when the status is unknown.
    func detail(of account: String) -> String {
        if let status = info[account], status.loggedIn {
            return [status.email, status.planName].compactMap { $0 }.joined(separator: " · ")
        }
        return (account as NSString).abbreviatingWithTildeInPath
    }

    /// False when the shown account's plan has no 5-hour / weekly limits in
    /// Claude Code (API key, cloud providers); nil when unknown.
    var planReportsLimits: Bool? {
        shownAccount.flatMap { info[$0]?.reportsRateLimits }
    }

    /// "API key", "Team", … for the explanation.
    var planDescription: String? {
        guard let account = shownAccount, let status = info[account] else { return nil }
        if let provider = status.apiProvider, provider != "firstParty" {
            return provider.prefix(1).uppercased() + provider.dropFirst()
        }
        return status.authMethod == "claude.ai" ? status.planName : "API key"
    }

    // MARK: Input

    /// The Settings account's status, at launch and after sign-in or sign-out.
    func setAccount(_ status: ClaudeAccount.Status?) {
        let account = status?.configDirectory.map { ClaudeConfigPath.normalize($0) } ?? ClaudeConfigPath.defaultDirectory()
        infoRequested.insert(account)
        info[account] = status
        signedOut = status?.loggedIn == false
        settingsAccount = signedOut ? nil : account
    }

    /// A hook or status line told which account a card's session runs under.
    func note(account: String, node: UUID) {
        if nodeAccounts[node] != account {
            nodeAccounts[node] = account
            objectWillChange.send()
        }
        requestInfo(account)
    }

    func account(of node: UUID) -> String? { nodeAccounts[node] }

    /// Every account the canvas knows, for badges: more than one means badges.
    var knownAccountCount: Int {
        Set(info.filter { $0.value.loggedIn }.keys).union(nodeAccounts.values).union(accounts.keys).count
    }

    func ingest(_ payload: StatuslinePayload, node: UUID?, account: String?, at date: Date) {
        let account = account ?? ClaudeConfigPath.defaultDirectory()
        if let node {
            note(account: account, node: node)
            if let id = payload.sessionID {
                let figures = SessionFigures(
                    nodeID: node,
                    account: account,
                    model: payload.model?.displayName ?? payload.model?.id,
                    costUSD: payload.cost?.totalCostUSD,
                    contextPercentage: payload.contextWindow?.usedPercentage,
                    linesChanged: payload.linesChanged,
                    at: date
                )
                if sessions[id] != figures { sessions[id] = figures }
            }
        }
        applyLimits(payload, account: account, at: date)
        requestInfo(account)
    }

    /// Figures from `claude -p /usage`: current at `date`.
    func applyProbe(_ windows: [String: StatuslinePayload.Window], account: String, at date: Date) {
        applyLimits(StatuslinePayload(rateLimits: .init(windows: windows)), account: account, at: date)
        requestInfo(account)
    }

    private func applyLimits(_ payload: StatuslinePayload, account: String, at date: Date) {
        guard let fresh = payload.rateLimits?.windows, !fresh.isEmpty else { return }
        var limits = accounts[account] ?? AccountLimits()
        // Arrival order says nothing about age: an idle session repeats its
        // last reply's figures. `LimitMerge` keeps the newest per window.
        let merged = LimitMerge.merge(current: limits.windows, fresh: fresh)
        limits.at = max(limits.at ?? date, date)
        if limits.windows != merged || accounts[account] == nil {
            limits.windows = merged
        }
        if accounts[account] != limits { accounts[account] = limits }
        record(LimitSample.from(StatuslinePayload(rateLimits: .init(windows: merged)), at: date, account: account))
    }

    private func record(_ fresh: [LimitSample]) {
        var changed = false
        for sample in fresh {
            let last = samples.last { $0.window == sample.window && $0.account == sample.account }
            let differs = last.map { $0.usedPercentage != sample.usedPercentage || $0.resetsAt != sample.resetsAt } ?? true
            let old = last.map { sample.at.timeIntervalSince($0.at) >= Self.sampleEvery } ?? true
            if differs || old {
                samples.append(sample)
                changed = true
            }
        }
        guard changed else { return }
        let cutoff = Date().addingTimeInterval(-Self.sampleAge)
        samples.removeAll { $0.at < cutoff }
        scheduleSave()
    }

    /// Email and plan of an account, once per launch, off the main thread.
    private func requestInfo(_ account: String) {
        guard !infoRequested.contains(account) else { return }
        infoRequested.insert(account)
        Task { [weak self] in
            guard case .success(let status) = await ClaudeAccount.status(configDirectory: account) else { return }
            self?.info[account] = status
        }
    }

    func forecast(_ key: String, account: String? = nil, now: Date = Date()) -> LimitForecast? {
        let account = account ?? shownAccount
        return LimitForecast.make(samples.filter { $0.window == key && $0.account == account }, now: now)
    }

    /// Figures for sessions still on the canvas.
    func open(nodes: Set<UUID>) -> [(id: String, figures: SessionFigures)] {
        sessions.filter { nodes.contains($0.value.nodeID) }
            .map { (id: $0.key, figures: $0.value) }
            .sorted { $0.figures.at > $1.figures.at }
    }

    func forget(node: UUID) {
        sessions = sessions.filter { $0.value.nodeID != node }
        nodeAccounts[node] = nil
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = samples
        let work = DispatchWorkItem {
            let url = Self.samplesURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder.withDates.encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }
}
