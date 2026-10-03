import CoreGraphics
import Foundation
import Testing
@testable import CanvasCore

@Suite struct CanvasCoreTests {
    let viewport = CGSize(width: 1000, height: 800)

    @Test func screenAndCanvasRoundTrip() {
        let camera = Camera(center: CGPoint(x: 400, y: -200), scale: 0.5)
        let canvas = CGPoint(x: 120, y: 80)
        let screen = camera.screenPoint(fromCanvas: canvas, viewport: viewport)
        let back = camera.canvasPoint(fromScreen: screen, viewport: viewport)
        #expect(abs(back.x - canvas.x) < 0.001)
        #expect(abs(back.y - canvas.y) < 0.001)
    }

    @Test func centerSitsAtTheViewportCenter() {
        let camera = Camera(center: CGPoint(x: 30, y: -10), scale: 0.8)
        let screen = camera.screenPoint(fromCanvas: camera.center, viewport: viewport)
        #expect(abs(screen.x - viewport.width / 2) < 0.001)
        #expect(abs(screen.y - viewport.height / 2) < 0.001)
    }

    @Test func zoomKeepsThePointUnderTheCursor() {
        var camera = Camera(center: CGPoint(x: 100, y: 50), scale: 1)
        let cursor = CGPoint(x: 200, y: 120)
        let anchor = camera.canvasPoint(fromScreen: cursor, viewport: viewport)
        camera = camera.zoomed(by: 1.2, around: cursor, viewport: viewport)
        let after = camera.canvasPoint(fromScreen: cursor, viewport: viewport)
        #expect(abs(after.x - anchor.x) < 0.001)
        #expect(abs(after.y - anchor.y) < 0.001)
        #expect(abs(camera.scale - 1.2) < 0.001)
    }

    @Test func zoomClampsToTheAllowedRange() {
        let camera = Camera(center: .zero, scale: 1)
        let cursor = CGPoint(x: 100, y: 100)
        let small = CGSize(width: 200, height: 200)
        #expect(camera.zoomed(by: 10, around: cursor, viewport: small).scale == Camera.maxScale)
        #expect(camera.zoomed(by: 0.001, around: cursor, viewport: small).scale == Camera.minScale)
        #expect(Camera(center: .zero, scale: 99).scale == Camera.maxScale)
    }

    @Test func zoomSnapsWhenItLandsNearOne() {
        let cursor = CGPoint(x: 100, y: 100)
        let small = CGSize(width: 200, height: 200)
        let camera = Camera(center: .zero, scale: 0.99)
        let next = camera.zoomed(by: 1.005, around: cursor, viewport: small)
        #expect(next.scale == 1)
    }

    @Test func oneStaysPutUntilTheGestureLeavesTheBand() {
        let cursor = CGPoint(x: 100, y: 100)
        let small = CGSize(width: 200, height: 200)
        let camera = Camera(center: .zero, scale: 1)
        #expect(camera.zoomed(by: 1.03, around: cursor, viewport: small).scale == 1)
        let left = camera.zoomed(by: 1.05, around: cursor, viewport: small)
        #expect(left.scale > 1)
    }

    @Test func panMovesTheCenterByScreenPointsOverScale() {
        let camera = Camera(center: CGPoint(x: 100, y: 80), scale: 1)
        let next = camera.panned(byScreen: CGPoint(x: 20, y: -10))
        #expect(abs(next.center.x - 80) < 0.001)
        #expect(abs(next.center.y - 90) < 0.001)
        #expect(next.scale == 1)
    }

    @Test func fitCentersContentAndClampsScale() {
        let content = CGRect(x: 100, y: 200, width: 400, height: 200)
        let camera = Camera(center: .zero, scale: 1).fitted(to: content, viewport: CGSize(width: 800, height: 800))
        #expect(abs(camera.center.x - 300) < 0.001)
        #expect(abs(camera.center.y - 300) < 0.001)
        #expect(camera.scale == Camera.fitMaxScale)
    }

