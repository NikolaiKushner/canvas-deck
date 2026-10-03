import AppKit
import QuartzCore
import CanvasCore
import os
import Combine
import SwiftUI
import Usage
import Trackers

private final class SubviewRanks {
    let ranks: [ObjectIdentifier: Int]
    init(_ ranks: [ObjectIdentifier: Int]) { self.ranks = ranks }
}

/// The canvas shell. A normal application window: it never hides, moves, or
/// restacks other apps' windows.
@MainActor
final class CanvasController: NSObject, NSWindowDelegate, NSMenuDelegate {
    /// Every change is saved (`CanvasStore`, a second later).
    private(set) var layout = Layout() {
        didSet { store.save(layout) }
    }
    private let store = CanvasStore()
    /// Restored once per launch; a reopened window keeps what is in memory.
    private var restored = false
    private var window: NSWindow?
    private var root: CanvasRootView?
    private var scroll: CanvasScrollView?
    private var document: CanvasDocumentView?
    private var minimap: MinimapView?
    private var zoomPill: ZoomPillView?
    private var cameraAnimation: Timer?
    /// One queue for every card's notices.
    private let notices = NoticeCenter()
    private var noticeStack: NoticeStackView?
    private var jumpPalette: JumpPalettePanel?
    private var defaultsObserver: NSObjectProtocol?
    private var zoomMenu: ZoomMenu?
    private var hint: NSTextField?
    private var views: [UUID: NodeContainerView] = [:]
    private var terminals: [UUID: TerminalNode] = [:]
    private var browsers: [UUID: BrowserNode] = [:]
    /// The dev server each terminal printed last, for its "Open Preview".
    private var previewURLs: [UUID: URL] = [:]
    /// The browser card a terminal's preview opened, reused next time.
    private var previewBrowsers: [UUID: UUID] = [:]
    /// When each browser card was last in view; long out of it, it unloads.
    private var browserLastSeen: [UUID: Date] = [:]
    private var browserSweep: Timer?
    static let browserUnloadAfter: TimeInterval = 3 * 60
    private var cliWatch: AnyCancellable?
    /// The target of the scroll gesture in progress: the active card or the canvas.
    private var scrollGoesToCard: Bool?
    private var accountObserver: NSObjectProtocol?
    /// What the agent in each terminal card is doing.
    private var statuses: [UUID: AgentStatus] = [:]
    /// Scripts for cards about to be mounted, e.g. a Claude Code launch.
    private var pendingLaunches: [UUID: String] = [:]
    private let notifyServer = NotifyServer()
    /// Claude Code sessions and usage.
    let sessionStore = ClaudeSessionStore()
    let usage = UsageStore()
    private lazy var usageProbe = UsageProbe(usage: usage)
    private var usageHUD: NSView?
    private var usageHUDWatch: AnyCancellable?
    private var lastActiveTerminalDirectory: String?
    private var activeID: UUID?
    private var monitor: Any?
    private var picker: AppPickerPanel?
    private var folderPicker: FolderPickerPanel?
    private var pendingPoint: CGPoint = .zero
    private var spaceHeld = false
    private var dragAnchor: NSPoint?
    private var didApplyLaunchSeed = false

