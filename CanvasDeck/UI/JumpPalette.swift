import AppKit
import CanvasCore
import SwiftUI

/// One row of the palette: what `JumpSearch` ranks, plus how it looks and
/// what Enter does.
struct JumpRow: Identifiable {
    /// Where the row is listed, under a header.
    enum Section: Int, CaseIterable {
        case waiting, cards, issues, commands, sessions

        var title: String {
            switch self {
            case .waiting: "Waiting for you"
            case .cards: "Cards"
            case .issues: "Issues"
            case .commands: "Commands"
            case .sessions: "Past sessions"
            }
        }
    }

    /// A button at the right of the row, e.g. Allow or Start in Claude Code.
    struct Action {
        var title: String
        var primary = false
        var run: () -> Void
    }

    var item: JumpItem
    var section: Section
    /// The icon square: "›_", "$", "◎", "◆", or an SF Symbol name when `symbol` is set.
    var glyph: String
    var symbol: String?
    /// The agent's state colour: tints the icon square.
    var tint: NSColor?
    var badge: String?
    var shortcut: String?
    var actions: [Action] = []
    var run: () -> Void
    /// ⌘↵: open in a new card (a new terminal in the same folder, a second browser card).
    var runInNewCard: (() -> Void)?
    var id: String { item.id }
}

@MainActor
final class JumpPaletteModel: ObservableObject {
    /// The filter chips: everything, cards only, issues only. Tab cycles.
    enum Scope: CaseIterable {
        case all, cards, issues
        var title: String {
            switch self {
            case .all: "All"
            case .cards: "Cards"
            case .issues: "Issues"
            }
        }
    }

    @Published var query = "" { didSet { selection = 0 } }
    @Published var scope = Scope.all { didSet { selection = 0 } }
    @Published var selection = 0
    let rows: [JumpRow]
    var onDone: (() -> Void)?
    private let byID: [String: JumpRow]

    init(rows: [JumpRow]) {
        self.rows = rows
        byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Ranked rows, then grouped by section in a fixed order; rank order
    /// holds inside each section.
    var sections: [(JumpRow.Section, [JumpRow])] {
        let ranked = JumpSearch.rank(rows.map(\.item), query: query).compactMap { byID[$0.id] }
        let inScope = ranked.filter { row in
            switch scope {
            case .all: true
            case .cards: row.section == .cards || row.section == .waiting
            case .issues: row.section == .issues
            }
        }
        return JumpRow.Section.allCases.compactMap { section in
            let list = inScope.filter { $0.section == section }
            return list.isEmpty ? nil : (section, list)
        }
    }

    var filtered: [JumpRow] { sections.flatMap(\.1) }

    func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = min(max(0, selection + delta), count - 1)
    }

    func cycleScope() {
        let all = Scope.allCases
        scope = all[((all.firstIndex(of: scope) ?? 0) + 1) % all.count]
    }

    func run(_ row: JumpRow) {
        onDone?()
        row.run()
    }

    func run(_ action: JumpRow.Action) {
        onDone?()
        action.run()
    }

    func runSelected(inNewCard: Bool = false) {
        let list = filtered
        guard list.indices.contains(selection) else { return }
        let row = list[selection]
        onDone?()
        if inNewCard, let alternate = row.runInNewCard { alternate() } else { row.run() }
    }
}

/// ⌘K (App design → Jump palette ⌘K).
struct JumpPaletteView: View {
    @ObservedObject var model: JumpPaletteModel
    @FocusState private var searchFocused: Bool

    private let text = Color(nsColor: CanvasPalette.text)
    private let secondary = Color(nsColor: CanvasPalette.secondaryText)