    @Test func layoutRoundTripKeepsNodesCameraAndVersion() throws {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let browser = Node(
            id: id,
            title: "Browser",
            frame: CGRect(x: 10, y: 20, width: 960, height: 640),
            kind: .browser,
            state: .browser(BrowserState(url: "https://example.com"))
        )
        let external = Node(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Safari",
            frame: CGRect(x: 40, y: 80, width: 100, height: 80),
            kind: .external(bundleID: "com.apple.Safari"),
            state: .external(ExternalState(bundleID: "com.apple.Safari"))
        )
        let layout = Layout(
            camera: Camera(center: CGPoint(x: 12, y: 34), scale: 0.5),
            nodes: [browser, external]
        )
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(Layout.self, from: data)
        #expect(decoded == layout)
        #expect(decoded.version == Layout.currentVersion)
    }

    @Test func decodedScaleIsClamped() throws {
        let encoded = try JSONEncoder().encode(Camera(center: .zero, scale: 1))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["scale"] = 9
        let camera = try JSONDecoder().decode(Camera.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(camera.scale == Camera.maxScale)
    }

    @Test func rejectsMismatchedKindAndState() throws {
        let node = Node(
            id: UUID(),
            title: "Browser",
            frame: CGRect(x: 0, y: 0, width: 10, height: 10),
            kind: .browser,
            state: .browser(BrowserState())
        )
        let data = try JSONEncoder().encode(node)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var state = try #require(object["state"] as? [String: Any])
        state["type"] = "terminal"
        state["workingDirectory"] = "/tmp"
        var tampered = object
        tampered["state"] = state
        let payload = try JSONSerialization.data(withJSONObject: tampered)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Node.self, from: payload)
        }
    }

    /// Editor, files and media cards left the picker long ago, but a
    /// `canvas.json` written before that must still open.
    @Test func legacyKindsStillDecode() throws {
        let legacy: [(NodeKind, NodeState)] = [
            (.code, .code(CodeState(path: "/src/main.swift"))),
            (.files, .files(FilesState(path: "/src"))),
            (.media, .media(MediaState(path: "/pic.png"))),
        ]
        for (kind, state) in legacy {
            let node = Node(
                id: UUID(),
                title: Node.defaultTitle(for: kind),
                frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                kind: kind,
                state: state
            )
            let data = try JSONEncoder().encode(node)
            let decoded = try JSONDecoder().decode(Node.self, from: data)
            #expect(decoded == node)
        }
    }

    @Test func freeFrameUsesThePointWhenNothingIsThere() {
        let layout = Layout()
        let size = CGSize(width: 200, height: 100)
        let frame = layout.freeFrame(near: CGPoint(x: 15, y: 25), size: size)
        #expect(frame == CGRect(x: 15, y: 25, width: 200, height: 100))
    }

    @Test func freeFrameStepsRightOfAnOccupiedSpot() {
        let occupant = Node(
            id: UUID(),
            title: "Browser",
            frame: CGRect(x: 0, y: 0, width: 200, height: 100),
            kind: .browser,
            state: .browser(BrowserState())
        )
        let layout = Layout(nodes: [occupant])
        let frame = layout.freeFrame(near: .zero, size: CGSize(width: 200, height: 100), gap: 24)
        #expect(frame.origin == CGPoint(x: 224, y: 0))
    }

    @Test func contentBoundsUnionsEveryNode() {
        let layout = Layout(nodes: [
            Node(id: UUID(), title: "A", frame: CGRect(x: 0, y: 10, width: 20, height: 20), kind: .files, state: .files(FilesState())),
            Node(id: UUID(), title: "B", frame: CGRect(x: 50, y: 0, width: 10, height: 5), kind: .media, state: .media(MediaState())),
        ])
        #expect(layout.contentBounds == CGRect(x: 0, y: 0, width: 60, height: 30))
        #expect(Layout().contentBounds == nil)
    }

    @Test func dotSpacingThinsOutAndDensifies() {
        #expect(DotGrid.canvasStep(scale: 1) == 24)
        #expect(DotGrid.canvasStep(scale: 0.5) == 48)
        #expect(DotGrid.canvasStep(scale: 0.25) == 96)
        #expect(DotGrid.canvasStep(scale: 0.05) == 384)
        #expect(DotGrid.canvasStep(scale: 1.5) == 12)
        #expect(DotGrid.canvasStep(scale: 2.56) == 12)
        #expect(DotGrid.canvasStep(scale: 0.16) == 192)
    }

    @Test func dotScreenSpacingStaysReadable() {
        for scale in [CGFloat(0.05), 0.1, 0.16, 0.25, 0.5, 1, 1.25, 1.5, 2, 2.56] {
            let screen = DotGrid.canvasStep(scale: scale) * scale
            #expect(screen + 0.001 >= DotGrid.minScreenSpacing)
            #expect(screen <= DotGrid.maxScreenSpacing + 0.001)
        }
    }
}