    func show() {
        if !restored {
            restored = true
            layout = store.load()
            migrateBoards()
        }
        if window == nil {
            store.reopen()
            prepareRestoredTerminals()
            build()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }


    /// The app is quitting: the layout goes to disk before the terminals die.
    func saveNow() {
        store.close(with: layout)
    }

    /// A Claude Code card comes back with its conversation: `claude --resume`
    /// in the account that holds the transcript. A session Claude Code did not
    /// save (e.g. an organization that keeps no transcripts) cannot be
    /// resumed: the card opens a shell and says so.
    private func prepareRestoredTerminals() {
        for node in layout.nodes {
            guard case .terminal(let state) = node.state, let id = state.claudeSessionID, pendingLaunches[node.id] == nil else { continue }
            let relaunch = ShellIntegration.relaunchCommand(shell: TerminalNode.shell)
            if let account = ClaudeConfig.account(ofSession: id, cwd: state.workingDirectory) {
                pendingLaunches[node.id] = ClaudeLaunch.shellScript(
                    shell: TerminalNode.shell,
                    start: .resume(sessionID: id),
                    name: sessionStore.index.session(id: id)?.name,
                    notifyPath: TerminalNode.notifyPath,
                    configDirectory: account
                )
                sessionStore.update { $0.attach(id: id, node: node.id, cwd: state.workingDirectory, at: Date()) }
            } else {
                let note = "Canvas Deck: Claude Code did not save session \(id) on this Mac, so it cannot be resumed."
                pendingLaunches[node.id] = "printf '%s\\n' \(ClaudeLaunch.shellQuote(note)); \(relaunch)"
                if let index = layout.nodes.firstIndex(where: { $0.id == node.id }) {
                    layout.nodes[index].state = .terminal(TerminalState(workingDirectory: state.workingDirectory))
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        store.close(with: layout)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        picker?.orderOut(nil)
        picker = nil
        folderPicker?.orderOut(nil)
        folderPicker = nil
        for terminal in terminals.values { terminal.terminate() }
        terminals.removeAll()
        statuses.removeAll()
        sessionStore.flush()
        usageHUD = nil
        usageHUDWatch = nil
        notifyServer.stop()
        usageProbe.stop()
        views.removeAll()
        activeID = nil
        window = nil
        root = nil
        scroll = nil
        document = nil
        minimap = nil
        zoomPill = nil
        stopCameraAnimation()
        noticeStack = nil
        jumpPalette?.orderOut(nil)
        jumpPalette = nil
        browserSweep?.invalidate()
        browserSweep = nil
        browsers.removeAll()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        hint = nil
    }

    // MARK: - Commands

    @objc func fitAll(_ sender: Any?) {
        guard let scroll, let bounds = layout.contentBounds else { return }
        layout.camera = layout.camera.fitted(to: bounds, viewport: scroll.bounds.size)
        applyCamera(updateCursors: true)
    }

    @objc func actualSize(_ sender: Any?) {
        layout.camera = Camera(center: layout.camera.center, scale: 1)
        applyCamera(updateCursors: true)
    }

    @objc func zoomIn(_ sender: Any?) {
        guard let root else { return }
        zoom(by: 2, atWindowPoint: root.convert(CGPoint(x: root.bounds.midX, y: root.bounds.midY), to: nil))
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let root else { return }
        zoom(by: 0.5, atWindowPoint: root.convert(CGPoint(x: root.bounds.midX, y: root.bounds.midY), to: nil))
    }

    // MARK: - Linear

    /// Linear's own web app in a browser card, on my issues: its board, its
    /// order and colours, issues with their images. A card already on
    /// linear.app is reused.
    func openLinear(at point: CGPoint? = nil) {
        if let existing = browsers.first(where: { $0.value.url.map(LinearURL.isLinear) ?? false })?.key {
            fly(to: existing)
            return
        }
        let workspace = LinearConnection.shared.sync.issues.compactMap(\.url).compactMap(LinearURL.workspace(in:)).first
        let url = LinearURL.myIssues(workspace: workspace)
        if let point {
            addNode(title: "Linear", kind: .browser, state: .browser(BrowserState(url: url.absoluteString)), at: point)
        } else {
            openBrowser(url)
        }
    }

    /// The board of an older build becomes Linear in a browser card.
    private func migrateBoards() {
        let workspace = LinearConnection.shared.sync.issues.compactMap(\.url).compactMap(LinearURL.workspace(in:)).first
        for index in layout.nodes.indices where layout.nodes[index].kind == .board {
            layout.nodes[index].kind = .browser
            layout.nodes[index].title = "Linear"
            layout.nodes[index].state = .browser(BrowserState(url: LinearURL.myIssues(workspace: workspace).absoluteString))
        }
    }

    /// Linear in a card behaves like an app: no address bar, back and
    /// reload as small buttons in the card's title bar.
    private func updateAppMode(_ id: UUID, _ url: URL) {
        guard let browser = browsers[id] else { return }
        let app = LinearURL.isLinear(url)
        browser.setChromeless(app)
        guard app else {
            views[id]?.setTools([])
            return
        }
        views[id]?.setTools([
            .init(symbol: "chevron.left", help: "Back (⌘[)", enabled: browser.canGoBack) { [weak browser] in browser?.goBack() },
            .init(symbol: "arrow.clockwise", help: "Reload (⌘R)") { [weak browser] in browser?.reloadPage() },
        ])
    }

    /// On an issue's page, the card's title bar gets the issue's menu.
    private func updateLinearAccessory(_ browser: UUID, _ url: URL) {
        guard let id = LinearURL.issueID(in: url) else {
            if LinearURL.isLinear(url) { views[browser]?.setAccessory(nil, action: nil) }
            return
        }
        guard case .connected = LinearConnection.shared.state else {
            views[browser]?.setAccessory("\(id) ▾", help: "Sign in to Linear in Settings → Linear") { NSApp.sendAction(Selector(("openSettings:")), to: nil, from: nil) }
            return
        }
        views[browser]?.setAccessory("\(id) ▾", help: "Start in Claude Code, move it, or copy its branch") { [weak self] in
            self?.showIssueMenu(id, from: browser)
        }
    }

    private func showIssueMenu(_ id: String, from browser: UUID) {
        Task { [weak self] in
            guard let self else { return }
            let sync = LinearConnection.shared.sync
            guard let issue = await sync.fullIssue(id) else {
                self.notices.post(Notice(sourceNodeID: browser, kind: .error, title: id, text: "Linear did not return this issue.", postedAt: Date()))
                return
            }
            guard let view = self.views[browser], let window = self.window else { return }
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(title: "Start in Claude Code…") { [weak self] in self?.startTask(issue, nextTo: browser) })
            menu.addItem(.separator())
            let move = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for status in sync.statuses[issue.teamId ?? ""] ?? [] {
                let item = ClosureMenuItem(title: status.name) { [weak self] in self?.moveIssue(issue.id, to: status, from: browser) }
                item.state = status.name == issue.status ? .on : .off
                item.isEnabled = status.name != issue.status
                submenu.addItem(item)
            }
            move.submenu = submenu
            move.isEnabled = !submenu.items.isEmpty
            menu.addItem(move)
            let cycle = sync.currentCycles[issue.teamId ?? ""]
            if let cycle, issue.cycleId == cycle.id {
                menu.addItem(ClosureMenuItem(title: "Remove from Sprint (\(cycle.title))") { [weak self] in self?.setSprint(issue.id, current: false, from: browser) })
            } else {
                let add = ClosureMenuItem(title: cycle.map { "Add to Current Sprint (\($0.title))" } ?? "Add to Current Sprint") { [weak self] in self?.setSprint(issue.id, current: true, from: browser) }
                add.isEnabled = cycle != nil
                menu.addItem(add)
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Copy \(issue.id)") { Self.copy(issue.id) })
            if let branch = issue.gitBranchName {
                menu.addItem(ClosureMenuItem(title: "Copy Branch Name") { Self.copy(branch) })
            }
            let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            menu.popUp(positioning: nil, at: point, in: view)
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func moveIssue(_ id: String, to status: IssueStatus, from source: UUID) {
        Task { [weak self] in
            if let error = await LinearConnection.shared.sync.move(id, to: status) {
                self?.notices.post(Notice(sourceNodeID: source, kind: .error, title: id, text: "Not moved: \(error)", postedAt: Date()))
            } else {
                self?.notices.post(Notice(sourceNodeID: source, kind: .done, title: id, text: "Moved to \(status.name)", postedAt: Date()))
            }
        }
    }

    private func setSprint(_ id: String, current: Bool, from source: UUID) {
        Task { [weak self] in
            if let error = await LinearConnection.shared.sync.setSprint(id, current: current) {
                self?.notices.post(Notice(sourceNodeID: source, kind: .error, title: id, text: error, postedAt: Date()))
            } else {
                self?.notices.post(Notice(sourceNodeID: source, kind: .done, title: id, text: current ? "Added to the current sprint" : "Removed from the sprint", postedAt: Date()))
            }
        }
    }

    private var startPanel: StartTaskPanel?

    /// Claude Code on an issue: the task, the team's folder, and a status
    /// to move it to, chosen in a small panel; the card opens beside `source`.
    private func startTask(_ issue: Issue, nextTo source: UUID) {
        guard let window else { return }
        let team = issue.teamId ?? ""
        let folder = Settings.linearTeamFolders[team] ?? Settings.recentClaudeFolders.first ?? Settings.resolvedTerminalHome
        let model = StartTaskModel(issue: issue, statuses: LinearConnection.shared.sync.statuses[team] ?? [], folder: folder)
        let panel = StartTaskPanel(model: model)
        model.onCancel = { [weak self, weak panel] in
            panel?.orderOut(nil)
            self?.startPanel = nil
        }
        model.onStart = { [weak self, weak panel] task, folder, move in
            panel?.orderOut(nil)
            self?.startPanel = nil
            guard let self else { return }
            if !team.isEmpty { Settings.linearTeamFolders[team] = folder }
            ClaudeCLI.shared.whenInstalled { [weak self] in
                guard let self else { return }
                let prompt = task.prompt(for: .init(id: issue.id, title: issue.title, description: issue.description, url: issue.url?.absoluteString, branch: issue.gitBranchName))
                let frame = self.layout.node(id: source)?.frame
                let point = frame.map { CGPoint(x: $0.maxX + 40, y: $0.minY) } ?? self.centerPoint(for: .terminal)
                let card = self.addClaude(in: folder, at: point, issueID: issue.id, prompt: prompt)
                self.fly(to: card)
                if let move { self.moveIssue(issue.id, to: move, from: card) }
            }
        }
        startPanel = panel
        panel.present(over: window)
    }

    /// Linear inbox items as toasts; a click opens the comment.
    private func postLinearNotifications(_ items: [LinearNotification]) {
        guard Settings.linearNotices else { return }
        for item in items.suffix(5) {
            notices.post(Notice(sourceNodeID: nil, kind: .info, title: item.title ?? "Linear", text: item.subtitle ?? "", postedAt: Date(), link: item.url?.absoluteString))
        }
    }

    // MARK: - Browser

    private func setBrowserURL(_ id: UUID, _ url: URL) {
        guard let index = layout.nodes.firstIndex(where: { $0.id == id }) else { return }
        // A page of our own (an error) has no address worth keeping.
        guard url.scheme != "about" || url.absoluteString == "about:blank" else { return }
        layout.nodes[index].state = .browser(BrowserState(url: url.absoluteString))
    }

    /// A browser card to the right of `source` (a link with target=_blank,
    /// a preview), or in the middle of the view.
    @discardableResult
    func openBrowser(_ url: URL?, nextTo source: UUID? = nil) -> UUID {
        let point: CGPoint
        if let source, let frame = layout.node(id: source)?.frame {
            point = CGPoint(x: frame.maxX + 40, y: frame.minY)
        } else {
            point = centerPoint(for: .browser)
        }
        let id = addNode(title: url?.host() ?? "Browser", kind: .browser, state: .browser(BrowserState(url: url?.absoluteString ?? "")), at: point)
        // Bring it into view when it landed partly or wholly outside.
        if let frame = layout.node(id: id)?.frame, let scroll, !scroll.contentView.bounds.contains(frame) {
            fly(to: id)
        }
        return id
    }

    /// "Open Preview" on a terminal that printed a dev server's address.
    private func noteLocalURL(_ url: URL, from terminal: UUID) {
        guard previewURLs[terminal] != url else { return }
        previewURLs[terminal] = url
        let label = url.port.map { "Open Preview :\($0)" } ?? "Open Preview"
        views[terminal]?.setAccessory(label, help: url.absoluteString) { [weak self] in self?.openPreview(for: terminal) }
    }

    private func openPreview(for terminal: UUID) {
        guard let url = previewURLs[terminal] else { return }
        if let existing = previewBrowsers[terminal], let browser = browsers[existing] {
            browser.open(url)
            fly(to: existing)
            return
        }
        previewBrowsers[terminal] = openBrowser(url, nextTo: terminal)
    }

    /// Pages out of view for `browserUnloadAfter` give their memory back.
    private func startBrowserSweep() {
        guard browserSweep == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepBrowsers() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        browserSweep = timer
    }

    private func sweepBrowsers() {
        let now = Date()
        for (id, browser) in browsers where id != activeID && !browser.isUnloaded {
            if now.timeIntervalSince(browserLastSeen[id] ?? now) >= Self.browserUnloadAfter { browser.unloadIfIdle() }
        }
    }

    private func noteBrowsersInView() {
        guard let scroll, !browsers.isEmpty else { return }
        let visible = scroll.contentView.bounds.insetBy(dx: -400, dy: -400)
        let now = Date()
        for (id, browser) in browsers {
            guard let frame = layout.node(id: id)?.frame, frame.intersects(visible) else { continue }
            browserLastSeen[id] = now
            if browser.isUnloaded { browser.reloadAfterUnload() }
        }
    }

    // MARK: - Notices

    private func showNotices() {
        let visible = notices.queue.visible
        noticeStack?.isHidden = !Settings.noticesOnCanvas
        noticeStack?.show(Settings.noticesOnCanvas ? visible.shown : [], more: Settings.noticesOnCanvas ? visible.more : 0)
    }

    /// A toast's button. Allow and Deny type into the agent's terminal — "1"
    /// and Esc, see `Notice.Action` — and only while it still waits for that
    /// answer, so a late click never types into whatever runs there now.
    private func answerNotice(_ id: UUID, _ action: Notice.Action) {
        guard let notice = notices.queue.notices.first(where: { $0.id == id }) else { return }
        switch action {
        case .open:
            notices.open(id)
        case .allow, .deny:
            guard let node = notice.sourceNodeID, let terminal = terminals[node],
                  let status = statuses[node], status.state == .waiting, status.reason == .permission else {
                notices.dismiss(id)
                return
            }
            terminal.send(action == .allow ? "1" : "\u{1b}")
            // As if typed in the card: working until the next hook says otherwise.
            handleAgent(.userInput, for: node, at: Date())
            notices.resolve(source: node)
        }
    }

    private func openNotice(_ notice: Notice) {
        if let link = notice.link, let url = URL(string: link), url.scheme != nil {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            openBrowser(url)
            return
        }
        guard let node = notice.sourceNodeID, layout.node(id: node) != nil else { return }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        fly(to: node)
    }

    /// Brings a card into view at 100%, animated, and gives it the keyboard.
    func fly(to node: UUID) {
        guard let frame = layout.node(id: node)?.frame else { return }
        animateCamera(to: Camera(center: CGPoint(x: frame.midX, y: frame.midY), scale: 1)) { [weak self] in
            self?.activate(node)
        }
    }

    /// ⌘J: the next agent waiting for an answer — permission first, then
    /// questions, the longest waiting first; again, the one after it.
    @objc func nextWaitingAgent(_ sender: Any?) {
        let waiting = statuses.filter { terminals[$0.key] != nil && $0.value.state == .waiting && $0.value.hooked }
            .sorted { a, b in
                let ra = a.value.reason == .permission ? 0 : 1, rb = b.value.reason == .permission ? 0 : 1
                return ra != rb ? ra < rb : a.value.updatedAt < b.value.updatedAt
            }
            .map(\.key)
        guard !waiting.isEmpty else { return NSSound.beep() }
        let next = activeID.flatMap { waiting.firstIndex(of: $0) }.map { waiting[($0 + 1) % waiting.count] } ?? waiting[0]
        fly(to: next)
    }

    // MARK: - ⌘K palette

    /// Cards to fly to (agents waiting for an answer first), commands, and
    /// past sessions to resume, in one searchable list.
    @objc func showJumpPalette(_ sender: Any?) {
        guard let window else { return }
        jumpPalette?.orderOut(nil)
        let panel = JumpPalettePanel(rows: jumpRows())
        panel.model.onDone = { [weak self, weak panel] in
            panel?.model.onDone = nil
            panel?.orderOut(nil)
            if self?.jumpPalette === panel { self?.jumpPalette = nil }
        }
        jumpPalette = panel
        panel.present(over: window)
    }

    private func jumpRows() -> [JumpRow] {
        var rows: [JumpRow] = []
        let many = usage.knownAccountCount > 1
        let count = Double(layout.nodes.count)
        // Activation moves a card to the end of `layout.nodes`: later is more recent.
        for (index, node) in layout.nodes.enumerated() {
            let status = statuses[node.id]
            var folder = ""
            var agent = false
            if case .terminal(let state) = node.state {
                folder = Self.shortPath(state.workingDirectory)
                agent = status?.hooked == true || state.claudeSessionID != nil
            } else if case .browser(let state) = node.state {
                folder = state.url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            }
            let account = usage.account(of: node.id).map { usage.name(of: $0) }
            let waiting = status?.state == .waiting && status?.hooked == true
            let id = node.id
            rows.append(JumpRow(
                item: JumpItem(
                    id: "card:\(node.id)",
                    title: node.title,
                    subtitle: folder.isEmpty ? "Card" : folder,
                    keywords: [folder, account, status?.label, agent ? "claude code agent" : nil].compactMap { $0 },
                    group: waiting ? .waiting : .card,
                    rank: waiting && status?.reason == .permission ? count + 1 : Double(index)
                ),
                symbol: agent ? "sparkles" : Self.symbol(for: node.kind),
                status: status?.label,
                statusColor: status.flatMap(Self.color(for:)).map(Color.init(nsColor:)),
                badge: many ? account : nil,
                run: { [weak self] in self?.fly(to: id) }
            ))
        }
        let commands: [(String, String, String?, () -> Void)] = [
            ("New Terminal", "terminal", nil, { [weak self] in self?.paletteAdd(.terminal) }),
            ("New Browser", "globe", nil, { [weak self] in self?.openBrowser(nil) }),
            ("Linear", "checklist", nil, { [weak self] in self?.openLinear() }),
            ("New Claude Code", "sparkles", nil, { [weak self] in self?.paletteAdd(.claude) }),
            ("Resume Other Session…", "clock.arrow.circlepath", nil, { [weak self] in self?.resumeOtherSession(nil) }),
            ("Next Waiting Agent", "bell.badge", "⌘J", { [weak self] in self?.nextWaitingAgent(nil) }),
            ("Usage", "gauge.with.dots.needle.33percent", "⇧⌘U", { [weak self] in self?.showUsage(nil) }),
            ("Fit All", "arrow.up.left.and.arrow.down.right", "⇧1", { [weak self] in self?.fitAll(nil) }),
            ("Zoom to 100%", "1.magnifyingglass", "⇧0", { [weak self] in self?.actualSize(nil) }),
            ("Settings…", "gearshape", "⌘,", { NSApp.sendAction(Selector(("openSettings:")), to: nil, from: nil) }),
        ]
        for (index, command) in commands.enumerated() {
            rows.append(JumpRow(
                item: JumpItem(id: "command:\(command.0)", title: command.0, subtitle: "Command", group: .command, rank: Double(commands.count - index)),
                symbol: command.1,
                shortcut: command.2,
                run: command.3
            ))
        }
        // My Linear issues: Enter opens the issue in a browser card.
        let sync = LinearConnection.shared.sync
        for (index, issue) in sync.issues.enumerated() {
            let sprint = sync.isInCurrentCycle(issue) ? sync.currentCycles[issue.teamId ?? ""]?.title : nil
            rows.append(JumpRow(
                item: JumpItem(
                    id: "issue:\(issue.id)",
                    title: "\(issue.id)  \(issue.title)",
                    subtitle: [issue.status, issue.team, sprint].compactMap { $0 }.joined(separator: " · "),
                    keywords: [issue.id, issue.gitBranchName, issue.status].compactMap { $0 } + (issue.labels ?? []),
                    group: .card,
                    rank: -Double(index) - 1000
                ),
                symbol: "checklist",
                status: sprint.map { _ in "Sprint" },
                statusColor: .purple,
                run: { [weak self] in
                    if let url = issue.url { self?.openBrowser(url) }
                }
            ))
        }
        for (index, session) in sessionStore.index.recent.prefix(30).enumerated() {
            let when = session.lastActiveAt.formatted(.relative(presentation: .named))
            rows.append(JumpRow(
                item: JumpItem(
                    id: "session:\(session.id)",
                    title: session.title,
                    subtitle: "Resume · \(Self.shortPath(session.cwd)) · \(when)",
                    keywords: [session.cwd, session.issueID, session.name].compactMap { $0 },
                    group: .recent,
                    rank: Double(-index)
                ),
                symbol: "clock",
                run: { [weak self] in self?.resume(session) }
            ))
        }
        return rows
    }

    /// A new card from the palette, in the middle of the view.
    private func paletteAdd(_ kind: BuiltinKind.Kind) {
        guard let window else { return }
        let point = centerPoint(for: .terminal)
        if kind == .claude {
            ClaudeCLI.shared.whenInstalled { [weak self] in
                guard let self else { return }
                if Settings.claudeAsksForFolder {
                    let screen = NSPoint(x: window.frame.midX - 220, y: window.frame.midY + 230)
                    self.showFolderPicker(at: point, screenPoint: screen)
                } else {
                    self.addBuiltin(BuiltinKind(kind: .claude), at: point)
                }
            }
        } else {
            addBuiltin(BuiltinKind(kind: kind), at: point)
        }
    }

    // MARK: - Camera animation

    /// Flies the camera to `target`: scale on a log curve, so every step of
    /// the zoom feels the same, ease-out, a third of a second. Any gesture
    /// stops it where it is.
    private func animateCamera(to target: Camera, duration: TimeInterval = 0.32, completion: (() -> Void)? = nil) {
        cameraAnimation?.invalidate()
        let from = layout.camera
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let t = min(1, (CACurrentMediaTime() - start) / duration)
                let e = CGFloat(1 - pow(1 - t, 3))
                let scale = exp(log(from.scale) + (log(target.scale) - log(from.scale)) * e)
                // The centre moves with the zoom, so the card grows out of
                // where it was clicked instead of sliding first.
                let reach = from.scale == target.scale ? e : (1 / from.scale - 1 / scale) / (1 / from.scale - 1 / target.scale)
                let center = CGPoint(
                    x: from.center.x + (target.center.x - from.center.x) * reach,
                    y: from.center.y + (target.center.y - from.center.y) * reach
                )
                self.layout.camera = Camera(center: center, scale: scale)
                self.applyCamera(updateCursors: t >= 1)
                if t >= 1 {
                    timer.invalidate()
                    self.cameraAnimation = nil
                    completion?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cameraAnimation = timer
    }

    private func stopCameraAnimation() {
        cameraAnimation?.invalidate()
        cameraAnimation = nil
    }

    /// Zooms to an exact scale around the centre of the view.
    func zoom(toScale target: CGFloat) {
        guard let root, let scroll, scroll.magnification > 0 else { return }
        zoom(by: Camera.clamp(target) / scroll.magnification, atWindowPoint: root.convert(CGPoint(x: root.bounds.midX, y: root.bounds.midY), to: nil))
    }

    private func showZoomMenu(from pill: ZoomPillView) {
        guard let scroll else { return }
        let menu = ZoomMenu(scale: scroll.magnification, hasCards: !layout.nodes.isEmpty, actions: .init(
            zoomIn: { [weak self] in self?.zoomIn(nil) },
            zoomOut: { [weak self] in self?.zoomOut(nil) },
            fitAll: { [weak self] in self?.fitAll(nil) },
            zoomToCard: { [weak self] in self?.zoomToNode(nil) },
            zoomTo: { [weak self] scale in self?.zoom(toScale: scale) }
        ))
        zoomMenu = menu
        menu.popUp(from: pill)
        zoomMenu = nil
    }

    @objc func zoomToNode(_ sender: Any?) {
        guard let scroll else { return }
        let frame: CGRect?
        if let activeID, let node = layout.node(id: activeID) {
            frame = node.frame
        } else if let root {
            frame = node(atRootPoint: CGPoint(x: root.bounds.midX, y: root.bounds.midY))?.frame
        } else {
            frame = nil
        }
        guard let frame else { return }
        layout.camera = layout.camera.fitted(to: frame, viewport: scroll.bounds.size, padding: 0.9)
        applyCamera(updateCursors: true)
    }

    // MARK: - Window

    private func build() {
        // Mounting cards refreshes the overlays, which read the camera back
        // from the scroll view before this one is applied.
        let savedCamera = layout.camera
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let window = NSWindow(
            contentRect: screen.visibleFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Canvas Deck"
        window.isReleasedWhenClosed = false
        window.backgroundColor = CanvasPalette.background
        window.minSize = NSSize(width: 720, height: 480)
        window.delegate = self
        window.setFrame(screen.visibleFrame, display: false)
        window.tabbingMode = .disallowed
        // The canvas builds its own window (and step 3 restores the layout):
        // no macOS window restoration, and so no "reopen windows?" after a crash.
        window.isRestorable = false
        window.acceptsMouseMovedEvents = true

        let root = CanvasRootView(frame: window.contentView?.bounds ?? .zero)
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.backgroundColor = CanvasPalette.background.cgColor
        window.contentView = root
        root.onLayout = { [weak self] in self?.layoutOverlays() }

        let scroll = CanvasScrollView(frame: root.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.allowsMagnification = true
        scroll.minMagnification = Camera.minScale
        scroll.maxMagnification = Camera.maxScale
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.backgroundColor = .clear
        let clip = CanvasClipView()
        clip.drawsBackground = true
        clip.backgroundColor = CanvasPalette.background
        scroll.contentView = clip
        let document = CanvasDocumentView(frame: CGRect(x: 0, y: 0, width: 40_000, height: 40_000))
        document.wantsLayer = true
        document.clipsToBounds = false
        scroll.documentView = document
        root.addSubview(scroll)

        let minimap = MinimapView(frame: .zero)
        minimap.onCenter = { [weak self] center in
            guard let self else { return }
            self.layout.camera = Camera(center: center, scale: self.layout.camera.scale)
            self.applyCamera(updateCursors: false)
        }
        root.addSubview(minimap)

        let zoomPill = ZoomPillView(frame: .zero)
        zoomPill.onClick = { [weak self] pill in self?.showZoomMenu(from: pill) }
        zoomPill.onResize = { [weak self] in self?.layoutOverlays() }
        root.addSubview(zoomPill)
        self.zoomPill = zoomPill

        let noticeStack = NoticeStackView(frame: root.bounds)
        noticeStack.autoresizingMask = [.width, .height]
        noticeStack.onAction = { [weak self] id, action in self?.answerNotice(id, action) }
        noticeStack.onDismiss = { [weak self] id in self?.notices.dismiss(id) }
        noticeStack.onHold = { [weak self] id, holding in self?.notices.hold(id, holding) }
        root.addSubview(noticeStack)
        self.noticeStack = noticeStack
        notices.onChange = { [weak self] in self?.showNotices() }
        notices.onOpen = { [weak self] notice in self?.openNotice(notice) }
        LinearConnection.shared.sync.onNotifications = { [weak self] items in self?.postLinearNotifications(items) }
        notices.isInFront = { [weak self] in
            guard let window = self?.window else { return false }
            return NSApp.isActive && window.isKeyWindow && !window.isMiniaturized
        }
        // Settings → Notifications applies at once.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showNotices() }
        }

        let hint = PassThroughLabel(labelWithString: "Double- or right-click to open a card")
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .left
        root.addSubview(hint)

        scroll.onCameraChanged = { [weak self] in self?.refreshOverlays(updateCursors: false) }
        clip.onBoundsChange = { [weak self] in self?.refreshOverlays(updateCursors: false) }
        scroll.onUnhandledScroll = { [weak self] event in
            self?.pan(byScreen: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY))
        }

        self.window = window
        self.root = root
        self.scroll = scroll
        self.document = document
        self.minimap = minimap
        self.hint = hint

        notifyServer.onMessage = { [weak self] message in self?.handleNotify(message) }

        // Usage lives in the title bar, right side, so it never covers the canvas.
        let hud = NSHostingView(rootView: UsageHUDView(store: usage, context: usageContext))
        hud.setFrameSize(NSSize(width: hud.fittingSize.width, height: 28))
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = hud
        window.addTitlebarAccessoryViewController(accessory)
        usageHUD = hud
        // The text changes width with the figures; the accessory takes the view's width.
        usageHUDWatch = usage.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.resizeUsageHUD()
                self?.refreshAccountBadges()
            }
        }
        do { try notifyServer.start() } catch { NSLog("Canvas notify socket unavailable: \(error)") }
        cliWatch = ClaudeCLI.shared.$state.sink { [weak self] state in
            self?.usage.cliMissing = state == .missing
        }
        Task { [weak self] in
            await ClaudeCLI.shared.refresh()
            if ClaudeCLI.shared.path != nil, case .success(let status) = await ClaudeAccount.status() {
                self?.usage.setAccount(status)
            }
            self?.usageProbe.start()
        }
        accountObserver = NotificationCenter.default.addObserver(forName: ClaudeAccount.statusChanged, object: nil, queue: .main) { [weak self] note in
            let status = note.object as? ClaudeAccount.Status
            MainActor.assumeIsolated {
                self?.usage.setAccount(status)
                self?.usageProbe.refresh()
            }
        }

        for node in layout.nodes { mount(node) }
        root.layoutSubtreeIfNeeded()
        layout.camera = savedCamera
        applyCamera(updateCursors: true)
        installControls()
        // Development: `--open=terminal,claude,usage` puts those cards on the canvas at launch.
        if !didApplyLaunchSeed, let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--open=") }) {
            didApplyLaunchSeed = true
            let kinds = flag.dropFirst("--open=".count).split(separator: ",").compactMap { BuiltinKind.Kind(rawValue: String($0)) }
            let visible = scroll.contentView.bounds
            for (index, kind) in kinds.enumerated() {
                let point = CGPoint(x: visible.minX + 80 + CGFloat(index) * 780, y: visible.minY + 80)
                if kind == .claude {
                    ClaudeCLI.shared.whenInstalled { [weak self] in self?.addBuiltin(BuiltinKind(kind: kind), at: point) }
                } else {
                    addBuiltin(BuiltinKind(kind: kind), at: point)
                }
            }
            if flag.contains("usage") { showUsage(nil) }
            // `--zoom=<percent>` sets the zoom once the cards are placed.
            if let zoom = CommandLine.arguments.first(where: { $0.hasPrefix("--zoom=") }).flatMap({ Double($0.dropFirst("--zoom=".count)) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.zoom(toScale: CGFloat(zoom) / 100) }
            }
            // `--type=<line>` types a line into the first card's shell once it is up.
            if let line = CommandLine.arguments.first(where: { $0.hasPrefix("--type=") })?.dropFirst("--type=".count) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.terminals.values.first?.send(String(line) + "\r")
                }
            }
        }
    }

    private func layoutOverlays() {
        guard let root, let minimap, let hint else { return }
        let width: CGFloat = 188
        let height: CGFloat = 120
        minimap.frame = CGRect(x: root.bounds.width - width - 12, y: 12, width: width, height: height)
        var reserved = width + 40
        if let zoomPill {
            let size = zoomPill.intrinsicContentSize
            zoomPill.frame = CGRect(x: minimap.frame.minX - size.width - 8, y: 12, width: size.width, height: size.height)
            reserved += size.width + 8
        }
        hint.frame = CGRect(x: 16, y: 14, width: max(0, min(460, root.bounds.width - reserved)), height: 18)

        hint.isHidden = !layout.nodes.isEmpty
        refreshOverlays(updateCursors: false)
    }

    private func applyCamera(updateCursors: Bool) {
        scroll?.apply(layout.camera)
        refreshOverlays(updateCursors: updateCursors)
    }

    private func refreshOverlays(updateCursors: Bool) {
        guard let scroll, let minimap else { return }
        // The clip bounds and the node frames share one coordinate system,
        // the same one the zoom spike uses. The minimap reads that, not a
        // second copy that can drift.
        minimap.nodes = layout.nodes.map(\.frame)
        minimap.viewport = scroll.contentView.bounds
        // Whatever moved the clip, the camera follows it: a stale camera
        // re-applied later (a resize, a zoom) threw the view back.
        let camera = scroll.readCamera()
        if camera != layout.camera { layout.camera = camera }
        // A card scrolled out of sight lets go of the keyboard.
        if let activeID, let frame = layout.node(id: activeID)?.frame, !frame.intersects(scroll.contentView.bounds) {
            deactivate()
        }
        zoomPill?.scale = scroll.magnification
        noteBrowsersInView()
        document?.updateDots(scale: scroll.magnification)
        hint?.isHidden = !layout.nodes.isEmpty
        if updateCursors {
            for view in views.values {
                window?.invalidateCursorRects(for: view)
            }
        }
    }

    // MARK: - Nodes

    private func mount(_ node: Node) {
        guard let document else { return }
        let view: NodeContainerView
        switch node.state {
        case .terminal(let state):
            let terminal = TerminalNode(
                nodeID: node.id,
                workingDirectory: state.workingDirectory,
                launchScript: pendingLaunches.removeValue(forKey: node.id)
            )
            terminal.onEvent = { [weak self] event in self?.handleAgent(event, for: node.id, at: Date()) }
            terminal.onTitle = { [weak self] title in self?.setNodeTitle(node.id, title) }
            terminal.onDirectory = { [weak self] directory in self?.setTerminalDirectory(node.id, directory) }
            terminal.onLocalURL = { [weak self] url in self?.noteLocalURL(url, from: node.id) }
            terminals[node.id] = terminal
            Self.agentLog.notice("terminal node \(node.id.uuidString, privacy: .public) \(node.title, privacy: .public)")
            view = NodeContainerView(nodeID: node.id, title: node.title, content: terminal, frame: node.frame)
            terminal.start()
            setTerminalDirectory(node.id, terminal.workingDirectory)
        case .browser(let state):
            let browser = BrowserNode(nodeID: node.id, url: state.url)
            browser.onTitle = { [weak self] title in self?.setNodeTitle(node.id, title) }
            browser.onURL = { [weak self] url in
                self?.setBrowserURL(node.id, url)
                self?.updateLinearAccessory(node.id, url)
                self?.updateAppMode(node.id, url)
            }
            browser.onHistoryChange = { [weak self] in
                guard let self, let url = self.browsers[node.id]?.url else { return }
                self.updateAppMode(node.id, url)
            }
            browser.onIcon = { [weak self] image in self?.views[node.id]?.setIcon(image) }
            browser.onOpenNewWindow = { [weak self] url in self?.openBrowser(url, nextTo: node.id) }
            browsers[node.id] = browser
            browserLastSeen[node.id] = Date()
            view = NodeContainerView(nodeID: node.id, title: node.title, content: browser, frame: node.frame)
            startBrowserSweep()
        case .usage:
            var context = usageContext
            context.contentHeight = { [weak self] height in self?.fitUsageCard(node.id, contentHeight: height) }
            let content = NSHostingView(rootView: UsageCardView(store: usage, context: context))
            view = NodeContainerView(nodeID: node.id, title: node.title, content: content, frame: node.frame)
        default:
            view = NodeContainerView(
                nodeID: node.id,
                title: node.title,
                symbol: Self.symbol(for: node.kind),
                message: Self.message(for: node),
                frame: node.frame
            )
        }
        view.onActivate = { [weak self] in self?.activate(node.id) }
        view.onClose = { [weak self] in self?.close(node.id) }
        view.onFrameChange = { [weak self] frame in self?.updateFrame(id: node.id, frame: frame) }
        views[node.id] = view
        document.addSubview(view)
        view.setActive(node.id == activeID)
    }

    @discardableResult
    private func addNode(id: UUID = UUID(), title: String, kind: NodeKind, state: NodeState, at point: CGPoint) -> UUID {
        // The card goes exactly where the user asked, over others if need be;
        // activation below brings it to the front.
        let frame = CGRect(origin: point, size: Node.defaultSize(for: kind))
        let node = Node(id: id, title: title, frame: frame, kind: kind, state: state)
        layout.nodes.append(node)
        mount(node)
        ensureDocumentContains(frame)
        activate(node.id)
        refreshOverlays(updateCursors: true)
        return node.id
    }

    private func activate(_ id: UUID) {
        activeID = id
        guard let document, let view = views[id] else { return }
        for (other, otherView) in views { otherView.setActive(other == id) }
        bringToFront(view, in: document)
        if let index = layout.nodes.firstIndex(where: { $0.id == id }) {
            let node = layout.nodes.remove(at: index)
            layout.nodes.append(node)
        }
        window?.makeFirstResponder(view.preferredFirstResponder)
        if let terminal = terminals[id] { lastActiveTerminalDirectory = terminal.workingDirectory }
    }

    private func setNodeTitle(_ id: UUID, _ title: String) {
        guard let index = layout.nodes.firstIndex(where: { $0.id == id }) else { return }
        layout.nodes[index].title = title
        views[id]?.setTitle(title)
    }

    private func setTerminalDirectory(_ id: UUID, _ directory: String) {
        guard let index = layout.nodes.firstIndex(where: { $0.id == id }) else { return }
        let sessionID: String? = if case .terminal(let state) = layout.nodes[index].state { state.claudeSessionID } else { nil }
        layout.nodes[index].state = .terminal(TerminalState(workingDirectory: directory, claudeSessionID: sessionID))
        if id == activeID { lastActiveTerminalDirectory = directory }
    }

    /// Re-adding the view would detach it from the window mid-click, and AppKit
    /// then drops the mouseDragged events that belong to that click.
    private func bringToFront(_ view: NSView, in document: NSView) {
        guard document.subviews.last !== view else { return }
        var ranks: [ObjectIdentifier: Int] = [:]
        for (index, subview) in document.subviews.enumerated() { ranks[ObjectIdentifier(subview)] = index }
        ranks[ObjectIdentifier(view)] = Int.max
        let box = SubviewRanks(ranks)
        withExtendedLifetime(box) {
            document.sortSubviews({ a, b, context in
                let ranks = Unmanaged<SubviewRanks>.fromOpaque(context!).takeUnretainedValue().ranks
                let ra = ranks[ObjectIdentifier(a)] ?? 0
                let rb = ranks[ObjectIdentifier(b)] ?? 0
                return ra < rb ? .orderedAscending : (ra > rb ? .orderedDescending : .orderedSame)
            }, context: Unmanaged.passUnretained(box).toOpaque())
        }
    }

    private func deactivate() {
        activeID = nil
        for view in views.values { view.setActive(false) }
        if let document { window?.makeFirstResponder(document) }
    }

    private func close(_ id: UUID) {
        if let terminal = terminals[id], !terminal.exited, Settings.confirmCloseRunningCard, let window {
            let alert = NSAlert()
            alert.messageText = "Close “\(layout.node(id: id)?.title ?? "Terminal")”?"
            alert.informativeText = "The shell and everything running in it will be stopped. You can turn off this question in Settings → General."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.closeNow(id)
            }
            return
        }
        closeNow(id)
    }

    private func closeNow(_ id: UUID) {
        terminals[id]?.terminate()
        terminals[id] = nil
        browsers[id] = nil
        browserLastSeen[id] = nil
        previewURLs[id] = nil
        previewBrowsers = previewBrowsers.filter { $0.key != id && $0.value != id }
        statuses[id] = nil
        notices.resolve(source: id)
        sessionStore.update { $0.closeAll(node: id, at: Date()) }
        usage.forget(node: id)
        views[id]?.removeFromSuperview()
        views[id] = nil
        layout.nodes.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
        refreshOverlays(updateCursors: false)
    }

    private func updateFrame(id: UUID, frame: CGRect) {
        guard let index = layout.nodes.firstIndex(where: { $0.id == id }) else { return }
        layout.nodes[index].frame = frame
        ensureDocumentContains(frame)
        minimap?.nodes = layout.nodes.map(\.frame)
    }

    private func ensureDocumentContains(_ rect: CGRect) {
        guard let document else { return }
        let needed = document.frame.union(rect.insetBy(dx: -2000, dy: -2000))
        guard needed != document.frame else { return }
        // Origin stays at 0 so a node's frame is the canvas point, matching
        // the clip view. The zoom spike relies on the same identity.
        let grown = CGRect(x: 0, y: 0, width: max(needed.maxX, document.frame.width), height: max(needed.maxY, document.frame.height))
        document.frame = grown
        document.bounds = CGRect(origin: .zero, size: grown.size)
    }

    private func showPicker(at windowPoint: NSPoint) {
        guard let window, let scroll else { return }
        pendingPoint = scroll.contentView.convert(windowPoint, from: nil)
        let point = pendingPoint
        let picker = AppPickerPanel(builtins: BuiltinKind.all)
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        picker.model.onPickBuiltin = { [weak self, weak picker] item in
            picker?.model.onCancel = nil
            picker?.orderOut(nil)
            if item.kind == .claude {
                ClaudeCLI.shared.whenInstalled { [weak self] in
                    if Settings.claudeAsksForFolder {
                        self?.showFolderPicker(at: point, screenPoint: screenPoint)
                    } else {
                        self?.addBuiltin(item, at: point)
                    }
                }
            } else {
                self?.addBuiltin(item, at: point)
            }
        }
        picker.model.onCancel = { [weak picker] in picker?.orderOut(nil) }
        picker.present(atCocoaPoint: screenPoint)
        self.picker = picker
    }

    private func addBuiltin(_ item: BuiltinKind, at point: CGPoint) {
        switch item.kind {
        case .browser:
            addNode(title: item.title, kind: .browser, state: .browser(BrowserState()), at: point)
        case .terminal:
            let directory = Settings.newTerminalDirectory(lastActive: lastActiveTerminalDirectory)
            addNode(title: item.title, kind: .terminal, state: .terminal(TerminalState(workingDirectory: directory)), at: point)
        case .claude:
            addClaude(in: Settings.newTerminalDirectory(lastActive: lastActiveTerminalDirectory), at: point)
        case .linear:
            openLinear(at: point)
        }
    }

    /// A Claude Code card; with an issue, the session is named after it and
    /// starts on `prompt`.
    @discardableResult
    private func addClaude(in directory: String, at point: CGPoint, issueID: String? = nil, prompt: String? = nil) -> UUID {
        let node = UUID()
        let session = UUID().uuidString.lowercased()
        pendingLaunches[node] = ClaudeLaunch.shellScript(
            shell: TerminalNode.shell,
            start: .new(sessionID: UUID(uuidString: session)!),
            name: issueID,
            notifyPath: TerminalNode.notifyPath,
            prompt: prompt
        )
        Settings.noteClaudeFolder(directory)
        sessionStore.update { $0.attach(id: session, node: node, cwd: directory, name: issueID, issueID: issueID, at: Date()) }
        addNode(id: node, title: issueID ?? "Claude Code", kind: .terminal, state: .terminal(TerminalState(workingDirectory: directory, claudeSessionID: session)), at: point)
        return node
    }

    /// Reopens a closed session in a new card at the centre of the view.
    func resume(_ session: ClaudeSession) {
        if let open = sessionStore.index.session(id: session.id), open.isOpen, let node = open.nodeID {
            focus(node)
            return
        }
        guard ClaudeCLI.shared.path != nil else {
            ClaudeCLI.shared.whenInstalled { [weak self] in self?.resume(session) }
            return
        }
        let node = UUID()
        pendingLaunches[node] = ClaudeLaunch.shellScript(
            shell: TerminalNode.shell,
            start: .resume(sessionID: session.id),
            name: session.name,
            notifyPath: TerminalNode.notifyPath,
            // The account whose folder holds the transcript; a wrapper that
            // picks the account by folder (as for the author) wins anyway.
            configDirectory: ClaudeConfig.account(ofSession: session.id, cwd: session.cwd)
        )
        sessionStore.update { $0.attach(id: session.id, node: node, cwd: session.cwd, at: Date()) }
        addNode(id: node, title: session.title, kind: .terminal, state: .terminal(TerminalState(workingDirectory: session.cwd, claudeSessionID: session.id)), at: centerPoint(for: .terminal))
    }

    /// Claude Code's own session picker in a chosen folder, for sessions the canvas did not start.
    @objc func resumeOtherSession(_ sender: Any?) {
        guard let window else { return }
        guard ClaudeCLI.shared.path != nil else {
            ClaudeCLI.shared.whenInstalled { [weak self] in self?.resumeOtherSession(sender) }
            return
        }
        let point = centerPoint(for: .terminal)
        let screen = NSPoint(x: window.frame.midX - 220, y: window.frame.midY + 230)
        showFolderPicker(at: point, screenPoint: screen) { [weak self] path in
            guard let self else { return }
            let node = UUID()
            self.pendingLaunches[node] = ClaudeLaunch.pickerScript(shell: TerminalNode.shell, notifyPath: TerminalNode.notifyPath)
            self.addNode(id: node, title: "Claude Code", kind: .terminal, state: .terminal(TerminalState(workingDirectory: path)), at: point)
        }
    }

    /// Top-left for a card of `kind` centred in the visible canvas.
    private func centerPoint(for kind: NodeKind) -> CGPoint {
        let visible = scroll?.contentView.bounds ?? .zero
        let size = Node.defaultSize(for: kind)
        return CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
    }

    /// Second step of Open… → Claude Code: which folder to start in.
    private func showFolderPicker(at point: CGPoint, screenPoint: NSPoint, launch: ((String) -> Void)? = nil) {
        let launch = launch ?? { [weak self] path in self?.addClaude(in: path, at: point) }
        let canvasFolders = layout.nodes.compactMap { node -> String? in
            if case .terminal(let state) = node.state { return state.workingDirectory }
            return nil
        }
        let panel = FolderPickerPanel(choices: FolderSources.gather(canvasFolders: canvasFolders))
        panel.model.onPick = { [weak panel] path in
            panel?.model.onCancel = nil
            panel?.orderOut(nil)
            launch(path)
        }
        panel.model.onChooseOther = { [weak self, weak panel] in
            panel?.model.onCancel = nil
            panel?.orderOut(nil)
            self?.chooseClaudeFolder(launch: launch)
        }
        panel.model.onCancel = { [weak panel] in panel?.orderOut(nil) }
        panel.present(atCocoaPoint: screenPoint)
        folderPicker = panel
    }

    private func chooseClaudeFolder(launch: @escaping (String) -> Void) {
        guard let window else { return }
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.prompt = "Open Claude Code"
        open.directoryURL = URL(filePath: Settings.recentClaudeFolders.first ?? Settings.resolvedTerminalHome, directoryHint: .isDirectory)
        open.beginSheetModal(for: window) { response in
            guard response == .OK, let url = open.url else { return }
            launch(url.path)
        }
    }

    // MARK: - Sessions and usage

    /// The Usage card is as tall as what it shows: no scrolling inside a card.
    private func fitUsageCard(_ id: UUID, contentHeight: CGFloat) {
        guard let view = views[id], contentHeight > 0 else { return }
        let height = ceil(contentHeight) + NodeContainerView.titleHeight
        guard abs(view.frame.height - height) > 0.5 else { return }
        var frame = view.frame
        frame.size.height = height
        view.frame = frame
        updateFrame(id: id, frame: frame)
    }

    /// "work" on each Claude Code card, as its session reported, once the
    /// canvas knows more than one account. Never a guess: no report, no badge.
    private func refreshAccountBadges() {
        let many = usage.knownAccountCount > 1
        for id in terminals.keys {
            let account = usage.account(of: id)
            views[id]?.setBadge(many ? account.map { usage.name(of: $0) } : nil, help: account.map { "Claude Code account: \(usage.detail(of: $0))" })
        }
    }

    private func resizeUsageHUD() {
        guard let usageHUD else { return }
        let width = ceil(usageHUD.fittingSize.width)
        if abs(usageHUD.frame.width - width) > 0.5 { usageHUD.setFrameSize(NSSize(width: width, height: usageHUD.frame.height)) }
    }

    private var usageContext: UsageContext {
        UsageContext(
            openNodes: { [weak self] in Set(self?.terminals.keys.map { $0 } ?? []) },
            title: { [weak self] id in self?.sessionStore.index.session(id: id)?.title ?? "Claude Code" },
            openCard: { [weak self] in self?.showUsage(nil) },
            focusNode: { [weak self] node in self?.focus(node) }
        )
    }

    private func handleNotify(_ message: NotifyMessage) {
        // Status lines come from canvas cards and, with the global status line
        // on, from Claude Code anywhere: limits count either way.
        if let statusline = message.statusline {
            let node = message.nodeID.flatMap { terminals[$0] != nil ? $0 : nil }
            usage.ingest(statusline, node: node, account: message.configDir, at: message.sentAt)
            if node != nil, let id = statusline.sessionID { sessionStore.update { $0.touch(id: id, at: message.sentAt) } }
            return
        }
        guard let node = message.nodeID, terminals[node] != nil else {
            Self.agentLog.notice("message for unknown node \(message.nodeID?.uuidString ?? "-", privacy: .public): \(message.hook, privacy: .public)")
            return
        }
        if let account = message.configDir {
            usage.note(account: account, node: node)
        }
        if let id = message.sessionID {
            let cwd = message.cwd ?? terminals[node]?.workingDirectory ?? NSHomeDirectory()
            switch message.hook {
            case "SessionStart":
                sessionStore.update { $0.attach(id: id, node: node, cwd: cwd, at: message.sentAt) }
                setTerminalSession(node, id)
            case "SessionEnd":
                sessionStore.update { $0.close(id: id, at: message.sentAt) }
                setTerminalSession(node, nil)
            case "UserPromptSubmit":
                if sessionStore.index.session(id: id) == nil {
                    sessionStore.update { $0.attach(id: id, node: node, cwd: cwd, at: message.sentAt) }
                }
                if let prompt = message.prompt, !prompt.isEmpty {
                    sessionStore.update { $0.notePrompt(prompt, id: id, at: message.sentAt) }
                    retitle(node)
                }
            default:
                sessionStore.update { $0.touch(id: id, at: message.sentAt) }
            }
        }
        if let event = message.event { handleAgent(event, for: node, at: message.sentAt) }
    }

    private func setTerminalSession(_ node: UUID, _ id: String?) {
        guard let index = layout.nodes.firstIndex(where: { $0.id == node }),
              case .terminal(var state) = layout.nodes[index].state else { return }
        state.claudeSessionID = id
        layout.nodes[index].state = .terminal(state)
        if id != nil { retitle(node) }
    }

    /// A Claude Code card takes its session's title, e.g. the first prompt.
    private func retitle(_ node: UUID) {
        guard let session = sessionStore.index.openSession(node: node) else { return }
        guard session.firstPrompt != nil || session.name != nil || session.issueID != nil else { return }
        setNodeTitle(node, session.title)
    }

    /// Brings a card into view and gives it focus.
    func focus(_ node: UUID) {
        guard let scroll, let frame = layout.node(id: node)?.frame else { return }
        layout.camera = layout.camera.fitted(to: frame, viewport: scroll.bounds.size, padding: 0.9)
        applyCamera(updateCursors: true)
        activate(node)
    }

    @objc func showUsage(_ sender: Any?) {
        usageProbe.refreshIfStale()
        if let existing = layout.nodes.first(where: { $0.kind == .usage }) {
            focus(existing.id)
            return
        }
        addNode(title: "Usage", kind: .usage, state: .usage(UsageState()), at: centerPoint(for: .usage))
    }

    // MARK: Sessions menu

    /// Rebuilt every time the Sessions menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let index = sessionStore.index
        let open = index.open.filter { $0.nodeID.map { terminals[$0] != nil } ?? false }
        menu.addItem(NSMenuItem.sectionHeader(title: "Open"))
        if open.isEmpty {
            menu.addItem(disabledItem("No Claude Code sessions on the canvas"))
        }
        for session in open {
            let item = NSMenuItem(title: session.title, action: #selector(sessionMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session.id
            let status = session.nodeID.flatMap { statuses[$0]?.label }
            item.subtitle = [Self.shortPath(session.cwd), status].compactMap { $0 }.joined(separator: " · ")
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Recent"))
        let recent = index.recent.prefix(15)
        if recent.isEmpty {
            menu.addItem(disabledItem("Closed sessions appear here"))
        }
        for session in recent {
            let item = NSMenuItem(title: session.title, action: #selector(sessionMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session.id
            let summary = sessionStore.summary(for: session)
            let when = session.lastActiveAt.formatted(.relative(presentation: .named))
            let cost = summary.flatMap { $0.turns > 0 ? StatuslineText.usd($0.costUSD) : nil }
            item.subtitle = [Self.shortPath(session.cwd), when, cost].compactMap { $0 }.joined(separator: " · ")
            item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: "Resume Other Session…", action: #selector(resumeOtherSession(_:)), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        let usageItem = NSMenuItem(title: "Usage", action: #selector(showUsage(_:)), keyEquivalent: "u")
        usageItem.keyEquivalentModifierMask = [.command, .shift]
        usageItem.target = self
        menu.addItem(usageItem)
    }

    @objc private func sessionMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let session = sessionStore.index.session(id: id) else { return }
        if session.isOpen, let node = session.nodeID, terminals[node] != nil {
            focus(node)
        } else {
            resume(session)
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func shortPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Agent state

    private func handleAgent(_ event: AgentEvent, for id: UUID, at date: Date) {
        guard let view = views[id], terminals[id] != nil else {
            Self.agentLog.notice("event for unknown node \(id.uuidString, privacy: .public): \(String(describing: event), privacy: .public)")
            return
        }
        let old = statuses[id] ?? .initial
        let new = old.applying(event, at: date)
        guard new != old else { return }
        statuses[id] = new
        Self.agentLog.notice("node \(id.uuidString, privacy: .public): \(String(describing: event), privacy: .public) → \(new.state.rawValue, privacy: .public) \(new.label ?? "", privacy: .public)")
        if new.label != old.label || new.state != old.state || new.reason != old.reason {
            view.setStatus(new.label, color: Self.color(for: new))
        }
        switch Notice.change(from: old, to: new, node: id, title: layout.node(id: id)?.title ?? "Terminal", at: date) {
        case .post(let notice): notices.post(notice)
        case .resolve(let node): notices.resolve(source: node)
        case .none: break
        }
    }

    private static let agentLog = Logger(subsystem: "app.canvasdeck", category: "agent")

    private static func color(for status: AgentStatus) -> NSColor? {
        switch status.state {
        case .idle: nil
        case .working: .systemBlue
        case .waiting:
            switch status.reason {
            case .permission: .systemOrange
            case .question: .systemYellow
            case .input, nil: .systemGray
            }
        case .done: .systemGreen
        case .error: .systemRed
        }
    }

    private static func symbol(for kind: NodeKind) -> String {
        switch kind {
        case .browser: "globe"
        case .terminal: "terminal"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .files: "folder"
        case .media: "photo"
        case .external: "macwindow"
        case .usage: "gauge.with.dots.needle.33percent"
        case .board: "checklist"
        }
    }

    private static func message(for node: Node) -> String {
        switch node.kind {
        case .browser: "Loading…"
        case .terminal: "Starting the terminal…"
        case .code, .files, .media: "This card type is no longer supported. It was kept from an older layout."
        case .external: "Cards of installed apps are not supported any more."
        case .usage, .board: ""
        }
    }

    // MARK: - Gestures

    private func installControls() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.magnify, .scrollWheel, .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .keyDown, .keyUp]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return event }
                return self.handle(event)
            }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // A gesture stops a flight; the second click of a double click does not.
        if cameraAnimation != nil, [.magnify, .scrollWheel, .rightMouseDown].contains(event.type) || (event.type == .leftMouseDown && event.clickCount == 1) {
            stopCameraAnimation()
        }
        switch event.type {
        case .magnify:
            zoom(by: 1 + event.magnification, atWindowPoint: event.locationInWindow)
            return nil

        case .scrollWheel:
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                let step: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
                zoom(by: CGFloat(exp(Double(event.scrollingDeltaY) * step)), atWindowPoint: event.locationInWindow)
                return nil
            }
            // One gesture, one target, momentum included: a pan that began on
            // the canvas stays a pan when a card slides under the cursor. A
            // mouse wheel has no phases: each click decides for itself.
            let wheel = event.phase.isEmpty && event.momentumPhase.isEmpty
            if wheel || event.phase.contains(.began) || scrollGoesToCard == nil {
                if let node = node(at: event), node.nodeID == activeID, eventHitsNodeContent(event, node: node) {
                    scrollGoesToCard = true
                } else {
                    scrollGoesToCard = false
                }
            }
            let toCard = scrollGoesToCard ?? false
            if wheel || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                scrollGoesToCard = nil
            }
            if toCard { return event }
            pan(byScreen: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY))
            return nil

