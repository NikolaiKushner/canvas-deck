import Foundation

/// Opt-in (Settings → Claude Code → Limits): Canvas Deck's status line in
/// `~/.claude/settings.json`, so limits arrive from every Claude Code session,
/// not only canvas cards. Only the `statusLine` key changes. The whole file is
/// backed up first, and the previous status line comes back on uninstall.
enum GlobalStatusline {
    enum Failure: Error, LocalizedError {
        case unreadable(String)
        case unwritable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let why): "Could not read \(GlobalStatusline.displayPath): \(why)"
            case .unwritable(let why): "Could not write \(GlobalStatusline.displayPath): \(why)"
            }
        }
    }

    private static let previousKey = "globalStatuslinePrevious"

    static var settingsURL: URL {
        // A dotfiles symlink stays a symlink: read and write through to its target.
        ClaudeConfig.settingsFile(in: ClaudeConfig.defaultDirectory).resolvingSymlinksInPath()
    }

    /// The settings file as the user would type it, for messages.
    static var displayPath: String {
        (ClaudeConfig.settingsFile(in: ClaudeConfig.defaultDirectory).path as NSString).abbreviatingWithTildeInPath
    }

    static var backupDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CanvasDeck/claude-settings-backups", directoryHint: .isDirectory)
    }

    static func ourCommand(helper: String) -> String { "\(ClaudeLaunch.shellQuote(helper)) --statusline" }

    /// The user's status line command, or nil when there is none.
    static func currentCommand() -> String? {
        (try? readSettings())?["statusLine"].flatMap { ($0 as? [String: Any])?["command"] as? String }
    }

    static var isInstalled: Bool {
        guard let command = currentCommand() else { return false }
        return command.contains("canvas-notify") && command.contains("--statusline")
    }

    /// What will come back on uninstall, for the settings text.
    static var previousCommand: String? {
        guard let data = UserDefaults.standard.data(forKey: previousKey),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["command"] as? String
    }

    static func install(helper: String) throws {
        var settings = try readSettings() ?? [:]
        try backup()
        if !isInstalled {
            if let previous = settings["statusLine"], let data = try? JSONSerialization.data(withJSONObject: previous) {
                UserDefaults.standard.set(data, forKey: previousKey)
            } else {
                UserDefaults.standard.removeObject(forKey: previousKey)
            }
        }
        settings["statusLine"] = [
            "type": "command",
            "command": ourCommand(helper: helper),
            "padding": 0,
            "refreshInterval": 60,
        ] as [String: Any]
        try write(settings)
    }

    static func uninstall() throws {
        guard var settings = try readSettings() else { return }
        try backup()
        if let data = UserDefaults.standard.data(forKey: previousKey),
           let previous = try? JSONSerialization.jsonObject(with: data) {
            settings["statusLine"] = previous
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try write(settings)
        UserDefaults.standard.removeObject(forKey: previousKey)
    }

    /// The app moved (a new build folder, /Applications): point the command at
    /// the helper inside this copy.
    static func repairIfNeeded(helper: String) {
        guard isInstalled, currentCommand() != ourCommand(helper: helper) else { return }
        try? install(helper: helper)
    }

    // MARK: File

    private static func readSettings() throws -> [String: Any]? {
        let url = settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            if data.isEmpty { return [:] }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.unreadable("it is not a JSON object")
            }
            return object
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
    }

    private static func backup() throws {
        let url = settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let target = backupDirectory.appending(path: "settings-\(formatter.string(from: Date())).json")
        do {
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            throw Failure.unwritable("backup failed: \(error.localizedDescription)")
        }
    }

    private static func write(_ settings: [String: Any]) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data + Data("\n".utf8)).write(to: settingsURL, options: .atomic)
        } catch {
            throw Failure.unwritable(error.localizedDescription)
        }
    }
}