@Suite struct LayoutFileTests {
    @Test func terminalSessionAndUsageComeBack() throws {
        let terminal = Node(id: UUID(), title: "Fix login", frame: CGRect(x: -500, y: 40, width: 780, height: 480),
                            kind: .terminal, state: .terminal(TerminalState(workingDirectory: "/tmp/app", claudeSessionID: "abc-123")))
        let usage = Node(id: UUID(), title: "Usage", frame: CGRect(x: 900, y: 0, width: 520, height: 700), kind: .usage, state: .usage(UsageState()))
        let layout = Layout(camera: Camera(center: CGPoint(x: -120, y: 300), scale: 0.5), nodes: [terminal, usage])
        #expect(LayoutFile.decode(try LayoutFile.encode(layout)) == .layout(layout))
    }

    @Test func plainShellHasNoSession() throws {
        let node = Node(id: UUID(), title: "Terminal", frame: .init(x: 0, y: 0, width: 10, height: 10), kind: .terminal, state: .terminal(TerminalState(workingDirectory: "/tmp")))
        let data = try LayoutFile.encode(Layout(nodes: [node]))
        #expect(!String(decoding: data, as: UTF8.self).contains("claudeSessionID"))
    }

    @Test func installedAppCardsAreDropped() throws {
        let external = Node(id: UUID(), title: "Mail", frame: .init(x: 0, y: 0, width: 10, height: 10), kind: .external(bundleID: "com.apple.mail"), state: .external(ExternalState(bundleID: "com.apple.mail")))
        guard case .layout(let restored) = LayoutFile.decode(try LayoutFile.encode(Layout(nodes: [external]))) else {
            Issue.record("not a layout")
            return
        }
        #expect(restored.nodes.isEmpty)
    }

    @Test func newerAndBrokenFilesAreSetAside() {
        #expect(LayoutFile.decode(Data(#"{"version": 99, "nodes": []}"#.utf8)) == .newer(version: 99))
        #expect(LayoutFile.decode(Data("not json".utf8)) == .unreadable)
        #expect(LayoutFile.decode(Data(#"{"version": 1, "nodes": "x"}"#.utf8)) == .unreadable)
    }
}

@Suite struct NoticeTests {
    let node = UUID()
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func status(_ state: AgentState, _ reason: WaitReason? = nil, detail: String? = nil, hooked: Bool = true) -> AgentStatus {
        AgentStatus(state: state, reason: reason, detail: detail, hooked: hooked, updatedAt: t0)
    }

    @Test func permissionIsStickyWithAnswers() {
        guard case .post(let notice) = Notice.change(from: status(.working), to: status(.waiting, .permission, detail: "Bash"), node: node, title: "ENG-1", at: t0) else {
            Issue.record("no notice"); return
        }
        #expect(notice.kind == .waiting && notice.sticky && notice.expiresAt == nil)
        #expect(notice.text == "Wants permission: Bash")
        #expect(notice.actions == [.allow, .deny, .open])
    }

