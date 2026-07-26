import Foundation

extension Helper {
    func currentStealthToolsStatus() -> StealthToolsStatus {
        let awgQuick = brewBinExecutable("awg-quick") != nil
        let amneziaGo = brewBinExecutable("amneziawg-go") != nil
        return StealthToolsStatus(
            amnezia: awgQuick && amneziaGo,
            udp2raw: brewBinExecutable("udp2raw") != nil,
            wstunnel: brewBinExecutable("wstunnel") != nil
        )
    }

    func brewBinExecutable(_ basename: String) -> String? {
        PathSecurity.validateExecutableBinaryPath(
            "\(brewPrefix)/bin/\(basename)",
            expectedBasename: basename
        )
    }

    func missingStealthToolMessage(for profile: StealthProfile) -> String? {
        let status = currentStealthToolsStatus()
        if profile.amnezia.enabled, !status.amnezia {
            if brewBinExecutable("awg-quick") == nil {
                return "awg-quick not installed"
            }
            return "amneziawg-go not installed"
        }
        if profile.wstunnel.enabled, !status.wstunnel {
            return "wstunnel not installed"
        }
        if profile.udp2raw.enabled, !status.udp2raw {
            return "udp2raw not installed"
        }
        return nil
    }

    func resolveStealthToolPaths() -> StealthToolPaths {
        StealthToolPaths(
            awgQuick: brewBinExecutable("awg-quick"),
            amneziaGo: brewBinExecutable("amneziawg-go"),
            udp2raw: brewBinExecutable("udp2raw"),
            wstunnel: brewBinExecutable("wstunnel")
        )
    }

    func makeStealthOrchestrator(toolPaths: StealthToolPaths? = nil) -> StealthOrchestrator {
        StealthOrchestrator(
            runner: RealStealthProcessRunner.shared,
            toolPaths: toolPaths ?? resolveStealthToolPaths(),
            runDirectory: stealthRunPath,
            brewPrefix: brewPrefix
        )
    }

    func quickBinPath(useAmnezia: Bool, toolPaths: StealthToolPaths) -> String {
        if useAmnezia, let awgQuick = toolPaths.awgQuick {
            return awgQuick
        }
        return wgquickBinPath
    }

    func bringStealthTunnelUp(tunnelName: String, profile: StealthProfile) -> (Bool, String) {
        if let missing = missingStealthToolMessage(for: profile) {
            return (false, missing)
        }
        guard let sourceConfigPath = wireguard.configFilePath(for: tunnelName) else {
            return (false, "Could not find configuration file for tunnel '\(tunnelName)'")
        }

        let toolPaths = resolveStealthToolPaths()
        let useAmnezia = profile.amnezia.enabled
        let quickBin = quickBinPath(useAmnezia: useAmnezia, toolPaths: toolPaths)
        let orchestrator = makeStealthOrchestrator(toolPaths: toolPaths)

        // If prior stealth state exists, tear it down with stored useAmnezia / ephemeral path
        // before re-up so a stale interface is not left orphaned when wrappers restart.
        if let stale = orchestrator.runtimeState(for: tunnelName) {
            NSLog("Clearing stale stealth state for \(tunnelName) before re-up")
            _ = tearDownStealthRuntime(
                tunnelName: tunnelName,
                state: stale,
                orchestrator: orchestrator
            )
        }

        let aliasName = WireGuard.wgQuickInterfaceName(for: tunnelName)
        NSLog("Set stealth tunnel \(tunnelName) up")
        return orchestrator.bringUp(
            tunnelName: tunnelName,
            sourceConfigPath: sourceConfigPath,
            profile: profile,
            useAmnezia: useAmnezia,
            runWgQuick: { ephemeralPath in
                self.wireguard.wgQuick(["up", ephemeralPath], quickBinPath: quickBin)
            },
            runWgQuickDown: {
                self.downEphemeralInterface(aliasName: aliasName, quickBinPath: quickBin)
            }
        )
    }

    func bringTunnelDown(tunnelName: String) -> (Bool, String) {
        let orchestrator = makeStealthOrchestrator()
        guard let state = orchestrator.runtimeState(for: tunnelName) else {
            NSLog("Set tunnel \(tunnelName) down")
            return wireguard.setTunnel(tunnelName: tunnelName, enable: false)
        }

        NSLog("Set stealth tunnel \(tunnelName) down")
        return tearDownStealthRuntime(tunnelName: tunnelName, state: state, orchestrator: orchestrator)
    }

    /// Orchestrator bringDown, then force interface down if still present (same as bringTunnelDown).
    func tearDownStealthRuntime(
        tunnelName: String,
        state: StealthOrchestrator.TunnelState,
        orchestrator: StealthOrchestrator
    ) -> (Bool, String) {
        let toolPaths = resolveStealthToolPaths()
        let useAmnezia = state.useAmnezia ?? false
        let quickBin = quickBinPath(useAmnezia: useAmnezia, toolPaths: toolPaths)
        let (success, errorMessage) = orchestrator.bringDown(tunnelName: tunnelName) {
            self.downEphemeralInterface(aliasName: state.aliasName, quickBinPath: quickBin)
        }
        if !wireguard.interfaceName(tunnelName).isEmpty {
            _ = wireguard.setTunnel(tunnelName: tunnelName, enable: false, quickBinPath: quickBin)
        }
        return (success, errorMessage)
    }

    func downEphemeralInterface(aliasName: String, quickBinPath: String) -> (Bool, String) {
        let ephemeralPath = "\(stealthRunPath)/\(aliasName).conf"
        if FileManager.default.fileExists(atPath: ephemeralPath) {
            return wireguard.wgQuick(["down", ephemeralPath], quickBinPath: quickBinPath)
        }
        return wireguard.wgQuick(["down", aliasName], quickBinPath: quickBinPath)
    }

    func shutdownConnectedTunnelsClearingStealth() {
        let orchestrator = makeStealthOrchestrator()
        wireguard.shutdownConnectedTunnels { tunnelName in
            guard let state = orchestrator.runtimeState(for: tunnelName) else { return nil }
            NSLog("Shutting down stealth tunnel '\(tunnelName)' on app quit")
            return self.tearDownStealthRuntime(
                tunnelName: tunnelName,
                state: state,
                orchestrator: orchestrator
            )
        }
        clearOrphanedStealthStacks(orchestrator: orchestrator)
    }

    func clearOrphanedStealthStacks(orchestrator: StealthOrchestrator) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: stealthRunPath) else { return }
        for fileName in contents where fileName.hasSuffix(".json") {
            let tunnelName = String(fileName.dropLast(5))
            guard WireGuard.validateTunnelName(tunnelName: tunnelName),
                  let state = orchestrator.runtimeState(for: tunnelName)
            else { continue }
            NSLog("Clearing orphaned stealth stack '\(tunnelName)' on app quit")
            _ = tearDownStealthRuntime(
                tunnelName: tunnelName,
                state: state,
                orchestrator: orchestrator
            )
        }
    }
}
