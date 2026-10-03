import Foundation

/// The app was called Canvas Station before it went public. Once, at the
/// first launch as Canvas Deck, its files and settings move over. The Linear
/// sign-in does not: a Keychain item belongs to the app that saved it, so
/// Linear asks to sign in once more.
enum RenameMigration {
    private static let oldBundleID = "app.canvasstation.CanvasStation"
    private static let doneKey = "migratedFromCanvasStation"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        moveFiles()
        copySettings(into: defaults)
        defaults.set(true, forKey: doneKey)
    }

    private static func moveFiles() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appending(path: "CanvasStation", directoryHint: .isDirectory)
        let new = support.appending(path: "CanvasDeck", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: new.path) else { return }
        try? FileManager.default.moveItem(at: old, to: new)
    }

    private static func copySettings(into defaults: UserDefaults) {
        guard let old = defaults.persistentDomain(forName: oldBundleID) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