    @Test func workingAgainResolvesAndDoneExpires() {
        #expect(Notice.change(from: status(.waiting, .permission), to: status(.working), node: node, title: "x", at: t0) == .resolve(node))
        guard case .post(let done) = Notice.change(from: status(.working), to: status(.done), node: node, title: "x", at: t0) else {
            Issue.record("no notice"); return
        }
        #expect(done.expiresAt == t0.addingTimeInterval(8))
        #expect(Notice.change(from: status(.done), to: status(.waiting, .input), node: node, title: "x", at: t0) == .none)
    }

    @Test func bellFromPlainTerminalIsInfo() {
        guard case .post(let bell) = Notice.change(from: status(.idle, hooked: false), to: status(.waiting, .input, hooked: false), node: node, title: "zsh", at: t0) else {
            Issue.record("no notice"); return
        }
        #expect(bell.kind == .info && !bell.sticky)
    }

    @Test func oneNoticePerCardAndOrder() {
        var queue = NoticeQueue()
        let other = UUID()
        queue.post(Notice(sourceNodeID: node, kind: .waiting, title: "a", text: "", sticky: true, postedAt: t0))
        queue.post(Notice(sourceNodeID: other, kind: .waiting, title: "b", text: "", sticky: true, postedAt: t0.addingTimeInterval(1)))
        let replaced = queue.post(Notice(sourceNodeID: node, kind: .done, title: "a", text: "", postedAt: t0.addingTimeInterval(2)))
        #expect(replaced.count == 1)
        #expect(queue.notices.map(\.title) == ["b", "a"])
        #expect(queue.resolve(source: other).count == 1)
        #expect(queue.notices.count == 1)
    }

    @Test func expiryHoldAndLimit() {
        var queue = NoticeQueue()
        for index in 0..<8 {
            queue.post(Notice(sourceNodeID: UUID(), kind: .info, title: "\(index)", text: "", postedAt: t0))
        }
        #expect(queue.visible.shown.count == 5 && queue.visible.more == 3)
        let held = queue.notices[0].id
        queue.hold(held, true, at: t0)
        #expect(queue.expire(at: t0.addingTimeInterval(9)).count == 7)
        #expect(queue.notices.map(\.id) == [held])
        queue.hold(held, false, at: t0.addingTimeInterval(10))
        #expect(queue.expire(at: t0.addingTimeInterval(15)).count == 1)
    }
}

@Suite struct JumpSearchTests {
    let items = [
        JumpItem(id: "a", title: "Fix the PDF export", subtitle: "~/work/acme-web", keywords: ["work"], group: .card, rank: 1),
        JumpItem(id: "b", title: "Terminal", subtitle: "~/dev/canvas-station", group: .card, rank: 3),
        JumpItem(id: "c", title: "Needs permission", subtitle: "~/dev/canvas-station", group: .waiting, rank: 0),
        JumpItem(id: "d", title: "New Terminal", group: .command),
        JumpItem(id: "e", title: "Old export session", subtitle: "~/work/acme-web", group: .recent),
    ]

    @Test func emptyQueryGroupsThenRank() {
        #expect(JumpSearch.rank(items, query: "").map(\.id) == ["c", "b", "a", "d", "e"])
    }

    @Test func titleWordBeatsFolderAndRecent() {
        let ids = JumpSearch.rank(items, query: "export").map(\.id)
        #expect(ids.first == "a")
        #expect(ids.contains("e") && !ids.contains("b"))
    }

    @Test func folderWordAndLettersInOrder() {
        #expect(JumpSearch.rank(items, query: "web").map(\.id).prefix(1) == ["a"])
        #expect(JumpSearch.rank(items, query: "ntrm").map(\.id).contains("d"))
        #expect(JumpSearch.rank(items, query: "zzz").isEmpty)
    }

