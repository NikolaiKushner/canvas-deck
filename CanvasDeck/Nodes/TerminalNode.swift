import AppKit
import CanvasCore
import SwiftTerm

/// A shell in a card: `$SHELL -l` in the node's folder, title from OSC 0/2,
/// folder from OSC 7. Bells, OSC 777 / OSC 9 notifications and keystrokes go
/// out as agent events; Claude Code hooks arrive separately via `NotifyServer`.
final class TerminalNode: NSView, NodeContentView {
    let nodeID: UUID
    private(set) var workingDirectory: String
    var onTitle: ((String) -> Void)?
    var onDirectory: ((String) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var onEvent: ((AgentEvent) -> Void)?
    var onLocalURL: ((URL) -> Void)? {
        get { terminal.onLocalURL }
        set { terminal.onLocalURL = newValue }
    }

    let terminal: CanvasTerminalView
    /// Run once instead of an interactive shell, e.g. Claude Code. A restart
    /// after it exits opens a plain shell.
    private var launchScript: String?
    private let exitLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var exited = false

    static let fontSize: CGFloat = 12
    /// SwiftTerm renders through CoreGraphics unless asked for Metal. `--cg`
    /// keeps CoreGraphics for A/B measurements.
    static let prefersMetal = !CommandLine.arguments.contains("--cg")
    /// Colours of the app's current light or dark appearance.
    static var background: NSColor { TerminalPalette.current(for: NSApp.effectiveAppearance).background }
    static var foreground: NSColor { TerminalPalette.current(for: NSApp.effectiveAppearance).foreground }

    /// Copied next to the app binary by the `canvas-notify` target.
    static var notifyPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/canvas-notify").path
    }

    static var shell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    init(nodeID: UUID, workingDirectory: String, launchScript: String? = nil) {
        self.nodeID = nodeID
        self.workingDirectory = workingDirectory
        self.launchScript = launchScript
        terminal = CanvasTerminalView(frame: .zero)
        super.init(frame: .zero)
        wantsLayer = true
        terminal.font = NSFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)
        terminal.processDelegate = self
        terminal.onBell = { [weak self] in self?.onEvent?(.bell) }
        terminal.onNotice = { [weak self] notice in self?.onEvent?(.terminalNotification(title: notice.title, body: notice.body)) }
        terminal.onInput = { [weak self] in self?.onEvent?(.userInput) }
        if Self.prefersMetal {
            do { try terminal.setUseMetal(true) } catch { NSLog("SwiftTerm Metal unavailable: \(error)") }
        }
        addSubview(terminal)

        exitLabel.font = .systemFont(ofSize: 13)
        exitLabel.alignment = .center
        exitLabel.isHidden = true
        addSubview(exitLabel)
        applyTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        let palette = TerminalPalette.current(for: effectiveAppearance)
        layer?.backgroundColor = palette.background.cgColor
        palette.apply(to: terminal)
        exitLabel.textColor = palette.foreground
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    var preferredFirstResponder: NSView? { terminal }
    var rendererName: String { terminal.isUsingMetalRenderer ? "metal" : "coregraphics" }

    // MARK: - Process

    func start() {
        let shell = Self.shell
        let directory = Settings.isDirectory(workingDirectory) ? workingDirectory : NSHomeDirectory()
        workingDirectory = directory
        exited = false
        exitLabel.isHidden = true
        let launch = ShellIntegration.launch(shell: shell, script: launchScript)
        launchScript = nil
        terminal.startProcess(
            executable: shell,
            args: launch.args,
            environment: environment(shell: shell),
            execName: launch.execName,
            currentDirectory: directory
        )
    }

    func terminate() {
        guard !exited else { return }
        terminal.terminate()
    }

    func send(_ text: String) {
        terminal.send(txt: text)
    }

