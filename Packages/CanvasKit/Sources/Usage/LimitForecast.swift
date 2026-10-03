import Foundation

/// One reading of a rate-limit window, taken from a status line payload.
public struct LimitSample: Codable, Equatable, Sendable {
    /// A `LimitKey`, e.g. `five_hour` or `seven_day_opus`.
    public var window: String
    public var usedPercentage: Double
    public var resetsAt: Date?
    public var at: Date
    /// The account's configuration folder (`ClaudeConfigPath`). Nil in files
    /// written before accounts were told apart.
    public var account: String?

    public init(window: String, usedPercentage: Double, resetsAt: Date?, at: Date, account: String? = nil) {
        self.window = window
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.at = at
        self.account = account
    }

    public static func from(_ payload: StatuslinePayload, at date: Date, account: String? = nil) -> [LimitSample] {
        var samples: [LimitSample] = []
        for key in LimitKey.sorted(payload.rateLimits?.windows.keys ?? [:].keys) {
            guard let reading = payload.rateLimits?.windows[key], let used = reading.usedPercentage else { continue }
            let resets = reading.resetsAt.map { Date(timeIntervalSince1970: $0) }
            samples.append(LimitSample(window: key, usedPercentage: used, resetsAt: resets, at: date, account: account))
        }
        return samples
    }
}

/// When a window is projected to fill, by least squares over the current fill
/// cycle only. A reset makes the percentage fall off a cliff; fitting across
/// it would give a negative burn rate and a confident, wrong "never".
public struct LimitForecast: Equatable, Sendable {
    public var window: String
    public var usedPercentage: Double
    public var burnPerHour: Double
    public var fullAt: Date?
    public var resetsAt: Date?
    public var samples: Int

    public var fillsBeforeReset: Bool {
        guard let fullAt else { return false }
        return resetsAt.map { fullAt < $0 } ?? true
    }

    /// `samples` of one window, any order. Nil when there are none.
    public static func make(_ samples: [LimitSample], now: Date = Date()) -> LimitForecast? {
        let current = currentCycle(samples)
        guard let last = current.last, let first = current.first else { return nil }
        let points = current.map { (x: $0.at.timeIntervalSince(first.at) / 3600, y: $0.usedPercentage) }
        let slope = regressionSlope(points) ?? 0
        let burn = slope > 0 ? slope : 0
        var fullAt: Date?
        if burn > 0 {
            let hours = (100 - last.usedPercentage) / burn
            if hours >= 0, hours.isFinite { fullAt = now.addingTimeInterval(hours * 3600) }
        }
        return LimitForecast(
            window: last.window,
            usedPercentage: last.usedPercentage,
            burnPerHour: burn,
            fullAt: fullAt,
            resetsAt: last.resetsAt,
            samples: current.count
        )
    }

    /// Samples since the last drop in usage, sorted by time.
    public static func currentCycle(_ samples: [LimitSample]) -> [LimitSample] {
        let sorted = samples.sorted { $0.at < $1.at }
        guard !sorted.isEmpty else { return [] }
        var start = sorted.count - 1
        while start > 0, sorted[start - 1].usedPercentage <= sorted[start].usedPercentage { start -= 1 }
        return Array(sorted[start...])
    }

    static func regressionSlope(_ points: [(x: Double, y: Double)]) -> Double? {
        let n = Double(points.count)
        guard points.count >= 2 else { return nil }
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for p in points {
            sx += p.x; sy += p.y; sxx += p.x * p.x; sxy += p.x * p.y
        }
        let denominator = n * sxx - sx * sx
        guard denominator != 0 else { return nil }
        return (n * sxy - sx * sy) / denominator
    }
}
