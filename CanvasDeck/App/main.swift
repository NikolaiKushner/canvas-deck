import AppKit

// Before anything starts a process: no variables of a parent Claude Code session.
InheritedEnvironment.scrub()
// Files, settings and sign-ins of the app's old name, once.
RenameMigration.run()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
