// Main Application logic and UI glue

import Cocoa

// make logging in debug more compact (no timestamp/process name/pid)
#if DEBUG
    let NSLog = customLog
    public func customLog(_ format: String, _ args: CVarArg...) {
        withVaList(args) { print(NSString(format: format, arguments: $0)) }
    }
#endif

extension NSImage.Name {
    static let connected = "silhouette"
    static let enabled = "silhouette-dim"
    static let disabled = "dragon"
    static let appInit = "dragon-dim"
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSUserNotificationCenterDelegate, AppProtocol {
    let defaults: UserDefaults = NSUserDefaultsController.shared.defaults

    /// keep the existence and state of all tunnel(configuration)s
    var tunnels = Tunnels()

    @objc dynamic var wireguardInstalled = false

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    @IBOutlet var menu: NSMenu!

    /// Companion-file stealth profiles keyed by tunnel name (from helper).
    var stealthProfiles: [String: StealthProfile] = [:]

    var privilegedHelper: HelperXPC?

    /// Tunnel name → target enabled state while wg-quick is running.
    var pendingTunnelOperations: PendingTunnelOperations = [:]

    private var statusBarSpinner: NSProgressIndicator?
    private var isUpdatingTunnelMenu = false

    func applicationDidFinishLaunching(_: Notification) {
        // set default preferences
        defaults.register(defaults: DefaultSettings.App)

        #if DEBUG
            // reset preferences to defaults for UI testing
            if ProcessInfo.processInfo.environment["RESET_CONFIGURATION"] == "1" {
                defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
            }
        #endif

        // set a default icon at startup
        statusItem.image = NSImage(named: .appInit)!
        statusItem.image!.isTemplate = true

        // configure menu to use and set delegate to allow overriding menu option modifier behaviour
        statusItem.menu = menu
        menu.minimumWidth = 260

        // initialize helper XPC connection
        privilegedHelper = HelperXPC(exportedObject: self)

        // install the Helper or Update it if needed
        privilegedHelper!.installOrUpdateHelper(
            // if installation failed alert user
            onFailure: alertHelperFailure,
            // if helper is up to date, installed or updated, get initial tunnel state
            onSuccess: connectedToHelper
        )
    }

    /// notify user of failed helper install
    func alertHelperFailure(message: String?) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Failed to install or update Privileged Helper."
            alert.informativeText = message ?? ""
            alert.runModal()
        }
    }

    @objc func menuNeedsUpdate(_ menu: NSMenu) {
        guard !isUpdatingTunnelMenu else { return }
        isUpdatingTunnelMenu = true
        defer { isUpdatingTunnelMenu = false }

        // show details if menu is invoked while pressing down option key
        let optionModifier = NSApp.currentEvent!.modifierFlags.contains(.option)
        let showAllTunnelDetails = defaults.bool(forKey: "showAllTunnelDetails")
        let showDetails = optionModifier || showAllTunnelDetails
        let showConnected = defaults.bool(forKey: "showConnectedTunnelDetails")

        // remove dynamic tunnel items, disable-all header, and the xib placeholder
        for tag in [
            MenuItemTypes.tunnel.rawValue,
            MenuItemTypes.tunnelplaceholder.rawValue,
            MenuItemTypes.disableAll.rawValue,
            MenuItemTypes.disableAllSeparator.rawValue,
        ] {
            while let item = menu.item(withTag: tag) {
                menu.removeItem(item)
            }
        }

        let menuWidth = tunnelMenuRowWidth(in: menu)

        // generate new tunnel and tunnel details menu items and add them to the menu
        var menuOptions = MenuBuildOptions()
        menuOptions.menuItemWidth = menuWidth
        menuOptions.pendingTunnels = pendingTunnelOperations
        menuOptions.stealthProfiles = stealthProfiles
        menuOptions.switchTarget = self
        menuOptions.switchAction = #selector(tunnelMenuSwitchChanged(_:))
        menuOptions.allTunnelDetails = showDetails
        menuOptions.connectedTunnelDetails = showConnected
        let tunnelMenuItems = buildMenu(tunnels: tunnels, options: menuOptions)
        for item in tunnelMenuItems.reversed() {
            item.tag = MenuItemTypes.tunnel.rawValue
            menu.insertItem(item, at: 0)
        }

        let disableAllItems = buildDisableAllMenuItems(
            tunnels: tunnels,
            pending: pendingTunnelOperations,
            target: self,
            action: #selector(disableAllTunnels(_:))
        )
        for item in disableAllItems.reversed() {
            menu.insertItem(item, at: 0)
        }
        resizeTunnelMenuItemViews(in: menu)
    }

    /// Perform initialization after first connection with helper
    func connectedToHelper() {
        validateHelper()
        updateState()
    }

    /// Query the Helper to ensure it is properly initialized (eg: wg-quick is available)
    func validateHelper() {
        let xpcService = privilegedHelper?.helperConnection()?.remoteObjectProxyWithErrorHandler { error in
            NSLog("XPCService error: \(error)")
        } as? HelperProtocol

        xpcService?.wireguardInstalled { self.wireguardInstalled = $0 }
    }

    /// query the Helper for all current tunnels configuration and runtime state, update menu icon
    func updateState() {
        NSLog("Updating tunnel configuration and runtime state.")

        let xpcService = privilegedHelper?.helperConnection()?.remoteObjectProxyWithErrorHandler { error in
            NSLog("XPCService error: \(error)")
        } as? HelperProtocol

        xpcService?.getTunnels(reply: { tunnelInfo in
            self.tunnels = tunnelInfo.map { name, interfaceAndConfigData in
                Tunnel(name: name, fromTunnelInfo: interfaceAndConfigData)
            }
            xpcService?.getStealthProfiles { json in
                self.stealthProfiles = Self.parseStealthProfilesJSON(json)
                DispatchQueue.main.async { self.applyTunnelStateUpdate() }
            }
        })
    }

    private static func parseStealthProfilesJSON(_ json: String) -> [String: StealthProfile] {
        guard let data = json.data(using: .utf8),
              let profiles = try? JSONDecoder().decode([String: StealthProfile].self, from: data)
        else {
            return [:]
        }
        return profiles
    }

    func applyTunnelStateUpdate() {
        resolvePendingTunnelOperations(&pendingTunnelOperations, tunnels: tunnels)
        refreshStatusBarAppearance()
        // Prefer in-place sync while the menu may still be open.
        syncOpenMenuForAllTunnels()
        menu.update()
    }

    func refreshStatusBarAppearance() {
        if pendingTunnelOperations.isEmpty {
            hideStatusBarSpinner()
            statusItem.image = menuImage(tunnels: tunnels)
        } else {
            statusItem.image = nil
            showStatusBarSpinner()
        }
    }

    private func showStatusBarSpinner() {
        guard let button = statusItem.button else { return }

        if statusBarSpinner == nil {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
            statusBarSpinner = spinner
        }
        statusBarSpinner?.startAnimation(nil)
    }

    private func hideStatusBarSpinner() {
        statusBarSpinner?.stopAnimation(nil)
        statusBarSpinner?.removeFromSuperview()
        statusBarSpinner = nil
    }

    /// Use notificationcenter banner to inform user of failed tunnel command
    func notifyError(_ errorMessage: String) {
        let notification = NSUserNotification()
        notification.title = "Failed to change tunnel state!"
        if errorMessage.split(separator: "\n").count == 1 {
            notification.informativeText = errorMessage
            notification.hasActionButton = false
        }
        notification.userInfo = ["message": errorMessage]
        let center = NSUserNotificationCenter.default
        center.delegate = self
        center.scheduleNotification(notification)
    }

    /// Make sure notifications are always show, even when the application is running in the foreground
    func userNotificationCenter(_: NSUserNotificationCenter, shouldPresent _: NSUserNotification) -> Bool {
        return true
    }

    /// Handle user clicking on the "Show" button
    func userNotificationCenter(_: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        switch notification.activationType {
        case .actionButtonClicked:
            let message = notification.userInfo?["message"] as? String ?? "InternalError: failed to get error message."
            let alert = NSAlert()
            alert.messageText = "Failed to change tunnel state!"
            alert.informativeText = message
            alert.runModal()
        default:
            break
        }
    }

    @IBAction func showInstallInstructions(_: Any) {
        let alert = NSAlert()
        alert.messageText = "WireGuard is not installed!"
        alert.informativeText = installInstructions
        alert.runModal()
    }

    @IBAction func about(_: Any) {
        let bundle = Bundle.main
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "WireGuardMultiTunnel",
            .applicationVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            .credits: aboutPanelCredits(),
        ]
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var preferences: NSWindowController?
    @IBAction func preferences(_: Any) {
        if preferences == nil {
            preferences = Preferences()
        }
        preferences!.showWindow(nil)
    }

    @IBAction func quit(_: Any) {
        NSApplication.shared.terminate(self)
    }

    func applicationWillTerminate(_: Notification) {
        // Connected tunnels are shut down by the privileged helper when this XPC connection closes.
    }
}