        case .mouseMoved:
            updateCursor(for: event)
            return event

        case .leftMouseDown:
            if spaceHeld {
                dragAnchor = event.locationInWindow
                NSCursor.closedHand.set()
                return nil
            }
            if let node = node(at: event) {
                // Content like a terminal takes the click itself, so the card's
                // own mouseDown never runs: activate here.
                if node.nodeID != activeID { activate(node.nodeID) }
                return event
            }
            if isMinimap(event) { return event }
            deactivate()
            if event.clickCount == 2 {
                showPicker(at: event.locationInWindow)
                return nil
            }
            return event

        case .leftMouseDragged:
            guard let dragAnchor else { return event }
            let point = event.locationInWindow
            pan(byScreen: CGPoint(x: point.x - dragAnchor.x, y: -(point.y - dragAnchor.y)))
            self.dragAnchor = point
            return nil

        case .leftMouseUp:
            guard dragAnchor != nil else { return event }
            dragAnchor = nil
            (spaceHeld ? NSCursor.openHand : NSCursor.arrow).set()
            return nil

        case .rightMouseDown:
            if let node = node(at: event) {
                if node.nodeID != activeID { activate(node.nodeID) }
                return event
            }
            if isMinimap(event) { return event }
            showPicker(at: event.locationInWindow)
            return nil

