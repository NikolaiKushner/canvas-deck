import Foundation

/// What the browser card's address field means: a URL to open, or words to
/// search for.
public enum BrowserAddress {
    public static let searchURL = "https://www.google.com/search?q="

    public static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about"].contains(scheme) {
            return url
        }
        if !text.contains(" "), looksLikeHost(text) {
            // Local servers speak plain http; everything else is tried over https.
            return URL(string: (isLocal(text) ? "http://" : "https://") + text)
        }
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? text
        return URL(string: searchURL + query)
    }

    static func looksLikeHost(_ text: String) -> Bool {
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let name = host.split(separator: ":").first.map(String.init) ?? host
        if isLocal(text) { return true }
        if name.split(separator: ".").count >= 2, let last = name.split(separator: ".").last, last.count >= 2, last.allSatisfy(\.isLetter) || name.allSatisfy({ $0.isNumber || $0 == "." }) {
            return true
        }
        return false
    }

    static func isLocal(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["localhost", "127.0.0.1", "0.0.0.0", "[::1]"].contains { lower == $0 || lower.hasPrefix($0 + ":") || lower.hasPrefix($0 + "/") }
            || lower.split(separator: "/").first.map { $0.hasSuffix(".local") || $0.hasSuffix(".test") || $0.contains(".local:") } ?? false
    }
}

/// Finds the address of a local dev server in a terminal's output, e.g.
/// "Local: http://localhost:5173/". Bytes come in pieces; a short tail is
/// kept so an address split between two pieces is still found.
public struct LocalURLDetector: Sendable {
    private var tail = ""
    private static let pattern = try! NSRegularExpression(
        pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(?::\d{2,5})?(?:/[^\s"'<>)\]]*)?"#,
        options: [.caseInsensitive]
    )
    private static let escape = try! NSRegularExpression(pattern: #"\x1B(?:\[[0-9;?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[()][A-Za-z0-9])"#)

    public init() {}

    /// The last local address in this piece of output, if any.
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> URL? {
        let text = tail + String(decoding: Array(bytes), as: UTF8.self)
        let plain = Self.escape.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        tail = String(plain.suffix(80))
        let matches = Self.pattern.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
        guard let match = matches.last, let range = Range(match.range, in: plain) else { return nil }
        // Found once: the tail must not report it again with the next piece.
        tail = String(plain[range.upperBound...].suffix(80))
        var address = String(plain[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        // 0.0.0.0 means "every interface"; a browser wants localhost.
        address = address.replacingOccurrences(of: "://0.0.0.0", with: "://localhost").replacingOccurrences(of: "://[::]", with: "://localhost")
        return URL(string: address)
    }
}
