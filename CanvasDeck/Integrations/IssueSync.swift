import Foundation
import Combine
import Trackers

/// My open Linear issues, kept current: everything at start and every 15
/// minutes (issues reassigned away only drop out of a full read), only what
/// changed in between, once a minute. Cached in `linear-cache.json`, so the
/// canvas shows them at launch, before the network.
@MainActor
final class IssueSync: ObservableObject {
    @Published private(set) var issues: [Issue] = []
    /// Team id → its current cycle (sprint), when it has one.
    @Published private(set) var currentCycles: [String: Cycle] = [:]
    /// Team id → its workflow states, in the order Linear gives them.
    @Published private(set) var statuses: [String: [IssueStatus]] = [:]
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    var onUnauthorized: (() -> Void)?
    /// New items in the Linear inbox since the last look.
    var onNotifications: (([LinearNotification]) -> Void)?
    /// The newest inbox item already seen; nothing older is announced.
    private var seenNotificationsUntil: Date?

    static let pollEvery: TimeInterval = 60
    static let fullReadEvery: TimeInterval = 15 * 60

    private let linear: LinearMCP
    private let client: MCPClient
    private var timer: Timer?
    private var lastFull: Date?
    private var running = false

    static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CanvasDeck/linear-cache.json")
    }

    struct Cache: Codable {
        var issues: [Issue]
        var currentCycles: [String: Cycle]
        var statuses: [String: [IssueStatus]]?
        var seenNotificationsUntil: Date?
        var savedAt: Date
    }

    init(linear: LinearMCP, client: MCPClient) {
        self.linear = linear
        self.client = client
        if let data = try? Data(contentsOf: Self.cacheURL), let cache = try? JSONDecoder.withDates.decode(Cache.self, from: data) {
            issues = cache.issues
            currentCycles = cache.currentCycles
            statuses = cache.statuses ?? [:]
            seenNotificationsUntil = cache.seenNotificationsUntil
            lastSync = cache.savedAt
        }
    }

    func issue(_ id: String) -> Issue? { issues.first { $0.id == id } }

    func isInCurrentCycle(_ issue: Issue) -> Bool {
        guard let team = issue.teamId, let cycle = issue.cycleId else { return false }
        return currentCycles[team]?.id == cycle
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh(full: true)
    }

    func stop(clearing: Bool) {
        timer?.invalidate()
        timer = nil
        guard clearing else { return }
        issues = []
        currentCycles = [:]
        statuses = [:]
        seenNotificationsUntil = nil
        lastSync = nil
        lastFull = nil
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }

    func resetSession() async { await client.reset() }

    func refresh(full: Bool = false) {
        guard !running else { return }
        running = true
        let now = Date()
        let full = full || lastFull.map { now.timeIntervalSince($0) >= Self.fullReadEvery } ?? true
        // A little overlap: an issue saved during the last read is not missed.
        let since = full ? nil : lastSync?.addingTimeInterval(-120)
        Task {
            defer { running = false }
            do {
                let fetched = try await linear.myIssues(updatedAfter: since)
                if full {
                    issues = fetched.filter(\.isOpen)
                    lastFull = now
                    try await refreshTeams()
                } else {
                    merge(fetched)
                }
                lastSync = now
                lastError = nil
                await checkNotifications()
                save()
            } catch MCPClient.Failure.unauthorized {
                onUnauthorized?()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func merge(_ changed: [Issue]) {
        guard !changed.isEmpty else { return }
        var byID = Dictionary(issues.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        for issue in changed {
            byID[issue.id] = issue.isOpen ? issue : nil
        }
        issues = byID.values.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    /// Sprint and workflow states of the teams my issues are in.
    private func refreshTeams() async throws {
        let teams = Set(issues.compactMap(\.teamId))
        var cycles: [String: Cycle] = [:]
        var states: [String: [IssueStatus]] = [:]
        for team in teams {
            if let cycle = try? await linear.currentCycle(team: team) { cycles[team] = cycle }
            if let list = try? await linear.statuses(team: team) { states[team] = list }
        }
        currentCycles = cycles
        statuses = states
    }

    /// Unread inbox items newer than the last seen. The first look after
    /// signing in only sets the mark: old items are not announced.
    private func checkNotifications() async {
        guard let inbox = try? await linear.notifications(unreadOnly: true, limit: 20) else { return }
        let newest = inbox.compactMap(\.createdAt).max()
        defer { if let newest, newest > (seenNotificationsUntil ?? .distantPast) { seenNotificationsUntil = newest } }
        guard let seen = seenNotificationsUntil else { return }
        let fresh = inbox.filter { ($0.createdAt ?? .distantPast) > seen }
        if !fresh.isEmpty { onNotifications?(fresh.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }) }
    }

    // MARK: Any issue, on demand

    private var details: [String: Issue] = [:]

    /// The issue in full, from Linear; mine or anyone's (a page open in a
    /// browser card). Kept for the session.
    func fullIssue(_ id: String) async -> Issue? {
        if let cached = details[id] { return cached }
        guard let issue = try? await linear.issue(id) else { return nil }
        details[id] = issue
        if let team = issue.teamId { await ensureTeam(team) }
        return issue
    }

    /// Statuses and current cycle of a team none of my issues are in.
    func ensureTeam(_ team: String) async {
        if statuses[team] == nil, let list = try? await linear.statuses(team: team) { statuses[team] = list }
        if currentCycles[team] == nil, let cycle = try? await linear.currentCycle(team: team) { currentCycles[team] = cycle }
    }

    // MARK: Changes, from the issue's menu only

    /// Moves an issue to `status` at once on the canvas, then in Linear;
    /// on failure it goes back and the error is returned.
    func move(_ issueID: String, to status: IssueStatus) async -> String? {
        let index = issues.firstIndex { $0.id == issueID }
        let before = index.map { issues[$0] }
        if let index {
            issues[index].status = status.name
            issues[index].statusType = status.type
        }
        do {
            try await linear.setState(issueID, to: status.id)
            details[issueID]?.status = status.name
            details[issueID]?.statusType = status.type
            save()
            return nil
        } catch {
            if let before, let back = issues.firstIndex(where: { $0.id == issueID }) { issues[back] = before }
            return error.localizedDescription
        }
    }

    /// Adds the issue to its team's current cycle, or takes it out.
    func setSprint(_ issueID: String, current: Bool) async -> String? {
        let index = issues.firstIndex { $0.id == issueID }
        guard let team = index.map({ issues[$0].teamId }) ?? details[issueID]?.teamId else { return "Unknown team" }
        let before = index.map { issues[$0] }
        let cycle = current ? currentCycles[team]?.id : nil
        if current, cycle == nil { return "This team has no current cycle" }
        if let index { issues[index].cycleId = cycle }
        do {
            try await linear.setCycle(issueID, to: cycle)
            details[issueID]?.cycleId = cycle
            save()
            return nil
        } catch {
            if let before, let back = issues.firstIndex(where: { $0.id == issueID }) { issues[back] = before }
            return error.localizedDescription
        }
    }

    private func save() {
        let cache = Cache(issues: issues, currentCycles: currentCycles, statuses: statuses, seenNotificationsUntil: seenNotificationsUntil, savedAt: lastSync ?? Date())
        guard let data = try? JSONEncoder.withDates.encode(cache) else { return }
        try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
    }
}
