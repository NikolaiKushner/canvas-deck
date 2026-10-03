import AppKit
import SwiftUI

/// What "Open…" offers: the canvas's own cards.
struct BuiltinKind: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Hashable {
        case browser, terminal, claude, linear
    }

    let kind: Kind
    var id: Kind { kind }
    var title: String {
        switch kind {
        case .browser: "Browser"
        case .terminal: "Terminal"
        case .claude: "Claude Code"
        case .linear: "Linear"
        }
    }
    var symbol: String {
        switch kind {
        case .browser: "globe"
        case .terminal: "terminal"
        case .claude: "sparkles"
        case .linear: "checklist"
        }
    }

    static let all = Kind.allCases.map { BuiltinKind(kind: $0) }
}

@MainActor
final class AppPickerModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0 } }
    @Published var selection = 0
    let builtins: [BuiltinKind]
    var onPickBuiltin: ((BuiltinKind) -> Void)?
    var onCancel: (() -> Void)?

    init(builtins: [BuiltinKind]) {
        self.builtins = builtins
    }

    var filtered: [BuiltinKind] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return builtins }
        return builtins.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = min(max(0, selection + delta), count - 1)
    }

    func pickSelected() {
        let list = filtered
        guard list.indices.contains(selection) else { return }
        onPickBuiltin?(list[selection])
    }
}

struct AppPickerView: View {
    @ObservedObject var model: AppPickerModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Open…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($searchFocused)
                .onSubmit { model.pickSelected() }
                .onExitCommand { model.onCancel?() }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.downArrow) { model.move(1); return .handled }
            Divider()
            VStack(spacing: 2) {
                ForEach(Array(model.filtered.enumerated()), id: \.element.id) { index, item in
                    row(item, selected: index == model.selection)
                        .contentShape(Rectangle())
                        .onTapGesture { model.onPickBuiltin?(item) }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
        }
        .frame(width: 320, height: 250)
        .onAppear { searchFocused = true }
    }

    private func row(_ item: BuiltinKind, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).frame(width: 22)
            Text(item.title)
            Spacer()
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Floating picker, shown where the user asked for a card.
@MainActor
final class AppPickerPanel: NSPanel {
    let model: AppPickerModel

    init(builtins: [BuiltinKind]) {
        model = AppPickerModel(builtins: builtins)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 250),
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
        contentView = NSHostingView(rootView: AppPickerView(model: model))
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        model.onCancel?()
    }

    func present(atCocoaPoint point: NSPoint) {
        model.query = ""
        let visible = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        var origin = NSPoint(x: point.x, y: point.y - frame.height)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        setFrameOrigin(origin)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}
