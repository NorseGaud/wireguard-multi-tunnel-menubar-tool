import Foundation

/// Orchestrates stealth wrapper lifecycle around wg-quick / Amnezia bring-up.
///
/// Packet path: WG → udp2raw → wstunnel → network
/// Start order: wstunnel → udp2raw → wg
/// Stop order: wg → udp2raw → wstunnel
///
/// Argv shapes (binaries not installed locally at impl time; verify against
/// `wstunnel --help` / `udp2raw --help` when available):
/// - wstunnel client: `client -L udp://127.0.0.1:<local>:<exitHost>:<exitPort> <serverURL>`
/// - udp2raw client: `-c -l 127.0.0.1:<local> -r <remoteHost>:<remotePort> -k <password> --raw-mode <mode>`
final class StealthOrchestrator {
    struct TunnelState: Codable {
        var tunnelName: String
        var aliasName: String
        var wstunnelPid: Int32?
        var udp2rawPid: Int32?
        var wstunnelLocalPort: UInt16?
        var udp2rawLocalPort: UInt16?
        var wgLocalPort: UInt16?
    }

    private let runner: StealthProcessRunning
    private let toolPaths: StealthToolPaths
    private let runDirectory: String
    /// Reserved for future Homebrew path resolution (toolPaths are injected today).
    let brewPrefix: String

    init(
        runner: StealthProcessRunning,
        toolPaths: StealthToolPaths,
        runDirectory: String,
        brewPrefix: String
    ) {
        self.runner = runner
        self.toolPaths = toolPaths
        self.runDirectory = runDirectory
        self.brewPrefix = brewPrefix
    }

    func bringUp(
        tunnelName: String,
        sourceConfigPath: String,
        profile: StealthProfile,
        useAmnezia: Bool,
        runWgQuick: (String) -> (Bool, String)
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
            aliasName: WireGuard.wgQuickInterfaceName(for: tunnelName)
        )

        do {
            try ensureRunDirectory()
            let localEndpoint = try startWrappersIfNeeded(
                profile: profile,
                configText: configText,
                state: &state,
                startedPids: &startedPids
            )
            let rewritten = try EphemeralConfig.rewrite(
                configText: configText,
                profile: profile,
                localEndpoint: localEndpoint
            )
            let ephemeralPath = ephemeralConfigPath(aliasName: state.aliasName)
            try rewritten.write(toFile: ephemeralPath, atomically: true, encoding: .utf8)
            try persistState(state)

            let (succeeded, message) = runWgQuick(ephemeralPath)
            if !succeeded {
                rollback(startedPids: startedPids.reversed(), state: state)
                return (false, message)
            }
            return (true, "")
        } catch {
            rollback(startedPids: startedPids.reversed(), state: state)
            return (false, "Stealth bring-up failed: \(error.localizedDescription)")
        }
    }

    func bringDown(
        tunnelName: String,
        runWgQuickDown: () -> (Bool, String)
    ) -> (Bool, String) {
        let state = loadState(tunnelName: tunnelName)
        let (succeeded, message) = runWgQuickDown()

        if let udp2rawPid = state?.udp2rawPid {
            runner.stop(pid: udp2rawPid)
        }
        if let wstunnelPid = state?.wstunnelPid {
            runner.stop(pid: wstunnelPid)
        }

        let aliasName = state?.aliasName ?? WireGuard.wgQuickInterfaceName(for: tunnelName)
        deleteRuntimeFiles(tunnelName: tunnelName, aliasName: aliasName)
        return (succeeded, message)
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
        let wstunnelPort = try allocatePort()
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
    }

    private func startUdp2raw(
        profile: StealthProfile,
        state: inout TunnelState,
        startedPids: inout [Int32]
    ) throws {
        let udp2rawPort = try allocatePort()
        state.udp2rawLocalPort = udp2rawPort
        let remoteHost: String
        let remotePort: UInt16
        if profile.wstunnel.enabled, let wstunnelPort = state.wstunnelLocalPort {
            // Next hop is local wstunnel (WG → udp2raw → wstunnel).
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
    }

    private func missingToolMessage(profile: StealthProfile, useAmnezia: Bool) -> String? {
        let needsAmnezia = useAmnezia || profile.amnezia.enabled
        if needsAmnezia, toolPaths.awgQuick == nil {
            return "awg-quick not installed"
        }
        // amneziaGo must exist alongside awg-quick for Amnezia bring-up (documented for callers).
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

    func allocatePort() throws -> UInt16 {
        let candidates = Array(1024 ... 65535).shuffled()
        for port in candidates {
            let socketFd = socket(AF_INET, SOCK_DGRAM, 0)
            guard socketFd >= 0 else { continue }
            defer { close(socketFd) }

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socketFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindResult == 0 {
                return UInt16(port)
            }
        }
        throw StealthOrchestratorError.portAllocationFailed
    }

    private func ensureRunDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: runDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func statePath(tunnelName: String) -> String {
        "\(runDirectory)/\(tunnelName).json"
    }

    private func ephemeralConfigPath(aliasName: String) -> String {
        "\(runDirectory)/\(aliasName).conf"
    }

    private func persistState(_ state: TunnelState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: URL(fileURLWithPath: statePath(tunnelName: state.tunnelName)), options: .atomic)
    }

    private func loadState(tunnelName: String) -> TunnelState? {
        let url = URL(fileURLWithPath: statePath(tunnelName: tunnelName))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TunnelState.self, from: data)
    }

    private func deleteRuntimeFiles(tunnelName: String, aliasName: String) {
        try? FileManager.default.removeItem(atPath: statePath(tunnelName: tunnelName))
        try? FileManager.default.removeItem(atPath: ephemeralConfigPath(aliasName: aliasName))
    }

    private func rollback(startedPids: [Int32], state: TunnelState) {
        for pid in startedPids {
            runner.stop(pid: pid)
        }
        deleteRuntimeFiles(tunnelName: state.tunnelName, aliasName: state.aliasName)
    }
}