    @Test func wordStartScoresAboveInside() {
        #expect(JumpSearch.score("term", in: "new terminal")! > JumpSearch.score("term", in: "determine")!)
    }
}

@Suite struct BrowserAddressTests {
    @Test func urlsHostsAndSearch() {
        #expect(BrowserAddress.resolve("https://github.com/x")?.absoluteString == "https://github.com/x")
        #expect(BrowserAddress.resolve("github.com")?.absoluteString == "https://github.com")
        #expect(BrowserAddress.resolve("localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(BrowserAddress.resolve("127.0.0.1:8080/api")?.absoluteString == "http://127.0.0.1:8080/api")
        #expect(BrowserAddress.resolve("swift concurrency")?.absoluteString == "https://www.google.com/search?q=swift%20concurrency")
        #expect(BrowserAddress.resolve("a&b")?.absoluteString.hasPrefix(BrowserAddress.searchURL) == true)
        #expect(BrowserAddress.resolve("  ") == nil)
    }

    @Test func detectsDevServerAcrossPiecesAndColours() {
        var detector = LocalURLDetector()
        #expect(detector.feed(Array("  ➜  Local:   \u{1B}[36mhttp://local".utf8)) == nil)
        #expect(detector.feed(Array("host:\u{1B}[1m5173\u{1B}[22m/\u{1B}[39m\n".utf8))?.absoluteString == "http://localhost:5173/")
        #expect(detector.feed(Array("ready\n".utf8)) == nil)
        #expect(detector.feed(Array("Listening on http://0.0.0.0:8000.".utf8))?.absoluteString == "http://localhost:8000")
        #expect(detector.feed(Array("see https://example.com".utf8)) == nil)
        #expect(detector.feed(Array("Serving HTTP on :: port 8765 (http://[::]:8765/) ...".utf8))?.absoluteString == "http://localhost:8765/")
    }
}

@Suite struct LinearURLTests {
    @Test func issueAndWorkspaceFromAddress() {
        let url = URL(string: "https://linear.app/acme/issue/ABC-961/pdf-lm-hide-columns#comment-1")!
        #expect(LinearURL.issueID(in: url) == "ABC-961")
        #expect(LinearURL.workspace(in: url) == "acme")
        #expect(LinearURL.issueID(in: URL(string: "https://linear.app/acme/team/GREEN/active")!) == nil)
        #expect(LinearURL.issueID(in: URL(string: "https://example.com/acme/issue/ABC-1")!) == nil)
        #expect(LinearURL.myIssues(workspace: "acme").absoluteString == "https://linear.app/acme/my-issues/assigned")
        #expect(LinearURL.myIssues(workspace: nil).absoluteString == "https://linear.app/")
    }
}

@Suite struct AgentTaskTests {
    let issue = AgentTask.Issue(id: "ABC-7", title: "Fix the export", description: "Steps:\n1. Export", url: "https://linear.app/acme/issue/ABC-7", branch: "abc-7-fix")

    @Test func builtInPromptCarriesTheIssue() {
        let prompt = AgentTask.implement.prompt(for: issue)
        #expect(prompt.hasPrefix("Implement Linear issue ABC-7."))
        #expect(prompt.contains("ABC-7: Fix the export") && prompt.contains("abc-7-fix") && prompt.contains("1. Export"))
    }

    @Test func customTextLeadsAndLongDescriptionsAreCut() {
        let long = AgentTask.Issue(id: "ABC-8", title: "t", description: String(repeating: "x", count: 9000))
        let prompt = AgentTask.custom("  Only update the docs.  ").prompt(for: long)
        #expect(prompt.hasPrefix("Only update the docs.\n"))
        #expect(prompt.contains("(cut; the full issue is at the link above)"))
        #expect(prompt.count < 6300)
    }
}
