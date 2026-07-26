//

import Cocoa

class Preferences: NSWindowController {
    private var didBuildTabs = false
    private var stealthView: StealthPreferencesView?

    override var windowNibName: String {
        return "PreferencesController"
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        buildTabbedContentIfNeeded()
    }

    /// make sure window is always brought to the front when it is opened
    override func showWindow(_: Any?) {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        buildTabbedContentIfNeeded()
        refreshStealthTab()
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

    // MARK: - Tab construction

    private func buildTabbedContentIfNeeded() {
        guard !didBuildTabs, let window = window, let contentView = window.contentView else { return }
        didBuildTabs = true

        let generalViews = contentView.subviews
        let generalContainer = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 120))
        for view in generalViews {
            view.removeFromSuperview()
            var frame = view.frame
            frame.origin.y += 12
            frame.origin.x += 8
            view.frame = frame
            generalContainer.addSubview(view)
        }

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let generalItem = NSTabViewItem(identifier: "general")
        generalItem.label = "General"
        generalItem.view = generalContainer

        let stealth = StealthPreferencesView(frame: .zero)
        stealth.store = appDelegate?.stealthStore
        stealth.tunnelNamesProvider = { [weak self] in
            self?.appDelegate?.tunnels.map(\.name).sorted() ?? []
        }
        stealth.toolsStatusProvider = { [weak self] reply in
            self?.fetchStealthToolsStatus(reply: reply)
        }
        stealthView = stealth

        let stealthItem = NSTabViewItem(identifier: "stealth")
        stealthItem.label = "Stealth"
        stealthItem.view = stealth

        tabView.addTabViewItem(generalItem)
        tabView.addTabViewItem(stealthItem)

        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])

        var frame = window.frame
        frame.size = NSSize(width: 560, height: 520)
        window.setFrame(frame, display: true)
        window.minSize = NSSize(width: 480, height: 360)
        window.styleMask.insert(.resizable)
    }

    private func refreshStealthTab() {
        stealthView?.store = appDelegate?.stealthStore
        stealthView?.reload()
    }

    private var appDelegate: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    private func fetchStealthToolsStatus(reply: @escaping (String) -> Void) {
        let xpcService = appDelegate?.privilegedHelper?.helperConnection()?.remoteObjectProxyWithErrorHandler { error in
            NSLog("XPCService error: \(error)")
            reply("")
        } as? HelperProtocol

        guard let xpcService else {
            reply("")
            return
        }
        xpcService.stealthToolsStatus(reply)
    }
}
