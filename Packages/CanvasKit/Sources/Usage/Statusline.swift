import Foundation

/// The JSON Claude Code hands to a status line command on stdin. Only the
/// fields the canvas uses; everything is optional because early in a session,
/// or on API-key auth, most of it is missing. `rate_limits` appears only for
/// Pro/Max subscriptions and only after the first model reply.
public struct StatuslinePayload: Codable, Equatable, Sendable {
    public struct Model: Codable, Equatable, Sendable {
        public var id: String?
        public var displayName: String?
        enum CodingKeys: String, CodingKey { case id, displayName = "display_name" }
    }

    public struct Cost: Codable, Equatable, Sendable {
        public var totalCostUSD: Double?
        public var totalLinesAdded: Int?
        public var totalLinesRemoved: Int?
        enum CodingKeys: String, CodingKey {
            case totalCostUSD = "total_cost_usd"
            case totalLinesAdded = "total_lines_added"
            case totalLinesRemoved = "total_lines_removed"
        }
    }

    public struct ContextWindow: Codable, Equatable, Sendable {
        public var usedPercentage: Double?
        enum CodingKeys: String, CodingKey { case usedPercentage = "used_percentage" }
    }

    public struct Window: Codable, Equatable, Sendable {
        public var usedPercentage: Double?
        /// Unix epoch seconds.
        public var resetsAt: Double?
        enum CodingKeys: String, CodingKey { case usedPercentage = "used_percentage", resetsAt = "resets_at" }

        public init(usedPercentage: Double?, resetsAt: Double?) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }
    }

    /// Every window Claude Code reports, by its key: `five_hour`, `seven_day`,
    /// `spend_limit`, and per-model weekly windows such as `seven_day_opus`
    /// when present. Unknown shapes are skipped, so new windows show up
    /// without a code change.
    public struct RateLimits: Codable, Equatable, Sendable {
        public var windows: [String: Window]

        public init(windows: [String: Window]) { self.windows = windows }

        public init(fiveHour: Window?, sevenDay: Window?) {
            var windows: [String: Window] = [:]
            windows[LimitKey.fiveHour] = fiveHour
            windows[LimitKey.sevenDay] = sevenDay
            self.windows = windows
        }

        public var fiveHour: Window? { windows[LimitKey.fiveHour] }
        public var sevenDay: Window? { windows[LimitKey.sevenDay] }

        struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            var windows: [String: Window] = [:]
            for key in container.allKeys {
                if let window = try? container.decode(Window.self, forKey: key), window.usedPercentage != nil {
                    windows[key.stringValue] = window
                }
            }
            self.windows = windows
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: AnyKey.self)
            for (key, window) in windows { try container.encode(window, forKey: AnyKey(stringValue: key)) }
        }
    }

    public var sessionID: String?
    public var model: Model?
    public var cost: Cost?
    public var contextWindow: ContextWindow?
    public var rateLimits: RateLimits?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case model
        case cost
        case contextWindow = "context_window"
        case rateLimits = "rate_limits"
    }

    public init(sessionID: String? = nil, model: Model? = nil, cost: Cost? = nil, contextWindow: ContextWindow? = nil, rateLimits: RateLimits? = nil) {
        self.sessionID = sessionID
        self.model = model
        self.cost = cost
        self.contextWindow = contextWindow
        self.rateLimits = rateLimits
    }

    public static func decode(_ data: Data) -> StatuslinePayload? {
        try? JSONDecoder().decode(StatuslinePayload.self, from: data)
    }

    public var linesChanged: Int { (cost?.totalLinesAdded ?? 0) + (cost?.totalLinesRemoved ?? 0) }
}

