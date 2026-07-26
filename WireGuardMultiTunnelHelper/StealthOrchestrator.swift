import Foundation

/// Orchestrates stealth wrapper lifecycle around wg-quick / Amnezia bring-up.
///
/// Packet path: WG → udp2raw → wstunnel → network
/// Start order: wstunnel → udp2raw → wg
/// Stop order: wg → udp2raw → wstunnel
///
/// After each wrapper start, polls process liveness (`kill(pid, 0)`) and local UDP
/// port readiness (bind probe: EADDRINUSE ⇒ in use) for up to `readinessTimeout`.
/// Immediately before `runWgQuick`, re-checks that wrapper pids are still alive.
///
/// Argv shapes (erebe/wstunnel v9+ / udp2raw-tunnel; verify against installed `--help`):
/// - wstunnel: `client -L udp://127.0.0.1:<local>:<exitHost>:<exitPort> [--tls-verify-certificate] <serverURL>`
/// - udp2raw: `-c -l 127.0.0.1:<local> -r <remoteHost>:<remotePort> -k <password> --raw-mode <mode>`
final class StealthOrchestrator {
    struct TunnelState: Codable {
        var tunnelName: String
        var aliasName: String
        var wstunnelPid: Int32?
        var udp2rawPid: Int32?
        var wstunnelLocalPort: UInt16?
        var udp2rawLocalPort: UInt16?
        var wgLocalPort: UInt16?
        /// Whether bring-up used awg-quick (Amnezia). Absent in older state files ⇒ nil/false.
        var useAmnezia: Bool?
    }

    private let runner: StealthProcessRunning
    private let toolPaths: StealthToolPaths
    private let store: StealthRuntimeStore
    /// Reserved for future Homebrew path resolution (toolPaths are injected today).
    let brewPrefix: String
    private let readinessTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let isPortReady: (UInt16) -> Bool

    init(
        runner: StealthProcessRunning,
        toolPaths: StealthToolPaths,
        runDirectory: String,
        brewPrefix: String,
        readinessTimeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.05,
        isPortReady: ((UInt16) -> Bool)? = nil
    ) {
        self.runner = runner
        self.toolPaths = toolPaths
        store = StealthRuntimeStore(runDirectory: runDirectory)
        self.brewPrefix = brewPrefix
        self.readinessTimeout = readinessTimeout
        self.pollInterval = pollInterval
        self.isPortReady = isPortReady ?? StealthLocalUdp.isPortInUse
    }

    func bringUp(
        tunnelName: String,
        sourceConfigPath: String,
        profile: StealthProfile,
        useAmnezia: Bool,
        runWgQuick: (String) -> (Bool, String),
        runWgQuickDown: (() -> (Bool, String))? = nil
    ) -> (Bool, String) {
        do {
            try profile.validate()
        } catch {
            return (false, "Invalid stealth profile: \(error)")
        }

        if let missing = missingToolMessage(profile: profile, useAmnezia: useAmnezia) {
            return (false, missing)
        }

        guard let configText = try? String(contentsOfFile: sourceConfigPath, encoding: .utf8) else {
            return (false, "Unable to read tunnel config")
        }

        var startedPids: [Int32] = []
        var state = TunnelState(
            tunnelName: tunnelName,
            aliasName: WireGuard.wgQuickInterfaceName(for: tunnelName),
            useAmnezia: useAmnezia || profile.amnezia.enabled
        )

        do {
            try store.ensureRunDirectory()
            cleanupStaleStateIfNeeded(tunnelName: tunnelName, runWgQuickDown: runWgQuickDown)

            let localEndpoint = try startWrappersIfNeeded(
                profile: profile,
                configText: configText,
                state: &state,
                startedPids: &startedPids
            )
            try assertWrappersAlive(state: state)

            let rewritten = try EphemeralConfig.rewrite(
                configText: configText,
                profile: profile,
                localEndpoint: localEndpoint
            )
            let ephemeralPath = store.ephemeralConfigPath(aliasName: state.aliasName)
            try rewritten.write(toFile: ephemeralPath, atomically: true, encoding: .utf8)
            try store.persist(state)

            let (succeeded, message) = runWgQuick(ephemeralPath)
            if !succeeded {
                _ = runWgQuickDown?()
                rollback(startedPids: startedPids.reversed(), state: state)
                return (false, message)
            }
            return (true, "")
        } catch {
            rollback(startedPids: startedPids.reversed(), state: state)
            return (false, "Stealth bring-up failed: \(error.localizedDescription)")
        }
    }

    func runtimeState(for tunnelName: String) -> TunnelState? {
        store.load(tunnelName: tunnelName)
    }

    func bringDown(
        tunnelName: String,
        runWgQuickDown: () -> (Bool, String)
    ) -> (Bool, String) {
        let state = store.load(tunnelName: tunnelName)
        let (succeeded, message) = runWgQuickDown()

        if let udp2rawPid = state?.udp2rawPid {
            runner.stop(pid: udp2rawPid)
        }
        if let wstunnelPid = state?.wstunnelPid {
            runner.stop(pid: wstunnelPid)
        }

        let aliasName = state?.aliasName ?? WireGuard.wgQuickInterfaceName(for: tunnelName)
        store.deleteRuntimeFiles(tunnelName: tunnelName, aliasName: aliasName)
        return (succeeded, message)
    }

