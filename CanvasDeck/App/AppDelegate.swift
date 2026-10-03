import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let canvas = CanvasController()
    private var settingsWindow: NSWindow?
    private var settings: SettingsModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        ShellIntegration.install()
        GlobalStatusline.repairIfNeeded(helper: TerminalNode.notifyPath)
        NSApp.mainMenu = makeMainMenu()
        // Signed in before: restore the Linear connection and its issues.
        _ = LinearConnection.shared
        canvas.show()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        canvas.saveNow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        canvas.show()
        return true
    }

    @objc private func openSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsModel() }
        guard let settings else { return }
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: settings))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Canvas Deck", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Canvas Deck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Standard edit commands, sent to whatever has focus: the terminal
        // (SwiftTerm implements copy:, paste:, selectAll:) or a text field.
        // Without this menu ⌘C / ⌘V / ⌘A reached nothing.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(command("Zoom In", action: #selector(CanvasController.zoomIn(_:)), key: "=", modifiers: .command))
        viewMenu.addItem(command("Zoom Out", action: #selector(CanvasController.zoomOut(_:)), key: "-", modifiers: .command))
        viewMenu.addItem(.separator())
        viewMenu.addItem(command("100%", action: #selector(CanvasController.actualSize(_:)), key: "0", modifiers: .shift))
        viewMenu.addItem(command("Fit All", action: #selector(CanvasController.fitAll(_:)), key: "1", modifiers: .shift))
        viewMenu.addItem(command("Zoom to Card", action: #selector(CanvasController.zoomToNode(_:)), key: "2", modifiers: .shift))
        viewMenu.addItem(.separator())
        viewMenu.addItem(command("Go to…", action: #selector(CanvasController.showJumpPalette(_:)), key: "k", modifiers: .command))
        viewMenu.addItem(command("Next Waiting Agent", action: #selector(CanvasController.nextWaitingAgent(_:)), key: "j", modifiers: .command))
        viewItem.submenu = viewMenu

        let sessionsItem = NSMenuItem()
        main.addItem(sessionsItem)
        let sessionsMenu = NSMenu(title: "Sessions")
        // Filled by the canvas each time it opens.
        sessionsMenu.delegate = canvas
        sessionsItem.submenu = sessionsMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu

        return main
    }

    private func command(_ title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = canvas
        return item
    }
}
