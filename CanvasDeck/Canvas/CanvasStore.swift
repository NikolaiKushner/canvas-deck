import CanvasCore
import Foundation
import os

/// `canvas.json` in Application Support: the camera and every card. Written a
/// second after the last change and at once when the app quits; read at
/// launch. A file this build cannot use is kept next to it, not overwritten.
///
/// Development launches (`--open`, `--seed`, `--load-test`) neither read nor
/// write it: test cards must not end up in someone's real layout.
@MainActor
final class CanvasStore {
    nonisolated static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CanvasDeck/canvas.json")
    }
    static let saveDelay: TimeInterval = 1

    static var isEphemeral: Bool {
        CommandLine.arguments.contains { $0.hasPrefix("--open=") || $0 == "--seed" || $0.hasPrefix("--load-test") }
    }

    private var pending: DispatchWorkItem?
    private var last: Layout?
    /// After quit or window close: terminals are being killed, and their
    /// last hooks must not rewrite the saved layout.
    private var closed = false
    nonisolated private static let log = Logger(subsystem: "app.canvasdeck", category: "canvas")

    func load() -> Layout {
        guard !Self.isEphemeral, let data = try? Data(contentsOf: Self.url) else { return Layout() }
        switch LayoutFile.decode(data) {
        case .layout(let layout):
            last = layout
            Self.log.notice("restored \(layout.nodes.count) cards")
            return layout
        case .newer(let version):
            setAside(suffix: "v\(version)")
        case .unreadable:
            setAside(suffix: "unreadable-\(Int(Date().timeIntervalSince1970))")
        }
        return Layout()
    }

    func save(_ layout: Layout) {
        guard !Self.isEphemeral, !closed, layout != last else { return }
        last = layout
        pending?.cancel()
        let work = DispatchWorkItem { Self.write(layout) }
        pending = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    /// Writes now and stops taking changes until `reopen()`.
    func close(with layout: Layout) {
        guard !Self.isEphemeral, !closed else { return }
        pending?.cancel()
        pending = nil
        last = layout
        Self.write(layout)
        closed = true
    }

    func reopen() { closed = false }

    nonisolated private static func write(_ layout: Layout) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LayoutFile.encode(layout).write(to: url, options: .atomic)
        } catch {
            log.error("could not save the canvas: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setAside(suffix: String) {
        let target = Self.url.deletingPathExtension().appendingPathExtension("\(suffix).json")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: Self.url, to: target)
        Self.log.notice("canvas.json set aside as \(target.lastPathComponent, privacy: .public)")
    }
}
