/// A notification a program asked the terminal to show.
public struct TerminalNotice: Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// Finds OSC 777 (`ESC ] 777 ; notify ; title ; body BEL`) and iTerm2-style
/// OSC 9 (`ESC ] 9 ; text BEL`) in the byte stream a terminal receives.
/// SwiftTerm handles OSC 777 in a protocol-extension default that a host
/// cannot override, so the card reads the bytes itself. Sequences split across
/// reads are carried over; OSC 9;4 progress reports are skipped.
public struct OSCNotificationSniffer: Sendable {
    private enum State: Sendable { case ground, escape, osc, oscEscape }

    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07
    private static let maxPayload = 4096

    private var state = State.ground
    private var payload: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: ArraySlice<UInt8>) -> [TerminalNotice] {
        var found: [TerminalNotice] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if state == .ground {
                // Fast path: almost all output is plain text.
                guard let next = bytes[index...].firstIndex(of: Self.esc) else { break }
                index = next + 1
                state = .escape
                continue
            }
            let byte = bytes[index]
            index += 1
            switch state {
            case .ground:
                break
            case .escape:
                if byte == 0x5D {
                    payload.removeAll(keepingCapacity: true)
                    state = .osc
                } else if byte != Self.esc {
                    state = .ground
                }
            case .osc:
                if byte == Self.bel {
                    if let notice = finish() { found.append(notice) }
                } else if byte == Self.esc {
                    state = .oscEscape
                } else if payload.count < Self.maxPayload {
                    payload.append(byte)
                } else {
                    state = .ground
                }
            case .oscEscape:
                if byte == 0x5C {
                    if let notice = finish() { found.append(notice) }
                } else {
                    // An ESC that is not ST aborts the OSC and may start another.
                    state = byte == 0x5D ? .osc : .ground
                    payload.removeAll(keepingCapacity: true)
                }
            }
        }
        return found
    }

    private mutating func finish() -> TerminalNotice? {
        state = .ground
        let text = String(decoding: payload, as: UTF8.self)
        payload.removeAll(keepingCapacity: true)
        guard let semicolon = text.firstIndex(of: ";") else { return nil }
        let code = text[..<semicolon]
        let rest = text[text.index(after: semicolon)...]
        switch code {
        case "777":
            let parts = rest.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.first == "notify" else { return nil }
            let title = parts.count > 1 ? String(parts[1]) : ""
            let body = parts.count > 2 ? String(parts[2]) : ""
            return TerminalNotice(title: title, body: body)
        case "9":
            // ConEmu subcommands (9;4;… progress and friends) start with digits.
            if let first = rest.split(separator: ";", maxSplits: 1).first, first.allSatisfy(\.isNumber) {
                return nil
            }
            return rest.isEmpty ? nil : TerminalNotice(title: "", body: String(rest))
        default:
            return nil
        }
    }
}
