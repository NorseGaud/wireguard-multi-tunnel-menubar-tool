import Cocoa

extension AppDelegate {
    @objc func tunnelMenuSwitchChanged(_ sender: TunnelMenuSwitch) {
        let tunnelName = sender.tunnelName
        guard !tunnelName.isEmpty else { return }

        switch sender.controlKind {
        case "enabled":
            setTunnelEnabled(tunnelName, enabling: sender.state == .on)
        default:
            NSLog("Unknown menu switch kind: \(sender.controlKind)")
        }
    }

    @objc func disableAllTunnels(_: Any?) {
        for tunnel in tunnels where tunnel.connected || pendingTunnelOperations[tunnel.name] == true {
            setTunnelEnabled(tunnel.name, enabling: false)
        }
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(disableAllTunnels(_:)) {
            return shouldEnableDisableAll(tunnels: tunnels, pending: pendingTunnelOperations)
        }
        return true
    }

    func setTunnelEnabled(_ tunnelName: String, enabling: Bool) {
        pendingTunnelOperations[tunnelName] = enabling
        refreshStatusBarAppearance()
        // menu.update() does not reliably replace custom views while the menu is open.
        syncOpenMenuForTunnel(tunnelName)

        helperProxy()?.setTunnel(tunnelName: tunnelName, enable: enabling) { success, errorMessage in
            NSLog("setTunnel \(tunnelName), to: \(enabling), success: \(success), error: \(errorMessage)")
            DispatchQueue.main.async {
                if !success {
                    self.pendingTunnelOperations.removeValue(forKey: tunnelName)
                    self.refreshStatusBarAppearance()
                    self.syncOpenMenuForTunnel(tunnelName)
                    self.rebuildStatusMenuIfAllowed()
                    self.notifyError(errorMessage)
                }
            }
        }
    }

    /// Update title/switch custom views in the already-open status menu.
    func syncOpenMenuForTunnel(_ tunnelName: String) {
        let connected = tunnels.first(where: { $0.name == tunnelName })?.connected ?? false
        syncOpenMenuTunnelAppearance(
            in: menu,
            tunnelName: tunnelName,
            connected: connected,
            pendingTarget: pendingTunnelOperations[tunnelName]
        )
    }

    func syncOpenMenuForAllTunnels() {
        for tunnel in tunnels {
            syncOpenMenuForTunnel(tunnel.name)
        }
    }

    func helperProxy() -> HelperProtocol? {
        privilegedHelper?.helperConnection()?.remoteObjectProxyWithErrorHandler { error in
            NSLog("XPCService error: \(error)")
        } as? HelperProtocol
    }
}

private let aboutPanelRepositoryURL = "https://github.com/NorseGaud/macos-menubar-wireguard"
private let aboutPanelUpstreamURL = "https://github.com/aequitas/macos-menubar-wireguard"
private let aboutPanelWireGuardURL = "https://www.wireguard.com/"

func aboutPanelCredits() -> NSAttributedString {
    let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let baseAttributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]

    let credits = NSMutableAttributedString()
    var isFirstLine = true

    func appendLine() {
        guard !isFirstLine else {
            isFirstLine = false
            return
        }
        credits.append(NSAttributedString(string: "\n", attributes: baseAttributes))
    }

    func appendText(_ text: String, link: String? = nil) {
        appendLine()
        var attributes = baseAttributes
        if let link {
            attributes[.link] = link
        }
        credits.append(NSAttributedString(string: text, attributes: attributes))
    }

    appendText(aboutPanelRepositoryURL, link: aboutPanelRepositoryURL)
    appendLine()
    credits.append(NSAttributedString(string: "Forked from ", attributes: baseAttributes))
    credits.append(NSAttributedString(
        string: aboutPanelUpstreamURL,
        attributes: baseAttributes.merging([.link: aboutPanelUpstreamURL]) { _, new in new }
    ))
    appendText(aboutPanelWireGuardURL, link: aboutPanelWireGuardURL)

    return credits
}