enum StealthClientArgv {
    /// Documented reasonable client argv (erebe/wstunnel-style). Not verified against a local binary.
    static func wstunnel(
        localPort: UInt16,
        exitHost: String,
        exitPort: UInt16,
        profile: WsTunnelSettings
    ) -> [String] {
        var args = [
            "client",
            "-L",
            "udp://127.0.0.1:\(localPort):\(exitHost):\(exitPort)",
        ]
        if profile.tlsSkipVerify {
            args.append("--tls-skip-verify")
        }
        args.append(contentsOf: profile.extraArgs)
        args.append(profile.serverURL)
        return args
    }

    /// Documented reasonable client argv (udp2raw-tunnel-style). Not verified against a local binary.
    static func udp2raw(
        localPort: UInt16,
        remoteHost: String,
        remotePort: UInt16,
        profile: Udp2RawSettings
    ) -> [String] {
        var args = [
            "-c",
            "-l", "127.0.0.1:\(localPort)",
            "-r", "\(remoteHost):\(remotePort)",
            "-k", profile.password,
            "--raw-mode", profile.rawMode.rawValue,
        ]
        args.append(contentsOf: profile.extraArgs)
        return args
    }
}

enum StealthEndpointParser {
    static func parse(from configText: String) -> (host: String, port: UInt16)? {
        var inPeer = false
        for rawLine in configText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                inPeer = line.dropFirst().dropLast().lowercased() == "peer"
                continue
            }
            guard inPeer, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "endpoint" else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return parseHostPort(value)
        }
        return nil
    }

    private static func parseHostPort(_ value: String) -> (host: String, port: UInt16)? {
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex) ..< close])
            let rest = value[value.index(after: close)...]
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = value.lastIndex(of: ":") else { return nil }
        let host = String(value[..<colon])
        guard let port = UInt16(value[value.index(after: colon)...]), !host.isEmpty else { return nil }
        return (host, port)
    }
}

enum StealthOrchestratorError: Error, LocalizedError {
    case portAllocationFailed
    case missingPeerEndpoint
    case missingTool(String)

    var errorDescription: String? {
        switch self {
        case .portAllocationFailed:
            return "Unable to allocate a free localhost port"
        case .missingPeerEndpoint:
            return "Tunnel config missing Peer Endpoint"
        case let .missingTool(name):
            return "\(name) not installed"
        }
    }
}