    /// The parent environment plus what a terminal emulator sets, plus the
    /// variables the canvas tools read.
    private func environment(shell: String) -> [String] {
        var env = ShellIntegration.environment(shell: shell, base: ProcessInfo.processInfo.environment)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "CanvasDeck"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["CANVAS_NODE_ID"] = nodeID.uuidString
        env["CANVAS_NOTIFY"] = Self.notifyPath
        env["CANVAS_NOTIFY_SOCKET"] = NotifyServer.defaultPath
        return env.map { "\($0.key)=\($0.value)" }
    }

    // MARK: - Layout & keys

    override func layout() {
        super.layout()
        terminal.frame = bounds
        exitLabel.frame = CGRect(x: 16, y: bounds.midY - 20, width: max(0, bounds.width - 32), height: 40)
    }

    /// Every key belongs to the shell while it has focus, including ones that
    /// match a bare menu shortcut like ⇧1 («!»). ⌘-combinations still reach
    /// the menu. After the shell exits, ⏎ opens a new one.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === terminal else { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command) { return super.performKeyEquivalent(with: event) }
        if exited {
            if event.keyCode == 36 { start() }
            return true
        }
        terminal.keyDown(with: event)
        return true
    }
}

extension TerminalNode: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated {
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            onTitle?(trimmed)
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated {
            guard let directory else { return }
            // OSC 7 carries a file URL: file://host/path.
            let path = URL(string: directory)?.path ?? directory
            guard Settings.isDirectory(path) else { return }
            workingDirectory = path
            onDirectory?(path)
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            exited = true
            let code = exitCode.map { String($0) } ?? "—"
            exitLabel.stringValue = "Process exited (code \(code)). Press ⏎ to start a new shell."
            exitLabel.isHidden = false
            onExit?(exitCode)
        }
    }
}

/// SwiftTerm's view with the three hooks the card needs. `bell`, `send` and
/// `dataReceived` are open; OSC 777 is not (a protocol-extension default), so
/// incoming bytes go through `OSCNotificationSniffer` as well.
final class CanvasTerminalView: LocalProcessTerminalView {
    var onBell: (() -> Void)?
    var onNotice: ((TerminalNotice) -> Void)?
    var onInput: (() -> Void)?
    /// A local dev server's address appeared in the output.
    var onLocalURL: ((URL) -> Void)?
    private var sniffer = OSCNotificationSniffer()
    private var urls = LocalURLDetector()

    override func bell(source: Terminal) {
        super.bell(source: source)
        onBell?()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        onInput?()
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        for notice in sniffer.feed(slice) { onNotice?(notice) }
        if let url = urls.feed(slice) { onLocalURL?(url) }
    }
}

/// Terminal colours per theme: background, text, caret and the 16 ANSI
/// colours. Both palettes are GitHub's; in the light one "white" is a grey,
/// or white text would vanish on the white background.
struct TerminalPalette {
    let background: NSColor
    let foreground: NSColor
    let ansi: [UInt32]

    /// The app's appearance decides: the terminal is part of its card.
    static func current(for appearance: NSAppearance) -> TerminalPalette {
        CanvasPalette.isDark(appearance) ? dark : light
    }

    static let light = TerminalPalette(
        background: NSColor(hex: 0xFFFFFF),
        foreground: NSColor(hex: 0x1F2328),
        ansi: [
            0x24292F, 0xCF222E, 0x116329, 0x9A6700, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
            0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F,
        ]
    )

    static let dark = TerminalPalette(
        // The dark card colour, so the terminal fills its card without a seam.
        background: NSColor(hex: 0x1B1E26),
        foreground: NSColor(hex: 0xE0E3E8),
        ansi: [
            0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
            0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xFFFFFF,
        ]
    )

    func apply(to terminal: TerminalView) {
        terminal.installColors(ansi.map { hex in
            func channel(_ shift: UInt32) -> UInt16 { UInt16((hex >> shift) & 0xFF) * 257 }
            return SwiftTerm.Color(red: channel(16), green: channel(8), blue: channel(0))
        })
        terminal.nativeBackgroundColor = background
        terminal.nativeForegroundColor = foreground
        terminal.caretColor = foreground
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