/// The status line text, in the nomnomtokens format:
/// `(＾ｕ＾)  $4.20  ctx 37%  7d 81% ·4d3h  5h 73% ·1h47m  138 lines`.
/// The tighter window goes first.
public enum StatuslineText {
    public static func render(_ payload: StatuslinePayload, now: Date = Date()) -> String {
        let five = payload.rateLimits?.fiveHour
        let seven = payload.rateLimits?.sevenDay
        let fivePct = five?.usedPercentage
        let sevenPct = seven?.usedPercentage

        var parts = [Mood(usedPercentage: max(fivePct ?? 0, sevenPct ?? 0)).face]
        if let cost = payload.cost?.totalCostUSD { parts.append(usd(cost)) }
        if let ctx = payload.contextWindow?.usedPercentage { parts.append("ctx \(Int(ctx.rounded()))%") }

        let fiveSegment = fivePct.map { segment("5h", $0, resetsAt: five?.resetsAt, now: now) }
        let sevenSegment = sevenPct.map { segment("7d", $0, resetsAt: seven?.resetsAt, now: now) }
        let weeklyFirst = sevenPct != nil && (fivePct == nil || sevenPct! >= fivePct!)
        parts += (weeklyFirst ? [sevenSegment, fiveSegment] : [fiveSegment, sevenSegment]).compactMap { $0 }

        let lines = payload.linesChanged
        if lines > 0 { parts.append("\(compact(lines)) lines") }
        return parts.joined(separator: "  ")
    }

    static func segment(_ label: String, _ used: Double, resetsAt: Double?, now: Date) -> String {
        let left = resetsAt.flatMap { untilReset(Date(timeIntervalSince1970: $0), now: now) }
        return "\(label) \(Int(used.rounded()))%" + (left.map { " ·\($0)" } ?? "")
    }

    /// "47m", "1h47m", "4d3h" — time left on a window, leading unit rounded down.
    public static func untilReset(_ date: Date, now: Date = Date()) -> String? {
        let delta = date.timeIntervalSince(now)
        guard delta > 0 else { return "now" }
        let minutes = Int(delta / 60)
        if minutes < 60 { return "\(max(minutes, 1))m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
        }
        let days = hours / 24
        let rest = hours % 24
        return rest == 0 ? "\(days)d" : "\(days)d\(rest)h"
    }

    public static func usd(_ value: Double) -> String {
        if value == 0 { return "$0.00" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }

    static func compact(_ n: Int) -> String {
        let value = Double(n)
        switch abs(value) {
        case 1e9...: return String(format: "%.1fB", value / 1e9)
        case 1e6...: return String(format: "%.1fM", value / 1e6)
        case 1e3...: return String(format: "%.1fk", value / 1e3)
        default: return String(n)
        }
    }
}

public enum Mood: String, Sendable {
    case hungry, content, full, stuffed, overstuffed

    public init(usedPercentage: Double) {
        switch usedPercentage {
        case ..<5: self = .hungry
        case ..<50: self = .content
        case ..<80: self = .full
        case ..<100: self = .stuffed
        default: self = .overstuffed
        }
    }

    public var face: String {
        switch self {
        case .hungry: "(・_・)"
        case .content: "(^_^)"
        case .full: "(＾ｕ＾)"
        case .stuffed: "(>_<)"
        case .overstuffed: "(x_x)"
        }
    }
}

/// Keys and display names of rate-limit windows.
public enum LimitKey {
    public static let fiveHour = "five_hour"
    public static let sevenDay = "seven_day"
    public static let spend = "spend_limit"

    /// "5-hour limit", "Weekly · all models", "Weekly · Fable", "Spend limit".
    public static func title(_ key: String) -> String {
        switch key {
        case fiveHour: return "5-hour limit"
        case sevenDay: return "Weekly · all models"
        case spend: return "Spend limit"
        default:
            if key.hasPrefix("seven_day_") {
                let rest = key.dropFirst("seven_day_".count).split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }
                return "Weekly · " + rest.joined(separator: " ")
            }
            return key.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    /// 5-hour first, then weekly, then per-model weekly windows by name, then the rest.
    public static func sorted(_ keys: some Sequence<String>) -> [String] {
        func rank(_ key: String) -> Int {
            switch key {
            case fiveHour: 0
            case sevenDay: 1
            case _ where key.hasPrefix("seven_day_"): 2
            case spend: 3
            default: 4
            }
        }
        return keys.sorted { (rank($0), $0) < (rank($1), $1) }
    }
}
