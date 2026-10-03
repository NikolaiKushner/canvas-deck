import AppKit
import SwiftUI

/// A folder offered when opening Claude Code.
struct FolderChoice: Identifiable, Hashable {
    enum Source: Int { case canvas, recent, claude, home }

    let path: String
    let source: Source
    let lastUsed: Date?
    let branch: String?
    var id: String { path }
    var name: String { path == NSHomeDirectory() ? "Home" : (path as NSString).lastPathComponent }
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

/// Where the folders come from: cards on the canvas, folders the canvas
/// opened Claude Code in before, and projects Claude Code itself knows
/// (`.claude.json`, read only).
enum FolderSources {
    static func gather(canvasFolders: [String]) -> [FolderChoice] {
        var seen = Set<String>()
        var result: [FolderChoice] = []
        func add(_ path: String, _ source: FolderChoice.Source, _ date: Date? = nil) {
            let path = (path as NSString).standardizingPath
            guard !seen.contains(path), Settings.isDirectory(path) else { return }
            seen.insert(path)
            result.append(FolderChoice(path: path, source: source, lastUsed: date ?? lastSession(at: path), branch: gitBranch(at: path)))
        }
        for path in canvasFolders where path != NSHomeDirectory() { add(path, .canvas) }
        for path in Settings.recentClaudeFolders { add(path, .recent) }
        let projects = claudeProjects()
            .map { ($0, lastSession(at: $0)) }
            .sorted { ($0.1 ?? .distantPast) > ($1.1 ?? .distantPast) }
        for (path, date) in projects where path != NSHomeDirectory() { add(path, .claude, date) }
        add(NSHomeDirectory(), .home)
        return result
    }

    /// Project paths from Claude Code's `.claude.json` in every known
    /// configuration folder, minus worktrees Claude Code made for itself.
    static func claudeProjects() -> [String] {
        var paths = Set<String>()
        for directory in ClaudeConfig.knownDirectories {
            guard let data = try? Data(contentsOf: ClaudeConfig.stateFile(in: directory)),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let projects = object["projects"] as? [String: Any] else { continue }
            paths.formUnion(projects.keys.filter { !$0.contains("/.claude/worktrees/") })
        }
        return Array(paths)
    }

    /// When Claude Code last wrote a transcript for this folder, in any known
    /// configuration folder.
    static func lastSession(at path: String) -> Date? {
        ClaudeConfig.knownDirectories
            .compactMap { (try? ClaudeConfig.projectDirectory(for: path, in: $0).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            .max()
    }

    /// Current branch from `.git/HEAD`, without running git.
    static func gitBranch(at path: String) -> String? {
        let head = URL(filePath: path).appending(path: ".git/HEAD")
        guard let text = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let prefix = "ref: refs/heads/"
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : String(line.prefix(7))
    }
}

@MainActor
final class FolderPickerModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0 } }
    @Published var selection = 0
    let choices: [FolderChoice]
    var onPick: ((String) -> Void)?
    var onChooseOther: (() -> Void)?
    var onCancel: (() -> Void)?

    init(choices: [FolderChoice]) {
        self.choices = choices
    }

    var filtered: [FolderChoice] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return choices }
        return choices.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.displayPath.localizedCaseInsensitiveContains(q)
        }
    }

    func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = min(max(0, selection + delta), count - 1)
    }

    func pickSelected() {
        let list = filtered
        if list.indices.contains(selection) {
            onPick?(list[selection].path)
        } else if list.isEmpty {
            // A typed path that exists opens directly.
            let typed = (query.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            if Settings.isDirectory(typed) { onPick?(typed) }
        }
    }
}

struct FolderPickerView: View {
    @ObservedObject var model: FolderPickerModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Open Claude Code in…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($searchFocused)
                .onSubmit { model.pickSelected() }
                .onExitCommand { model.onCancel?() }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.downArrow) { model.move(1); return .handled }
            Divider()
            ScrollViewReader { proxy in
                List {
                    let list = model.filtered
                    if list.isEmpty {
                        Text("No matching folders. Type a full path or choose a folder below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, choice in
                        row(choice, selected: index == model.selection)
                            .id(choice.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.onPick?(choice.path) }
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .onChange(of: model.selection) { _, index in
                    let list = model.filtered
                    if list.indices.contains(index) { proxy.scrollTo(list[index].id) }
                }
            }
            Divider()
            HStack {
                Button("Choose Folder…") { model.onChooseOther?() }
                    .keyboardShortcut("o", modifiers: .command)
                Spacer()
                Text("↑↓ to select · ⏎ to open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .frame(width: 440, height: 460)
        .onAppear { searchFocused = true }
    }

    private func row(_ choice: FolderChoice, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(for: choice.source))
                .frame(width: 20)
                .foregroundStyle(selected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(choice.name).font(.body.weight(.medium))
                    if let branch = choice.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                    }
                }
                Text(choice.displayPath)
                    .font(.caption)
                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let date = choice.lastUsed {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func symbol(for source: FolderChoice.Source) -> String {
        switch source {
        case .canvas: "rectangle.on.rectangle"
        case .recent: "clock"
        case .claude: "sparkles"
        case .home: "house"
        }
    }
}

/// Floating folder picker, shown where the user asked for a Claude Code card.
@MainActor
final class FolderPickerPanel: NSPanel {
    let model: FolderPickerModel

    init(choices: [FolderChoice]) {
        model = FolderPickerModel(choices: choices)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 460),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .canvasPanel
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: FolderPickerView(model: model))
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        model.onCancel?()
    }

    func present(atCocoaPoint point: NSPoint) {
        let visible = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        var origin = NSPoint(x: point.x, y: point.y - frame.height)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        setFrameOrigin(origin)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}
