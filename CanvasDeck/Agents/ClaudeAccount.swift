import AppKit
import SwiftTerm

/// The Claude Code account, through the CLI only: `claude auth status | login |
/// logout`. The canvas never sees or stores a token — Claude Code keeps it in
/// the macOS keychain itself.
enum ClaudeAccount {
    struct Status: Decodable, Equatable {
        let loggedIn: Bool
        let authMethod: String?
        let email: String?
        let orgName: String?
        let subscriptionType: String?
        let configDirectory: String?
        /// "firstParty", or a cloud provider such as Bedrock or Vertex.
        let apiProvider: String?

        /// Whether Claude Code reports 5-hour and weekly limits for this
        /// account: Claude subscriptions do (Pro, Max, Team — seen with a Team
        /// seat 2026-09-30); API keys and cloud providers do not. Nil when the
        /// status does not say enough to tell, e.g. Enterprise.
        var reportsRateLimits: Bool? {
            guard loggedIn else { return nil }
            if let apiProvider, apiProvider != "firstParty" { return false }
            guard let authMethod else { return nil }
            guard authMethod == "claude.ai" else { return false }
            guard let plan = subscriptionType?.lowercased(), !plan.isEmpty else { return nil }
            if ["pro", "max", "team"].contains(plan) { return true }
            return nil
        }

        var planName: String? {
            guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
            return subscriptionType.prefix(1).uppercased() + subscriptionType.dropFirst()
        }
    }

    /// Posted with the new `Status` as the object after Settings reads it
    /// again (sign-in, sign-out, retry).
    static let statusChanged = Notification.Name("CanvasDeckClaudeAccountStatusChanged")

    enum Failure: Error, Equatable {
        case cliNotFound
        case failed(String)
    }

    /// Where `claude` lives. GUI apps do not get the user's shell PATH, so the
    /// usual install locations are tried first, then the login shell is asked.
    static func cliPath() async -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let shell = TerminalNode.shell
        guard let output = try? await run(shell, ["-l", "-i", "-c", "command -v claude"], timeout: 10) else { return nil }
        let path = output.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The account of `configDirectory` (`CLAUDE_CONFIG_DIR`), or of the
    /// default folder when nil.
    static func status(configDirectory: String? = nil) async -> Result<Status, Failure> {
        guard let cli = await cliPath() else { return .failure(.cliNotFound) }
        var environment = ProcessInfo.processInfo.environment
        if let configDirectory { environment = ClaudeConfig.environment(for: configDirectory, base: environment) }
        do {
            let output = try await run(cli, ["auth", "status", "--json"], timeout: 15, environment: environment)
            guard let data = output.data(using: .utf8) else { return .failure(.failed("Empty response")) }
            return .success(try JSONDecoder().decode(Status.self, from: data))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.failed("Could not read the account status"))
        }
    }

    static func logout() async -> Failure? {
        guard let cli = await cliPath() else { return .cliNotFound }
        do {
            _ = try await run(cli, ["auth", "logout"], timeout: 15)
            return nil
        } catch let failure as Failure {
            return failure
        } catch {
            return .failed("Sign out failed")
        }
    }

    /// Runs a command off the main thread and returns stdout.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, environment: [String: String]? = nil, directory: URL? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(filePath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }
                if let directory { process.currentDirectoryURL = directory }
                process.standardInput = FileHandle.nullDevice
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Failure.failed("Could not start \((executable as NSString).lastPathComponent)"))
                    return
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errorData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                let text = String(decoding: data, as: UTF8.self)
                if process.terminationStatus == 0 || !text.isEmpty {
                    continuation.resume(returning: text)
                } else {
                    let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: Failure.failed(message.isEmpty ? "Exited with code \(process.terminationStatus)" : message))
                }
            }
        }
    }
}

/// A small window with a terminal running `claude auth login`. The login
/// itself happens in the browser; the terminal is there for the URL fallback
/// and for any code Claude Code asks to paste.
@MainActor
final class ClaudeSignInWindow: NSObject, NSWindowDelegate, LocalProcessTerminalViewDelegate {
    private let window: NSWindow
    private let terminal = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 720, height: 400))
    private let onFinish: () -> Void
    private static var open: ClaudeSignInWindow?

    static func show(cli: String, onFinish: @escaping () -> Void) {
        open?.window.close()
        let controller = ClaudeSignInWindow(cli: cli, onFinish: onFinish)
        open = controller
        controller.window.makeKeyAndOrderFront(nil)
    }

    private init(cli: String, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Sign in to Claude Code"
        window.isReleasedWhenClosed = false
        window.delegate = self
        terminal.font = NSFont.monospacedSystemFont(ofSize: TerminalNode.fontSize, weight: .regular)
        TerminalPalette.current.apply(to: terminal)
        terminal.processDelegate = self
        window.contentView = terminal
        window.center()
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        terminal.startProcess(
            executable: cli,
            args: ["auth", "login"],
            environment: env.map { "\($0.key)=\($0.value)" },
            currentDirectory: NSHomeDirectory()
        )
        window.makeFirstResponder(terminal)
    }

    func windowWillClose(_ notification: Notification) {
        terminal.terminate()
        onFinish()
        Self.open = nil
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            // Leave the result readable for a moment, then close.
            DispatchQueue.main.asyncAfter(deadline: .now() + (exitCode == 0 ? 1.2 : 4)) { [weak self] in
                self?.window.close()
            }
        }
    }
}
