import Foundation

/// Reads the limits out of `claude -p /usage`, Claude Code's own usage
/// command, so they are current without a session open. Lines look like
///
///     Current session: 7% used · resets Sep 30 at 7:49pm (Europe/Minsk)
///     Current week (all models): 11% used · resets Oct 6 at 1:59pm (Europe/Minsk)
///     Current week (Fable): 12% used · resets Oct 6 at 1:59pm (Europe/Minsk)
///
/// This is text meant for people and may change between versions: whatever
/// does not parse is skipped, and the status line stays the other source.
public enum UsageCommand {
    /// The command line after the `claude` executable. No session is saved,
    /// the user's settings (and so their hooks) and MCP servers are not loaded.
    public static let arguments = ["-p", "/usage", "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config"]

    public static func parse(_ text: String, now: Date = Date(), timeZone fallback: TimeZone = .current) -> [String: StatuslinePayload.Window] {
        var windows: [String: StatuslinePayload.Window] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            guard let key = key(for: String(line[..<colon])) else { continue }
            let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let percent = rest.firstIndex(of: "%"),
                  let used = Double(rest[..<percent].trimmingCharacters(in: .whitespaces)),
                  rest[percent...].hasPrefix("% used") else { continue }
            var resetsAt: Double?
            if let range = rest.range(of: "resets ") {
                var when = String(rest[range.upperBound...])
                var zone = fallback
                if let open = when.lastIndex(of: "("), when.hasSuffix(")") {
                    let name = String(when[when.index(after: open)..<when.index(before: when.endIndex)])
                    zone = TimeZone(identifier: name) ?? fallback
                    when = String(when[..<open]).trimmingCharacters(in: .whitespaces)
                }
                resetsAt = date(when, now: now, timeZone: zone)?.timeIntervalSince1970
            }
            windows[key] = .init(usedPercentage: used, resetsAt: resetsAt)
        }
        return windows
    }

    /// "Current session" → five_hour, "Current week (all models)" → seven_day,
    /// "Current week (Fable)" → seven_day_fable.
    static func key(for label: String) -> String? {
        let label = label.trimmingCharacters(in: .whitespaces)
        if label == "Current session" { return LimitKey.fiveHour }
        guard label.hasPrefix("Current week") else { return nil }
        guard let open = label.firstIndex(of: "("), let close = label.lastIndex(of: ")"), open < close else {
            return LimitKey.sevenDay
        }
        let model = label[label.index(after: open)..<close].trimmingCharacters(in: .whitespaces).lowercased()
        if model == "all models" { return LimitKey.sevenDay }
        let slug = model.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return LimitKey.sevenDay + "_" + String(slug)
    }

    /// "Sep 30 at 7:49pm", "Oct 7 at 8am", "7:49pm" (today), "Oct 7": the
    /// first moment matching it from a day ago on, in `timeZone`.
    static func date(_ text: String, now: Date, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let cleaned = text.replacingOccurrences(of: " at ", with: " ").trimmingCharacters(in: .whitespaces)
        for format in ["MMM d h:mma", "MMM d ha", "MMM d", "h:mma", "ha"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: cleaned) else { continue }
            // The text has no year, and a bare time has no day: take them
            // from now, then move on a year or a day if that lands in the past.
            let read = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
            var parts = calendar.dateComponents([.year, .month, .day], from: now)
            if format.hasPrefix("MMM") {
                parts.month = read.month
                parts.day = read.day
            }
            parts.hour = format == "MMM d" ? 0 : read.hour
            parts.minute = format == "MMM d" ? 0 : read.minute
            parts.second = 0
            guard var date = calendar.date(from: parts) else { continue }
            if format.hasPrefix("MMM") {
                if date < now.addingTimeInterval(-24 * 3600), let next = calendar.date(byAdding: .year, value: 1, to: date) { date = next }
            } else if date < now.addingTimeInterval(-60), let next = calendar.date(byAdding: .day, value: 1, to: date) {
                date = next
            }
            return date
        }
        return nil
    }
}
