import AppKit
import CanvasCore
import SwiftUI

/// One row of the palette: what `JumpSearch` ranks, plus how it looks and
/// what Enter does.
struct JumpRow: Identifiable {
    var item: JumpItem
    var symbol: String
    var status: String?
    var statusColor: Color?
    var badge: String?
    var shortcut: String?
    var run: () -> Void
    var id: String { item.id }
}

@MainActor
final class JumpPaletteModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0 } }
    @Published var selection = 0
    let rows: [JumpRow]
    var onDone: (() -> Void)?
    private let byID: [String: JumpRow]

    init(rows: [JumpRow]) {
        self.rows = rows
        byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var filtered: [JumpRow] {
        JumpSearch.rank(rows.map(\.item), query: query).compactMap { byID[$0.id] }
    }

    func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = min(max(0, selection + delta), count - 1)
    }

    func run(_ row: JumpRow) {
        onDone?()
        row.run()
    }

    func runSelected() {
        let list = filtered
        guard list.indices.contains(selection) else { return }
        run(list[selection])
    }
}

struct JumpPaletteView: View {
    @ObservedObject var model: JumpPaletteModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to a card, a session or a command", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { model.runSelected() }
                    .onExitCommand { model.onDone?() }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                List {
                    let list = model.filtered
                    if list.isEmpty {
                        Text("Nothing matches.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, row in
                        rowView(row, selected: index == model.selection)
                            .id(row.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.run(row) }
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
                Text("↑↓ to select · ⏎ to go · esc to close")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
        .frame(width: 520, height: 440)
        .onAppear { searchFocused = true }
    }

    private func rowView(_ row: JumpRow, selected: Bool) -> some View {
        let secondary: Color = selected ? .white.opacity(0.85) : .secondary
        return HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .frame(width: 20)
                .foregroundStyle(selected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.item.title).font(.body.weight(.medium)).lineLimit(1)
                    if let badge = row.badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(secondary.opacity(0.6)))
                            .foregroundStyle(secondary)
                    }
                }
                if !row.item.subtitle.isEmpty {
                    Text(row.item.subtitle)
                        .font(.caption)
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let status = row.status {
                HStack(spacing: 5) {
                    Circle().fill(selected ? .white : row.statusColor ?? .secondary).frame(width: 7, height: 7)
                    Text(status).font(.caption.weight(.semibold))
                }
                .foregroundStyle(selected ? .white : row.statusColor ?? .secondary)
            }
            if let shortcut = row.shortcut {
                Text(shortcut).font(.caption.monospaced()).foregroundStyle(secondary)
            }
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// ⌘K: a floating panel over the canvas, centred near the top.
@MainActor
final class JumpPalettePanel: NSPanel {
    let model: JumpPaletteModel

    init(rows: [JumpRow]) {
        model = JumpPaletteModel(rows: rows)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
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
        contentView = NSHostingView(rootView: JumpPaletteView(model: model))
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        model.onDone?()
    }

    func present(over window: NSWindow) {
        let frame = window.frame
        setFrameOrigin(NSPoint(x: frame.midX - self.frame.width / 2, y: frame.maxY - self.frame.height - 120))
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}