    private func cleanupStaleStateIfNeeded(
        tunnelName: String,
        runWgQuickDown: (() -> (Bool, String))?
    ) {
        guard let stale = store.load(tunnelName: tunnelName) else { return }
        // Best-effort down of prior interface before restarting wrappers (avoids orphan utun).
        _ = runWgQuickDown?()
        if let udp2rawPid = stale.udp2rawPid {
            runner.stop(pid: udp2rawPid)
        }
        if let wstunnelPid = stale.wstunnelPid {
            runner.stop(pid: wstunnelPid)
        }
        store.deleteRuntimeFiles(tunnelName: stale.tunnelName, aliasName: stale.aliasName)
    }

    private func startWrappersIfNeeded(
        profile: StealthProfile,
        configText: String,
        state: inout TunnelState,
        startedPids: inout [Int32]
    ) throws -> String? {
        guard profile.wstunnel.enabled || profile.udp2raw.enabled else { return nil }
        guard let endpoint = StealthEndpointParser.parse(from: configText) else {
            throw StealthOrchestratorError.missingPeerEndpoint
        }

        if profile.wstunnel.enabled {
            try startWstunnel(profile: profile, endpoint: endpoint, state: &state, startedPids: &startedPids)
        }
        if profile.udp2raw.enabled {
            try startUdp2raw(profile: profile, state: &state, startedPids: &startedPids)
        }

        let wgPort = profile.udp2raw.enabled ? state.udp2rawLocalPort! : state.wstunnelLocalPort!
        state.wgLocalPort = wgPort
        return "127.0.0.1:\(wgPort)"
    }

    private func startWstunnel(
        profile: StealthProfile,
        endpoint: (host: String, port: UInt16),
        state: inout TunnelState,
        startedPids: inout [Int32]
    ) throws {
        let wstunnelPort = try StealthLocalUdp.allocatePort()
        state.wstunnelLocalPort = wstunnelPort
        let exitHost = profile.udp2raw.enabled ? profile.udp2raw.remoteHost : endpoint.host
        let exitPort = profile.udp2raw.enabled ? profile.udp2raw.remotePort : endpoint.port
        let args = StealthClientArgv.wstunnel(
            localPort: wstunnelPort,
            exitHost: exitHost,
            exitPort: exitPort,
            profile: profile.wstunnel
        )
        guard let executable = toolPaths.wstunnel else {
            throw StealthOrchestratorError.missingTool("wstunnel")
        }
        let pid = try runner.start(executable: executable, arguments: args)
        startedPids.append(pid)
        state.wstunnelPid = pid
        try waitForListenerReady(pid: pid, port: wstunnelPort)
    }

    private func startUdp2raw(
        profile: StealthProfile,
        state: inout TunnelState,
        startedPids: inout [Int32]
    ) throws {
        let udp2rawPort = try StealthLocalUdp.allocatePort()
        state.udp2rawLocalPort = udp2rawPort
        let remoteHost: String
        let remotePort: UInt16
        if profile.wstunnel.enabled, let wstunnelPort = state.wstunnelLocalPort {
            remoteHost = "127.0.0.1"
            remotePort = wstunnelPort
        } else {
            remoteHost = profile.udp2raw.remoteHost
            remotePort = profile.udp2raw.remotePort
        }
        let args = StealthClientArgv.udp2raw(
            localPort: udp2rawPort,
            remoteHost: remoteHost,
            remotePort: remotePort,
            profile: profile.udp2raw
        )
        guard let executable = toolPaths.udp2raw else {
            throw StealthOrchestratorError.missingTool("udp2raw")
        }
        let pid = try runner.start(executable: executable, arguments: args)
        startedPids.append(pid)
        state.udp2rawPid = pid
        try waitForListenerReady(pid: pid, port: udp2rawPort)
    }

    private func waitForListenerReady(pid: Int32, port: UInt16) throws {
        let deadline = Date().addingTimeInterval(readinessTimeout)
        while Date() < deadline {
            guard runner.isAlive(pid: pid) else {
                throw StealthOrchestratorError.wrapperExited
            }
            if isPortReady(port) {
                return
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        guard runner.isAlive(pid: pid) else {
            throw StealthOrchestratorError.wrapperExited
        }
        guard isPortReady(port) else {
            throw StealthOrchestratorError.wrapperNotReady
        }
    }

    private func assertWrappersAlive(state: TunnelState) throws {
        if let pid = state.wstunnelPid, !runner.isAlive(pid: pid) {
            throw StealthOrchestratorError.wrapperExited
        }
        if let pid = state.udp2rawPid, !runner.isAlive(pid: pid) {
            throw StealthOrchestratorError.wrapperExited
        }
    }

    private func missingToolMessage(profile: StealthProfile, useAmnezia: Bool) -> String? {
        let needsAmnezia = useAmnezia || profile.amnezia.enabled
        if needsAmnezia, toolPaths.awgQuick == nil {
            return "awg-quick not installed"
        }
        if needsAmnezia, toolPaths.amneziaGo == nil {
            return "amneziawg-go not installed"
        }
        if profile.wstunnel.enabled, toolPaths.wstunnel == nil {
            return "wstunnel not installed"
        }
        if profile.udp2raw.enabled, toolPaths.udp2raw == nil {
            return "udp2raw not installed"
        }
        return nil
    }

    private func rollback(startedPids: [Int32], state: TunnelState) {
        for pid in startedPids {
            runner.stop(pid: pid)
        }
        store.deleteRuntimeFiles(tunnelName: state.tunnelName, aliasName: state.aliasName)
    }
}