    var body: some View {
        VStack(spacing: 0) {
            field
            Rectangle().fill(Color(nsColor: CanvasPalette.line)).frame(height: 1)
            results
            footer
        }
        .frame(width: 640)
        .background(Color(nsColor: CanvasPalette.card), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(nsColor: CanvasPalette.edge), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Room on every side for the whole shadow: the panel's edge cut it off.
        .shadow(color: .black.opacity(0.18), radius: 22, y: 14)
        .padding(.horizontal, 64)
        .padding(.top, 24)
        .padding(.bottom, 90)
        // The panel keeps one size; the clear space under a short list lets
        // clicks through to the canvas.
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { searchFocused = true }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(secondary)
            TextField("Jump to a card, session or issue", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(text)
                .focused($searchFocused)
                .onSubmit { model.runSelected(inNewCard: NSEvent.modifierFlags.contains(.command)) }
                .onExitCommand { model.onDone?() }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(.tab) { model.cycleScope(); return .handled }
            HStack(spacing: 4) {
                ForEach(JumpPaletteModel.Scope.allCases, id: \.self) { scope in
                    Button { model.scope = scope } label: {
                        Text(scope.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(model.scope == scope ? text : secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(model.scope == scope ? Color(nsColor: CanvasPalette.chipStrong) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, 16)
    }

    private var results: some View {
        let sections = model.sections
        var index = 0
        let numbered = sections.map { section, rows in
            (section, rows.map { row -> (Int, JumpRow) in
                defer { index += 1 }
                return (index, row)
            })
        }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if numbered.isEmpty {
                        Text("Nothing matches.")
                            .font(.system(size: 13))
                            .foregroundStyle(secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 14)
                    }
                    ForEach(numbered, id: \.0) { section, rows in
                        Text(section.title.uppercased())
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(secondary.opacity(0.9))
                            .padding(.leading, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                        ForEach(rows, id: \.1.id) { index, row in
                            rowView(row, selected: index == model.selection)
                                .id(row.id)
                                .contentShape(Rectangle())
                                .onTapGesture { model.run(row) }
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: model.selection) { _, index in
                let list = model.filtered
                if list.indices.contains(index) { proxy.scrollTo(list[index].id) }
            }
        }
    }

    private func rowView(_ row: JumpRow, selected: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(row.tint.map { Color(nsColor: $0).opacity(0.15) } ?? Color(nsColor: CanvasPalette.chipStrong).opacity(0.75))
                if let symbol = row.symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                } else {
                    Text(row.glyph)
                        .font(row.glyph.count > 1 ? .system(size: 10.5, weight: .medium, design: .monospaced) : .system(size: 13, weight: .medium))
                }
            }
            .foregroundStyle(row.tint.map { Color(nsColor: $0) } ?? text)
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.item.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(text).lineLimit(1)
                    if let badge = row.badge {
                        Text(badge)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color(nsColor: CanvasPalette.chip), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                if !row.item.subtitle.isEmpty {
                    Text(row.item.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            ForEach(Array(row.actions.enumerated()), id: \.offset) { _, action in
                Button { model.run(action) } label: {
                    Text(action.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(action.primary ? .white : secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(action.primary ? Color(nsColor: CanvasPalette.accent) : Color(nsColor: CanvasPalette.chipStrong).opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            if let shortcut = row.shortcut {
                Text(shortcut).font(.system(size: 11.5, weight: .medium)).foregroundStyle(secondary)
            }
            if selected, row.actions.isEmpty {
                Text("↵")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: CanvasPalette.chipStrong).opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Color(nsColor: CanvasPalette.accent).opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("↑↓ move")
            Text("↵ open")
            Text("⌘↵ open in new card")
            Text("tab scope")
            Spacer()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(nsColor: CanvasPalette.bar))
        .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: CanvasPalette.line)).frame(height: 1) }
    }
}

/// ⌘K: a floating panel over the canvas, centred near the top.
@MainActor
final class JumpPalettePanel: NSPanel {
    let model: JumpPaletteModel

    init(rows: [JumpRow]) {
        model = JumpPaletteModel(rows: rows)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 768, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // The card draws its own shadow; the window's would outline the clear area.
        hasShadow = false
        level = .canvasPanel
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: JumpPaletteView(model: model))
    }

    override var canBecomeKey: Bool { true }

    /// `--palette` (development): stays open without the keyboard, for screenshots.
    var staysOpen = false

    override func resignKey() {
        super.resignKey()
        if !staysOpen { model.onDone?() }
    }

    func present(over window: NSWindow) {
        let frame = window.frame
        setFrameTopLeftPoint(NSPoint(x: frame.midX - self.frame.width / 2, y: frame.maxY - 86))
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}
