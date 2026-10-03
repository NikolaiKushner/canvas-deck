import AppKit
import SwiftUI
import Trackers

/// User settings, one tab per area: the app itself, the terminal card, the
/// browser card. Values live in `UserDefaults`; each tab reads and writes only
/// its own keys.
enum Settings {
    private enum Key {
        static let confirmCloseRunning = "confirmCloseRunningCard"
        static let noticesOnCanvas = "noticesOnCanvas"
        static let noticesInMacOS = "noticesInMacOS"
        static let noticeSound = "noticeSound"
        static let linearNotices = "linearNotices"
        static let linearTeamFolders = "linearTeamFolders"
        static let terminalHome = "terminalHomeDirectory"
        static let terminalLastActive = "terminalUsesLastActiveFolder"
        static let appearance = "appearance"
        static let browserHomePage = "browserHomePage"
        static let claudeAsksForFolder = "claudeAsksForFolder"
        static let recentClaudeFolders = "recentClaudeFolders"
        static let terminalAgentShim = "terminalAgentShim"
        static let refreshLimits = "refreshLimitsWithUsageCommand"
        static let titleBarAccount = "titleBarClaudeAccount"
        static let knownAccounts = "knownClaudeAccounts"
    }

    private static let defaults = UserDefaults.standard

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.confirmCloseRunning: true,
            Key.noticesOnCanvas: true,
            Key.noticesInMacOS: true,
            Key.noticeSound: true,
            Key.linearNotices: true,
            Key.browserHomePage: "",
            Key.claudeAsksForFolder: true,
            Key.terminalAgentShim: true,
            Key.refreshLimits: true,
        ])
    }

    // MARK: General

    /// Ask before the × on a card kills a shell that is still running.
    static var confirmCloseRunningCard: Bool {
        get { defaults.bool(forKey: Key.confirmCloseRunning) }
        set { defaults.set(newValue, forKey: Key.confirmCloseRunning) }
    }

    /// Toasts in the top-right corner of the canvas.
    static var noticesOnCanvas: Bool {
        get { defaults.bool(forKey: Key.noticesOnCanvas) }
        set { defaults.set(newValue, forKey: Key.noticesOnCanvas) }
    }

    /// macOS notifications while the canvas window is not in front.
    static var noticesInMacOS: Bool {
        get { defaults.bool(forKey: Key.noticesInMacOS) }
        set { defaults.set(newValue, forKey: Key.noticesInMacOS) }
    }

    /// A sound with a notice, on the canvas and in macOS.
    static var noticeSound: Bool {
        get { defaults.bool(forKey: Key.noticeSound) }
        set { defaults.set(newValue, forKey: Key.noticeSound) }
    }

    /// New comments, mentions and changes from the Linear inbox as toasts.
    static var linearNotices: Bool {
        get { defaults.bool(forKey: Key.linearNotices) }
        set { defaults.set(newValue, forKey: Key.linearNotices) }
    }

    /// Linear team id → the folder Claude Code starts in for its issues.
    static var linearTeamFolders: [String: String] {
        get { defaults.dictionary(forKey: Key.linearTeamFolders) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.linearTeamFolders) }
    }

    // MARK: Terminal

    /// Light or dark for the whole app, terminals included.
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    /// The system's unless the user picked one. Applies at once.
    static var appearance: Appearance {
        get { defaults.string(forKey: Key.appearance).flatMap(Appearance.init(rawValue:)) ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: Key.appearance)
            MainActor.assumeIsolated { applyAppearance() }
        }
    }

    /// `--appearance=dark` or `=light` (development) wins over the setting.
    @MainActor
    static func applyAppearance() {
        let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--appearance=") })?.dropFirst("--appearance=".count)
        let choice = flag.flatMap { Appearance(rawValue: String($0)) } ?? appearance
        switch choice {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// `claude` typed in any terminal card runs with the canvas hooks
    /// (`ShellIntegration`). Takes effect in shells started after the change.
    static var terminalAgentShim: Bool {
        get { defaults.bool(forKey: Key.terminalAgentShim) }
        set { defaults.set(newValue, forKey: Key.terminalAgentShim) }
    }

    static let titleBarAccountChanged = Notification.Name("CanvasDeckTitleBarAccountChanged")

    /// The account whose limits the title bar shows (its configuration
    /// folder); nil means the one signed in under Settings.
    static var titleBarAccount: String? {
        get { defaults.string(forKey: Key.titleBarAccount) }
        set {
            defaults.set(newValue, forKey: Key.titleBarAccount)
            NotificationCenter.default.post(name: titleBarAccountChanged, object: nil)
        }
    }

    /// Accounts the canvas has heard from, folder → "email · plan", kept by
    /// `UsageStore` for the title bar picker.
    static var knownClaudeAccounts: [String: String] {
        get { defaults.dictionary(forKey: Key.knownAccounts) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.knownAccounts) }
    }

    /// Limits from `claude -p /usage` every few minutes (`UsageProbe`).
    static var refreshLimitsWithUsageCommand: Bool {
        get { defaults.bool(forKey: Key.refreshLimits) }
        set { defaults.set(newValue, forKey: Key.refreshLimits) }
    }

    /// Empty means the user's home folder.
    static var terminalHomeDirectory: String {
        get { defaults.string(forKey: Key.terminalHome) ?? "" }
        set { defaults.set(newValue, forKey: Key.terminalHome) }
    }

    /// When on, a new terminal starts in the folder of the terminal card that was
    /// active last; the home folder is the fallback.
    static var terminalUsesLastActiveFolder: Bool {
        get { defaults.bool(forKey: Key.terminalLastActive) }
        set { defaults.set(newValue, forKey: Key.terminalLastActive) }
    }

    /// The configured home folder, or `~` when unset or missing on disk.
    static var resolvedTerminalHome: String {
        let path = (terminalHomeDirectory as NSString).expandingTildeInPath
        return isDirectory(path) ? path : NSHomeDirectory()
    }

    static func newTerminalDirectory(lastActive: String?) -> String {
        if terminalUsesLastActiveFolder, let lastActive, isDirectory(lastActive) {
            return lastActive
        }
        return resolvedTerminalHome
    }

    static func isDirectory(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: Claude Code

    /// Opening Claude Code from Open… first asks which folder to start in.
    static var claudeAsksForFolder: Bool {
        get { defaults.bool(forKey: Key.claudeAsksForFolder) }
        set { defaults.set(newValue, forKey: Key.claudeAsksForFolder) }
    }

    /// Folders Claude Code was opened in from the canvas, newest first.
    static var recentClaudeFolders: [String] {
        get { defaults.stringArray(forKey: Key.recentClaudeFolders) ?? [] }
        set { defaults.set(Array(newValue.prefix(12)), forKey: Key.recentClaudeFolders) }
    }

    static func noteClaudeFolder(_ path: String) {
        recentClaudeFolders = [path] + recentClaudeFolders.filter { $0 != path }
    }

    // MARK: Browser

    /// What a new browser card opens. Empty means the built-in start page.
    /// The page a new browser card opens.
    static var browserHomePage: String {
        get { defaults.string(forKey: Key.browserHomePage) ?? "" }
        set { defaults.set(newValue, forKey: Key.browserHomePage) }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var confirmCloseRunningCard: Bool {
        didSet { Settings.confirmCloseRunningCard = confirmCloseRunningCard }
    }
    @Published var noticesOnCanvas: Bool {
        didSet { Settings.noticesOnCanvas = noticesOnCanvas }
    }
    @Published var noticesInMacOS: Bool {
        didSet { Settings.noticesInMacOS = noticesInMacOS }
    }
    @Published var noticeSound: Bool {
        didSet { Settings.noticeSound = noticeSound }
    }
    @Published var homeDirectory: String {
        didSet { Settings.terminalHomeDirectory = homeDirectory }
    }
    @Published var usesLastActiveFolder: Bool {
        didSet { Settings.terminalUsesLastActiveFolder = usesLastActiveFolder }
    }
    @Published var titleBarAccount: String {
        didSet { Settings.titleBarAccount = titleBarAccount.isEmpty ? nil : titleBarAccount }
    }
    @Published private(set) var knownAccounts: [String: String] = [:]
    @Published var refreshLimits: Bool {
        didSet { Settings.refreshLimitsWithUsageCommand = refreshLimits }
    }
    @Published var agentShim: Bool {
        didSet { Settings.terminalAgentShim = agentShim }
    }
    @Published var appearance: Settings.Appearance {
        didSet { Settings.appearance = appearance }
    }
    @Published var browserHomePage: String {
        didSet { Settings.browserHomePage = browserHomePage }
    }
    @Published var claudeAsksForFolder: Bool {
        didSet { Settings.claudeAsksForFolder = claudeAsksForFolder }
    }
    @Published var recentClaudeFolderCount: Int

    enum AccountState: Equatable {
        case loading
        case signedIn(ClaudeAccount.Status)
        case signedOut
        case notInstalled
        case unavailable(String)
    }
    @Published var account: AccountState = .loading
    @Published var accountBusy = false
    @Published var globalStatusline = GlobalStatusline.isInstalled
    @Published var globalStatuslineError: String?
    @Published var userStatuslineCommand: String? = GlobalStatusline.isInstalled ? GlobalStatusline.previousCommand : GlobalStatusline.currentCommand()

    func setGlobalStatusline(_ on: Bool) {
        do {
            if on {
                try GlobalStatusline.install(helper: TerminalNode.notifyPath)
            } else {
                try GlobalStatusline.uninstall()
            }
            globalStatuslineError = nil
        } catch {
            globalStatuslineError = error.localizedDescription
        }
        globalStatusline = GlobalStatusline.isInstalled
        userStatuslineCommand = globalStatusline ? GlobalStatusline.previousCommand : GlobalStatusline.currentCommand()
    }

    init() {
        confirmCloseRunningCard = Settings.confirmCloseRunningCard
        noticesOnCanvas = Settings.noticesOnCanvas
        noticesInMacOS = Settings.noticesInMacOS
        noticeSound = Settings.noticeSound
        homeDirectory = Settings.terminalHomeDirectory
        usesLastActiveFolder = Settings.terminalUsesLastActiveFolder
        appearance = Settings.appearance
        agentShim = Settings.terminalAgentShim
        refreshLimits = Settings.refreshLimitsWithUsageCommand
        titleBarAccount = Settings.titleBarAccount ?? ""
        knownAccounts = Settings.knownClaudeAccounts
        browserHomePage = Settings.browserHomePage
        claudeAsksForFolder = Settings.claudeAsksForFolder
        recentClaudeFolderCount = Settings.recentClaudeFolders.count
    }

    func refreshAccount() {
        Task {
            switch await ClaudeAccount.status() {
            case .success(let status):
                account = status.loggedIn ? .signedIn(status) : .signedOut
                NotificationCenter.default.post(name: ClaudeAccount.statusChanged, object: status)
            case .failure(.cliNotFound):
                account = .notInstalled
            case .failure(.failed(let message)):
                account = .unavailable(message)
            }
        }
    }

    func signIn() {
        Task {
            guard let cli = await ClaudeAccount.cliPath() else {
                account = .notInstalled
                return
            }
            ClaudeSignInWindow.show(cli: cli) { [weak self] in self?.refreshAccount() }
        }
    }

    func signOut() {
        accountBusy = true
        Task {
            if let failure = await ClaudeAccount.logout(), case .failed(let message) = failure {
                account = .unavailable(message)
            }
            accountBusy = false
            refreshAccount()
        }
    }

    func reloadKnownAccounts() {
        knownAccounts = Settings.knownClaudeAccounts
    }

    func clearRecentClaudeFolders() {
        Settings.recentClaudeFolders = []
        recentClaudeFolderCount = 0
    }

    var homeIsValid: Bool {
        homeDirectory.isEmpty || Settings.isDirectory((homeDirectory as NSString).expandingTildeInPath)
    }

    var browserHomePageIsValid: Bool {
        let text = browserHomePage.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && url.host() != nil
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: Settings.resolvedTerminalHome, directoryHint: .isDirectory)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            homeDirectory = url.path
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var cli = ClaudeCLI.shared

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            terminalTab
                .tabItem { Label("Terminal", systemImage: "terminal") }
            claudeTab
                .tabItem { Label("Claude Code", systemImage: "sparkles") }
                .onAppear {
                    model.refreshAccount()
                    model.reloadKnownAccounts()
                }
            browserTab
                .tabItem { Label("Browser", systemImage: "globe") }
            LinearSettingsTab(connection: LinearConnection.shared, sync: LinearConnection.shared.sync)
                .tabItem { Label("Linear", systemImage: "checklist") }
        }
        .padding(.top, 8)
        .frame(width: 760, height: 600)
    }

    private var generalTab: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(Settings.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("The canvas, cards and terminals follow it. Claude Code has its own theme: run /theme inside it to match.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Cards") {
                Toggle("Ask before closing a card with a running process", isOn: $model.confirmCloseRunningCard)
                Text("The × on a terminal card stops its shell and everything running in it, including an agent. With this on, the canvas asks first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Show notices on the canvas", isOn: $model.noticesOnCanvas)
                Text("A toast in the top-right corner when an agent asks for permission or a question, finishes or fails, or a terminal rings its bell. A click brings you to the card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Notify in macOS when Canvas Deck is in the background", isOn: $model.noticesInMacOS)
                Toggle("Play a sound", isOn: $model.noticeSound)
            }
            Section("Keys") {
                LabeledContent("Return to the canvas from a card", value: "⌘⎋")
                LabeledContent("Go to a card, a session or a command", value: "⌘K")
                LabeledContent("Next agent waiting for you", value: "⌘J")
                LabeledContent("Open…", value: "double- or right-click the canvas")
            }
        }
        .formStyle(.grouped)
    }

    private var terminalTab: some View {
        Form {
            Section("New terminal folder") {
                LabeledContent("Home folder") {
                    HStack(spacing: 8) {
                        TextField("~", text: $model.homeDirectory)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 240)
                        Button("Choose…") { model.chooseFolder() }
                    }
                }
                if !model.homeIsValid {
                    Text("This folder does not exist; the terminal will open in ~.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Open in the folder of the last active card", isOn: $model.usesLastActiveFolder)
                Text("A terminal opened from Open… starts in the home folder. With this on, it starts in the folder of the terminal card that was active last, or the home folder if there is none.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var claudeTab: some View {
        Form {
            Section("Account") {
                accountSection
            }
            if case .found(let path, let version) = cli.state {
                Section("Claude Code") {
                    LabeledContent("Version", value: version ?? "Unknown")
                    LabeledContent("Location") {
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    if cli.isOutdated {
                        Text("Canvas Deck needs Claude Code \(ClaudeCLI.minimumVersion) or later for card status and limits. Run claude update in a terminal.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section("Limits") {
                Picker("Show in the title bar", selection: $model.titleBarAccount) {
                    Text("Signed-in account").tag("")
                    ForEach(model.knownAccounts.keys.sorted(), id: \.self) { folder in
                        Text("\(model.knownAccounts[folder] ?? "") — \((folder as NSString).abbreviatingWithTildeInPath)").tag(folder)
                    }
                    if !model.titleBarAccount.isEmpty, model.knownAccounts[model.titleBarAccount] == nil {
                        Text((model.titleBarAccount as NSString).abbreviatingWithTildeInPath).tag(model.titleBarAccount)
                    }
                }
                Text("Every Claude Code account has its own limits. The list has the accounts the canvas has seen, by their configuration folder (CLAUDE_CONFIG_DIR).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Refresh limits every 5 minutes", isOn: $model.refreshLimits)
                Text("Runs Claude Code's own /usage in the background for each account the canvas knows, so the title bar is current without a session open. It does not call a model, save a session, or load your hooks and MCP servers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show limits from every Claude Code session", isOn: Binding(
                    get: { model.globalStatusline },
                    set: { model.setGlobalStatusline($0) }
                ))
                Text(model.globalStatusline
                    ? "Canvas Deck's status line is set in \(GlobalStatusline.displayPath), so limits arrive from Claude Code in any terminal or IDE, not only canvas cards. Turning this off restores \(model.userStatuslineCommand.map { "`\($0)`" } ?? "no status line")."
                    : "Without this, limits arrive only from Claude Code cards on the canvas. With it, Canvas Deck sets its status line in \(GlobalStatusline.displayPath) (backed up first) and replaces \(model.userStatuslineCommand.map { "`\($0)`" } ?? "the default status line") until you turn it off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.globalStatuslineError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Starting a session") {
                Toggle("Choose a folder each time", isOn: $model.claudeAsksForFolder)
                Text("Opening Claude Code from Open… shows folders from the canvas, recent sessions and projects Claude Code already knows. Off: it starts where a new terminal would.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Recent folders") {
                    HStack(spacing: 8) {
                        Text("\(model.recentClaudeFolderCount)")
                            .foregroundStyle(.secondary)
                        Button("Clear") { model.clearRecentClaudeFolders() }
                            .disabled(model.recentClaudeFolderCount == 0)
                    }
                }
            }
            Section("Claude Code typed in a terminal") {
                Toggle("Track it like a Claude Code card", isOn: $model.agentShim)
                if model.agentShim, !ShellIntegration.supports(shell: TerminalNode.shell) {
                    Text("Your shell, \((TerminalNode.shell as NSString).lastPathComponent), is not supported: this works in zsh, bash and fish. Claude Code opened from Open… is tracked either way.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("Typing claude in any terminal card starts a session the canvas sees: status on the card, the Sessions menu, limits. Your shell startup files run as usual; claude auth, mcp and other commands are passed through unchanged. Applies to terminals opened after the change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var accountSection: some View {
        switch model.account {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the account…").foregroundStyle(.secondary)
            }
        case .signedIn(let status):
            LabeledContent("Signed in as") {
                Text(status.email ?? "Unknown").textSelection(.enabled)
            }
            if let org = status.orgName, !org.isEmpty {
                LabeledContent("Organization", value: org)
            }
            LabeledContent("Plan", value: [status.planName, status.authMethod].compactMap { $0 }.joined(separator: " · "))
            HStack {
                Spacer()
                Button("Sign Out") { model.signOut() }
                    .disabled(model.accountBusy)
            }
        case .signedOut:
            LabeledContent("Not signed in") {
                Button("Sign In…") { model.signIn() }
            }
            Text("Opens the Claude sign-in page in your browser. Claude Code keeps the credentials in the macOS keychain; Canvas Deck never sees them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .notInstalled:
            Text("Claude Code is not installed, or `claude` is not in any of the usual places or on your shell's PATH.")
                .foregroundStyle(.red)
            HStack {
                Button("How to Install…") { NSWorkspace.shared.open(ClaudeCLI.installURL) }
                Spacer()
                Button("Check Again") {
                    Task {
                        await ClaudeCLI.shared.refresh()
                        model.refreshAccount()
                    }
                }
            }
        case .unavailable(let message):
            Text(message).foregroundStyle(.red)
            HStack {
                Spacer()
                Button("Retry") { model.refreshAccount() }
            }
        }
    }

    private var browserTab: some View {
        Form {
            Section("New browser card") {
                LabeledContent("Start page") {
                    TextField("https://…", text: $model.browserHomePage)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 300)
                }
                if !model.browserHomePageIsValid {
                    Text("Enter a full address starting with http:// or https://.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Leave empty for the built-in start page. The browser card is not built yet; this setting is already saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings → Linear: sign in through Linear's MCP server, no API key.
struct LinearSettingsTab: View {
    @ObservedObject var connection: LinearConnection
    @ObservedObject var sync: IssueSync

    var body: some View {
        Form {
            Section("Account") {
                switch connection.state {
                case .signedOut:
                    LabeledContent("Not connected") {
                        Button("Sign In with Linear…") { connection.signIn() }
                    }
                    explanation
                case .signingIn:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to authorize Canvas Deck in the browser…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { connection.cancelSignIn() }
                    }
                case .connected(let user):
                    LabeledContent("Signed in as") {
                        Text([user.name, user.email].compactMap { $0 }.joined(separator: " · ")).textSelection(.enabled)
                    }
                    HStack {
                        Spacer()
                        Button("Sign Out") { connection.signOut() }
                    }
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                    HStack {
                        Spacer()
                        Button("Sign In with Linear…") { connection.signIn() }
                    }
                }
            }
            if case .connected = connection.state {
                Section("Issues") {
                    LabeledContent("Open issues assigned to you", value: "\(sync.issues.count)")
                    if let at = sync.lastSync {
                        LabeledContent("Updated") { Text(at, format: .relative(presentation: .named)) }
                    }
                    if let error = sync.lastError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    Toggle("Show Linear notifications on the canvas", isOn: Binding(
                        get: { Settings.linearNotices },
                        set: { Settings.linearNotices = $0 }
                    ))
                    Text("New comments, mentions and changes by others from your Linear inbox, as toasts in the top-right corner. Canvas Deck does not mark them read.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Refreshed every minute. Find them with ⌘K by number or title. Linear itself opens in a browser card; on an issue's page its title bar has Start in Claude Code and Move to.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh Now") { sync.refresh(full: true) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var explanation: some View {
        Text("Opens Linear in your browser to authorize Canvas Deck. It connects to Linear's MCP server, the same one Claude Code uses, with a sign-in of its own; the tokens stay in your Keychain. It reads the issues assigned to you and changes an issue only when you choose to from its menu.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
