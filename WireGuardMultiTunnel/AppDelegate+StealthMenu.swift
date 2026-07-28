import Cocoa

extension AppDelegate {
    @objc func tunnelMenuSwitchChanged(_ sender: TunnelMenuSwitch) {
        let tunnelName = sender.tunnelName
        guard !tunnelName.isEmpty else { return }

        switch sender.controlKind {
        case "enabled":
            setTunnelEnabled(tunnelName, enabling: sender.state == .on)
        case "amnezia", "udp2raw", "wstunnel":
            setStealthLayer(tunnelName, kind: sender.controlKind, enabled: sender.state == .on, switchControl: sender)
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

        let profile = stealthProfiles[tunnelName] ?? StealthProfile()
        let json = (try? profile.jsonString()) ?? ""
        helperProxy()?.setTunnel(
            tunnelName: tunnelName,
            enable: enabling,
            stealthProfileJSON: json,
            reply: { success, errorMessage in
                NSLog("setTunnel \(tunnelName), to: \(enabling), success: \(success), error: \(errorMessage)")
                DispatchQueue.main.async {
                    if !success {
                        self.pendingTunnelOperations.removeValue(forKey: tunnelName)
                        self.refreshStatusBarAppearance()
                        self.syncOpenMenuForTunnel(tunnelName)
                        self.menu.update()
                        self.notifyError(errorMessage)
                    }
                }
            }
        )
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

    func setStealthLayer(_ tunnelName: String, kind: String, enabled: Bool, switchControl: TunnelMenuSwitch) {
        var profile = stealthProfiles[tunnelName] ?? StealthProfile()
        switch kind {
        case "amnezia": profile.amnezia.enabled = enabled
        case "udp2raw": profile.udp2raw.enabled = enabled
        case "wstunnel": profile.wstunnel.enabled = enabled
        default: return
        }

        do {
            try profile.validate()
        } catch {
            switchControl.state = enabled ? .off : .on
            notifyError(stealthValidationMessage(error))
            return
        }

        guard let json = try? profile.jsonString() else {
            switchControl.state = enabled ? .off : .on
            notifyError("Failed to encode stealth profile")
            return
        }

        helperProxy()?.setStealthProfile(tunnelName: tunnelName, stealthProfileJSON: json) { success, errorMessage in
            DispatchQueue.main.async {
                guard success else {
                    switchControl.state = enabled ? .off : .on
                    self.notifyError(errorMessage)
                    return
                }
                self.stealthProfiles[tunnelName] = profile
                if let tunnel = self.tunnels.first(where: { $0.name == tunnelName }), tunnel.connected {
                    self.reconnectTunnel(tunnelName)
                } else {
                    self.syncOpenMenuForTunnel(tunnelName)
                    self.menu.update()
                }
            }
        }
    }

    func reconnectTunnel(_ tunnelName: String) {
        pendingTunnelOperations[tunnelName] = true
        refreshStatusBarAppearance()
        syncOpenMenuForTunnel(tunnelName)

        let profile = stealthProfiles[tunnelName] ?? StealthProfile()
        let json = (try? profile.jsonString()) ?? ""
        let proxy = helperProxy()
        proxy?.setTunnel(tunnelName: tunnelName, enable: false, stealthProfileJSON: "") { downOK, downError in
            if !downOK {
                DispatchQueue.main.async {
                    self.pendingTunnelOperations.removeValue(forKey: tunnelName)
                    self.refreshStatusBarAppearance()
                    self.syncOpenMenuForTunnel(tunnelName)
                    self.menu.update()
                    self.notifyError(downError)
                }
                return
            }
            proxy?.setTunnel(tunnelName: tunnelName, enable: true, stealthProfileJSON: json) { upOK, upError in
                DispatchQueue.main.async {
                    if !upOK {
                        self.pendingTunnelOperations.removeValue(forKey: tunnelName)
                        self.refreshStatusBarAppearance()
                        self.syncOpenMenuForTunnel(tunnelName)
                        self.menu.update()
                        self.notifyError(upError)
                    }
                }
            }
        }
    }

    func helperProxy() -> HelperProtocol? {
        privilegedHelper?.helperConnection()?.remoteObjectProxyWithErrorHandler { error in
            NSLog("XPCService error: \(error)")
        } as? HelperProtocol
    }

    func stealthValidationMessage(_ error: Error) -> String {
        if let stealthError = error as? StealthValidationError {
            switch stealthError {
            case .incompleteUdp2Raw:
                return "udp2raw needs host/port/password in <tunnel>.stealth.json"
            case .incompleteWsTunnel:
                return "wstunnel needs a ws:// or wss:// URL in <tunnel>.stealth.json"
            case .invalidAmneziaParams:
                return "Invalid Amnezia settings"
            case .extraArgsNotSupported:
                return "extraArgs are not supported in v1"
            case .invalidJSON, .invalidExtraArgs:
                return "Invalid stealth profile"
            }
        }
        return "Invalid stealth profile: \(error)"
    }
}
