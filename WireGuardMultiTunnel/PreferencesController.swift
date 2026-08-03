import Cocoa

class Preferences: NSWindowController {
    @IBOutlet var launchAtLoginCheckbox: NSButton!

    var loginItemService: LoginItemControlling = LoginItemService()

    convenience init(loginItemService: LoginItemControlling) {
        self.init(windowNibName: NSNib.Name("PreferencesController"))
        self.loginItemService = loginItemService
    }

    override var windowNibName: String {
        return "PreferencesController"
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        syncLaunchAtLoginCheckbox()
    }

    /// make sure window is always brought to the front when it is opened
    override func showWindow(_: Any?) {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        syncLaunchAtLoginCheckbox()
    }

    /// close on ⌘-w (required because app has no menubar with close window action)
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.characters == "w" {
            window?.close()
        }
    }

    /// close on esc key
    @objc func cancel(_: Any?) {
        window?.close()
    }

    func syncLaunchAtLoginCheckbox() {
        guard launchAtLoginCheckbox != nil else { return }
        launchAtLoginCheckbox.isEnabled = loginItemService.isAvailable
        if loginItemService.isAvailable {
            launchAtLoginCheckbox.state = loginItemService.isEnabled ? .on : .off
            launchAtLoginCheckbox.toolTip = nil
        } else {
            launchAtLoginCheckbox.state = .off
            launchAtLoginCheckbox.toolTip = "Requires macOS 13 or later."
        }
    }

    @IBAction func launchAtLoginChanged(_ sender: NSButton) {
        do {
            try loginItemService.setEnabled(sender.state == .on)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to update start at login."
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        syncLaunchAtLoginCheckbox()
    }
}