        case .keyDown:
            return handleKeyDown(event)

        case .keyUp:
            guard event.keyCode == 49, spaceHeld else { return event }
            spaceHeld = false
            if dragAnchor == nil { NSCursor.arrow.set() }
            return nil

        default:
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // An active card owns every key, Esc included (Claude Code and vim
        // need it). ⌘⎋ or a click on empty canvas hands focus back.
        if activeID != nil {
            if event.keyCode == 53, flags == .command {
                deactivate()
                return nil
            }
            return event
        }
        let key = event.charactersIgnoringModifiers ?? ""
        // ⇧0 / ⇧1 / ⇧2 and ⌘+ / ⌘− live on the View menu, so they run once.
        // ⌘0 and ⌘1 are aliases for fit and 100% while nothing is active.
        if flags == .command {
            switch key {
            case "0": fitAll(nil); return nil
            case "1": actualSize(nil); return nil
            default: break
            }
        }
        if event.keyCode == 49 {
            if !spaceHeld { NSCursor.openHand.set() }
            spaceHeld = true
            return nil
        }
        return event
    }

    /// Keeps the canvas point under the cursor fixed. This is the magnification
    /// path from NativeZoomSpike: the anchor and the clip origin are both in
    /// document coordinates, which only works while the document origin is zero.
    private func zoom(by factor: CGFloat, atWindowPoint point: NSPoint) {
        guard let scroll, let document, factor.isFinite, factor > 0 else { return }
        let old = scroll.magnification
        let new = Camera.snappedScale(from: old, raw: Camera.clamp(old * factor))
        guard new > 0 else { return }
        let anchor = document.convert(point, from: nil)
        let origin = scroll.contentView.bounds.origin
        let offset = CGPoint(x: (anchor.x - origin.x) * old, y: (anchor.y - origin.y) * old)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        scroll.magnification = new
        scroll.contentView.setBoundsOrigin(CGPoint(x: anchor.x - offset.x / new, y: anchor.y - offset.y / new))
        scroll.reflectScrolledClipView(scroll.contentView)
        NSAnimationContext.endGrouping()
        layout.camera = scroll.readCamera()
        refreshOverlays(updateCursors: true)
    }

    /// Screen-point pan, y pointing down, copied from the zoom spike.
    private func pan(byScreen delta: CGPoint) {
        guard let scroll else { return }
        let scale = max(scroll.magnification, Camera.minScale)
        var origin = scroll.contentView.bounds.origin
        origin.x -= delta.x / scale
        origin.y -= delta.y / scale
        scroll.contentView.setBoundsOrigin(origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        layout.camera = scroll.readCamera()
        refreshOverlays(updateCursors: false)
    }

    /// Content views such as a web page get the event after this and may set
    /// their own cursor on top.
    private func updateCursor(for event: NSEvent) {
        guard !spaceHeld, dragAnchor == nil else { return }
        guard let node = node(at: event) else {
            NSCursor.arrow.set()
            return
        }
        node.cursor(at: node.convert(event.locationInWindow, from: nil)).set()
    }

    private func node(at event: NSEvent) -> NodeContainerView? {
        guard let root else { return nil }
        return node(atRootPoint: root.convert(event.locationInWindow, from: nil))
    }

    private func node(atRootPoint point: NSPoint) -> NodeContainerView? {
        var view = root?.hitTest(point)
        while let current = view {
            if let node = current as? NodeContainerView { return node }
            view = current.superview
        }
        return nil
    }

    private func isMinimap(_ event: NSEvent) -> Bool {
        guard let root else { return false }
        var view = root.hitTest(root.convert(event.locationInWindow, from: nil))
        while let current = view {
            if current is MinimapView { return true }
            view = current.superview
        }
        return false
    }

    private func eventHitsNodeContent(_ event: NSEvent, node: NodeContainerView) -> Bool {
        let local = node.convert(event.locationInWindow, from: nil)
        guard local.y >= 36 else { return false }
        guard let root else { return false }
        guard let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)) else { return false }
        return hit !== node && hit.isDescendant(of: node)
    }
}
