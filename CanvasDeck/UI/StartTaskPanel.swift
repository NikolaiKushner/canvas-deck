import AppKit
import CanvasCore
import SwiftUI
import Trackers

/// "Start in Claude Code" for a Linear issue: what to do, where, and
/// whether to move the issue on in Linear (one click, never on its own).
@MainActor
final class StartTaskModel: ObservableObject {
    let issue: Issue
    let statuses: [IssueStatus]
    @Published var task = 0
    @Published var customText = ""
    @Published var folder: String
    /// Status id to move the issue to on start; empty for none.
    @Published var moveTo: String
    var onStart: ((AgentTask, String, IssueStatus?) -> Void)?
    var onCancel: (() -> Void)?

    init(issue: Issue, statuses: [IssueStatus], folder: String) {
        self.issue = issue
        self.statuses = statuses
        self.folder = folder
        // Not started yet: suggest the first in-progress column.
        let notStarted = ["backlog", "unstarted", "triage"].contains(issue.statusType ?? "")
        moveTo = notStarted ? (statuses.first { $0.type == "started" }?.id ?? "") : ""
    }

    var tasks: [AgentTask] { AgentTask.builtIn + [.custom("")] }

    var canStart: Bool {
        guard Settings.isDirectory(folder) else { return false }
        if case .custom = tasks[task] { return !customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return true
    }

    func start() {
        guard canStart else { return }
        var chosen = tasks[task]
        if case .custom = chosen { chosen = .custom(customText) }
        onStart?(chosen, folder, statuses.first { $0.id == moveTo })
    }

    func chooseFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.directoryURL = URL(filePath: folder, directoryHint: .isDirectory)
        open.prompt = "Choose"
        if open.runModal() == .OK, let url = open.url { folder = url.path }
    }
}

struct StartTaskView: View {
    @ObservedObject var model: StartTaskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Start in Claude Code").font(.headline)
                Text("\(model.issue.id)  \(model.issue.title)").font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Picker("Task", selection: $model.task) {
                ForEach(Array(model.tasks.enumerated()), id: \.offset) { index, task in
                    Text(task.title).tag(index)
                }
            }
            if case .custom = model.tasks[model.task] {
                TextEditor(text: $model.customText)
                    .font(.body)
                    .frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
            }
            LabeledContent("Folder") {
                HStack(spacing: 8) {
                    Text((model.folder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(Settings.isDirectory(model.folder) ? .primary : Color.red)
                    Button("Choose…") { model.chooseFolder() }
                }
            }
            Picker("Move in Linear to", selection: $model.moveTo) {
                Text("Don't change the status").tag("")
                ForEach(model.statuses.filter { $0.name != model.issue.status }, id: \.id) { status in
                    Text(status.name).tag(status.id)
                }
            }
            Text("The issue's title, link, branch and description go into the first message. The folder is remembered for \(model.issue.team ?? "this team").")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.onCancel?() }.keyboardShortcut(.cancelAction)
                Button("Start") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

@MainActor
final class StartTaskPanel: NSPanel {
    let model: StartTaskModel

    init(model: StartTaskModel) {
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .canvasPanel
        isReleasedWhenClosed = false
        let host = NSHostingView(rootView: StartTaskView(model: model))
        contentView = host
        setContentSize(host.fittingSize)
    }

    override var canBecomeKey: Bool { true }

    func present(over window: NSWindow) {
        setFrameOrigin(NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.midY - frame.height / 2 + 120))
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}
