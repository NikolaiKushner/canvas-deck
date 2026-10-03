import Foundation
import Testing
@testable import CanvasCore

@Suite struct ClaudeSessionTests {
    let t0 = Date(timeIntervalSince1970: 5_000)
    let node = UUID()

    @Test func titlePrefersTicketThenNameThenPromptThenFolder() {
        var session = ClaudeSession(id: "s", nodeID: nil, cwd: "/Users/me/dev/canvas-station", openedAt: t0)
        #expect(session.title == "canvas-station")
        session.firstPrompt = "Fix the flaky login test\nand explain why"
        #expect(session.title == "Fix the flaky login test")
        session.name = "Refactor"
        #expect(session.title == "Refactor")
        session.issueID = "ENG-123"
        #expect(session.title == "ENG-123")
    }

    @Test func shortenCutsAtAWord() {
        let text = "Investigate why the minimap flickers when zooming out below a quarter scale"
        let short = ClaudeSession.shorten(text, limit: 30)
        #expect(short == "Investigate why the minimap…")
        #expect(ClaudeSession.shorten(String(repeating: "x", count: 40), limit: 10) == "xxxxxxxxx…")
    }

    @Test func attachThenPromptThenClose() {
        var index = ClaudeSessionIndex()
        index.attach(id: "a", node: node, cwd: "/tmp", at: t0)
        index.notePrompt("first", id: "a", at: t0 + 1)
        index.notePrompt("second", id: "a", at: t0 + 2)
        #expect(index.openSession(node: node)?.firstPrompt == "first")
        #expect(index.open.count == 1)
        index.close(id: "a", at: t0 + 3)
        #expect(index.open.isEmpty)
        #expect(index.recent.first?.id == "a" && index.recent.first?.nodeID == nil)
    }

    @Test func newIdInTheSameCardEndsThePreviousOne() {
        var index = ClaudeSessionIndex()
        index.attach(id: "a", node: node, cwd: "/tmp", at: t0)
        index.attach(id: "b", node: node, cwd: "/tmp", at: t0 + 1) // e.g. /clear
        #expect(index.openSession(node: node)?.id == "b")
        #expect(index.session(id: "a")?.closedAt == t0 + 1)
    }

    @Test func resumingAKnownIdReopensIt() {
        var index = ClaudeSessionIndex()
        index.attach(id: "a", node: node, cwd: "/tmp", at: t0)
        index.close(id: "a", at: t0 + 1)
        let other = UUID()
        index.attach(id: "a", node: other, cwd: "/tmp", at: t0 + 2)
        #expect(index.sessions.count == 1)
        #expect(index.openSession(node: other)?.id == "a")
    }

    @Test func indexIsBounded() {
        var index = ClaudeSessionIndex()
        for i in 0..<(ClaudeSessionIndex.limit + 5) {
            index.attach(id: "s\(i)", node: UUID(), cwd: "/tmp", at: t0 + Double(i))
        }
        #expect(index.sessions.count == ClaudeSessionIndex.limit)
        #expect(index.sessions.first?.id == "s\(ClaudeSessionIndex.limit + 4)")
    }

    @Test func launchClosesSessionsLeftOpen() throws {
        var index = ClaudeSessionIndex()
        index.attach(id: "a", node: node, cwd: "/tmp", at: t0)
        index.closeAllOpen(at: t0 + 9)
        #expect(index.open.isEmpty)
        let decoded = try JSONDecoder().decode(ClaudeSessionIndex.self, from: JSONEncoder().encode(index))
        #expect(decoded == index)
    }
}
