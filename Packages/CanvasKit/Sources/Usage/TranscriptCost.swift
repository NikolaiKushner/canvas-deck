import Foundation

/// USD per million tokens, as published for the Claude API. Modern Claude Code
/// transcripts carry no cost, so every figure is computed from this table.
/// Cache writes cost 1.25x input (5 min) or 2x (1 h); cache reads 0.1x.
public enum ModelPricing {
    public struct Price: Equatable, Sendable {
        public var input: Double
        public var output: Double
    }

    static let table: [String: Price] = [
        "claude-fable-5": Price(input: 10, output: 50),
        "claude-mythos-5": Price(input: 10, output: 50),
        "claude-opus-5": Price(input: 5, output: 25),
        "claude-opus-4-8": Price(input: 5, output: 25),
        "claude-opus-4-7": Price(input: 5, output: 25),
        "claude-opus-4-6": Price(input: 5, output: 25),
        "claude-opus-4-5": Price(input: 5, output: 25),
        "claude-opus-4-1": Price(input: 15, output: 75),
        "claude-opus-4-0": Price(input: 15, output: 75),
        "claude-sonnet-5": Price(input: 3, output: 15),
        "claude-sonnet-4-6": Price(input: 3, output: 15),
        "claude-sonnet-4-5": Price(input: 3, output: 15),
        "claude-sonnet-4-0": Price(input: 3, output: 15),
        "claude-haiku-4-5": Price(input: 1, output: 5),
        "claude-3-5-haiku": Price(input: 0.8, output: 4),
        "claude-3-haiku": Price(input: 0.25, output: 1.25),
    ]

    /// `claude-haiku-4-5-20251001`, `claude-opus-5-5[1m]`, `claude-opus-4-6-fast`
    /// → the longest table key the normalised id starts with.
    public static func key(for model: String?) -> String? {
        guard var id = model?.trimmingCharacters(in: .whitespaces).lowercased(), !id.isEmpty, !id.hasPrefix("<") else { return nil }
        if id.hasPrefix("anthropic.") { id.removeFirst("anthropic.".count) }
        id = id.replacingOccurrences(of: ".", with: "-")
        for suffix in ["[1m]", "-fast", "-thinking"] where id.hasSuffix(suffix) { id.removeLast(suffix.count) }
        if let range = id.range(of: #"-\d{8}$"#, options: .regularExpression) { id.removeSubrange(range) }
        if table[id] != nil { return id }
        return table.keys.filter { id.hasPrefix($0) }.max { $0.count < $1.count }
    }

    public static func price(for model: String?) -> Price? {
        key(for: model).flatMap { table[$0] }
    }

    /// `<synthetic>` messages never reached the API: they cost exactly zero.
    /// An unknown model returns nil — "unknown" beats a quiet $0.
    public static func cost(model: String?, tokens: Tokens) -> Double? {
        if let model, model.trimmingCharacters(in: .whitespaces).hasPrefix("<") { return 0 }
        guard let price = price(for: model) else { return nil }
        let input = price.input / 1_000_000
        return Double(tokens.input) * input
            + Double(tokens.output) * price.output / 1_000_000
            + Double(tokens.cacheWrite5m) * input * 1.25
            + Double(tokens.cacheWrite1h) * input * 2
            + Double(tokens.cacheRead) * input * 0.1
    }

    public struct Tokens: Equatable, Sendable {
        public var input = 0
        public var output = 0
        public var cacheWrite5m = 0
        public var cacheWrite1h = 0
        public var cacheRead = 0

        public init(input: Int = 0, output: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0) {
            self.input = input
            self.output = output
            self.cacheWrite5m = cacheWrite5m
            self.cacheWrite1h = cacheWrite1h
            self.cacheRead = cacheRead
        }

        public static func + (a: Tokens, b: Tokens) -> Tokens {
            Tokens(
                input: a.input + b.input,
                output: a.output + b.output,
                cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
                cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
                cacheRead: a.cacheRead + b.cacheRead
            )
        }
    }
}

/// What a finished session cost, read from its transcript
/// (`~/.claude/projects/<cwd>/<session-id>.jsonl`). The log format is not a
/// public contract: unknown lines are skipped, never fatal.
///
/// Claude Code writes the same assistant turn two or three times, identical
/// but for `uuid`; summing without dedup over-reports ~2.3x. The key is
/// `requestId` + `message.id`.
public struct TranscriptSummary: Equatable, Sendable {
    public var costUSD: Double
    /// Turns whose model has no known price; their cost is not in `costUSD`.
    public var unpricedTurns: Int
    public var turns: Int
    public var tokens: ModelPricing.Tokens
    public var firstPrompt: String?
    public var firstAt: Date?
    public var lastAt: Date?

    public static func read(_ url: URL) -> TranscriptSummary? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> TranscriptSummary {
        var summary = TranscriptSummary(costUSD: 0, unpricedTurns: 0, turns: 0, tokens: .init(), firstPrompt: nil, firstAt: nil, lastAt: nil)
        var seen = Set<String>()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let newline = UInt8(ascii: "\n")
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: newline) ?? data.endIndex
            defer { start = end < data.endIndex ? data.index(after: end) : data.endIndex }
            let line = data[start..<end]
            guard !line.isEmpty,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            let type = object["type"] as? String
            if let stamp = object["timestamp"] as? String, let date = iso.date(from: stamp) {
                if summary.firstAt == nil { summary.firstAt = date }
                summary.lastAt = date
            }
            if type == "user", summary.firstPrompt == nil, object["isMeta"] as? Bool != true,
               let text = promptText(object["message"]) {
                summary.firstPrompt = text
            }
            guard type == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let key = "\(object["requestId"] as? String ?? "-"):\(message["id"] as? String ?? UUID().uuidString)"
            guard seen.insert(key).inserted else { continue }

            func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
            let creation = usage["cache_creation"] as? [String: Any]
            let write1h = int(creation?["ephemeral_1h_input_tokens"])
            let write5m = creation?["ephemeral_5m_input_tokens"] != nil
                ? int(creation?["ephemeral_5m_input_tokens"])
                : int(usage["cache_creation_input_tokens"]) - write1h
            let tokens = ModelPricing.Tokens(
                input: int(usage["input_tokens"]),
                output: int(usage["output_tokens"]),
                cacheWrite5m: max(0, write5m),
                cacheWrite1h: write1h,
                cacheRead: int(usage["cache_read_input_tokens"])
            )
            summary.turns += 1
            summary.tokens = summary.tokens + tokens
            if let legacy = object["costUSD"] as? Double {
                summary.costUSD += legacy
            } else if let cost = ModelPricing.cost(model: message["model"] as? String, tokens: tokens) {
                summary.costUSD += cost
            } else {
                summary.unpricedTurns += 1
            }
        }
        return summary
    }

    /// The user's text from a transcript message, skipping tool results and
    /// command wrappers like `<command-name>`.
    static func promptText(_ message: Any?) -> String? {
        guard let message = message as? [String: Any] else { return nil }
        var text: String?
        if let content = message["content"] as? String {
            text = content
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return trimmed
    }
}
