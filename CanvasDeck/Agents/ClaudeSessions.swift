import CanvasCore
import Foundation
import Usage

/// `sessions.json` plus what the Sessions menu shows about each entry. Writes
/// are debounced; transcript costs are read off the main thread and cached by
/// file modification date.
@MainActor
final class ClaudeSessionStore {
    private(set) var index = ClaudeSessionIndex()
    private var saveWork: DispatchWorkItem?
    private var summaries: [String: (modified: Date, summary: TranscriptSummary)] = [:]
    private var loading = Set<String>()
    /// Called when a transcript summary arrives, so an open menu can refresh.
    var onSummary: (() -> Void)?

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CanvasDeck/sessions.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder.withDates.decode(ClaudeSessionIndex.self, from: data) {
            index = saved
        }
        // Nothing from a previous run is live; cards the layout brings back
        // attach their sessions again when they resume (`CanvasController`).
        index.closeAllOpen(at: Date())
        scheduleSave()
    }

    func update(_ change: (inout ClaudeSessionIndex) -> Void) {
        let before = index
        change(&index)
        if index != before { scheduleSave() }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = index
        let work = DispatchWorkItem {
            let url = Self.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder.withDates.encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }

    func flush() {
        guard let work = saveWork else { return }
        work.cancel()
        saveWork = nil
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.withDates.encode(index) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Transcripts

    static func transcriptURL(for session: ClaudeSession) -> URL {
        ClaudeConfig.transcript(session: session.id, cwd: session.cwd)
    }

    /// The cached summary, if fresh; otherwise starts reading it and returns
    /// whatever was cached before.
    func summary(for session: ClaudeSession) -> TranscriptSummary? {
        let url = Self.transcriptURL(for: session)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let cached = summaries[session.id]
        if let cached, let modified, cached.modified >= modified { return cached.summary }
        guard let modified, !loading.contains(session.id) else { return cached?.summary }
        loading.insert(session.id)
        let id = session.id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let summary = TranscriptSummary.read(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.loading.remove(id)
                    if let summary {
                        self.summaries[id] = (modified, summary)
                        self.onSummary?()
                    }
                }
            }
        }
        return cached?.summary
    }
}

extension JSONEncoder {
    static var withDates: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var withDates: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
