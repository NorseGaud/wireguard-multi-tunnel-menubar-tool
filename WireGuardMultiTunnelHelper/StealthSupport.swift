import Foundation

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

enum StealthLocalUdp {
    /// Bind probe on 127.0.0.1:port. Returns true if bind succeeded (port free).
    static func canBind(port: UInt16) -> Bool {
        let socketFd = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFd >= 0 else { return false }
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
        return bindResult == 0
    }

    /// Non-destructive-ish check: bind failure ⇒ port in use (listener likely ready).
    static func isPortInUse(_ port: UInt16) -> Bool {
        !canBind(port: port)
    }

    static func allocatePort() throws -> UInt16 {
        for port in Array(1024 ... 65535).shuffled() where canBind(port: UInt16(port)) {
            return UInt16(port)
        }
        throw StealthOrchestratorError.portAllocationFailed
    }
}

struct StealthRuntimeStore {
    let runDirectory: String

    func ensureRunDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: runDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func statePath(tunnelName: String) -> String {
        "\(runDirectory)/\(tunnelName).json"
    }

    func ephemeralConfigPath(aliasName: String) -> String {
        "\(runDirectory)/\(aliasName).conf"
    }

    func persist(_ state: StealthOrchestrator.TunnelState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: URL(fileURLWithPath: statePath(tunnelName: state.tunnelName)), options: .atomic)
    }

    func load(tunnelName: String) -> StealthOrchestrator.TunnelState? {
        let url = URL(fileURLWithPath: statePath(tunnelName: tunnelName))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StealthOrchestrator.TunnelState.self, from: data)
    }

    func deleteRuntimeFiles(tunnelName: String, aliasName: String) {
        try? FileManager.default.removeItem(atPath: statePath(tunnelName: tunnelName))
        try? FileManager.default.removeItem(atPath: ephemeralConfigPath(aliasName: aliasName))
    }
}

enum StealthOrchestratorError: Error, LocalizedError {
    case portAllocationFailed
    case missingPeerEndpoint
    case missingTool(String)
    case wrapperExited
    case wrapperNotReady

    var errorDescription: String? {
        switch self {
        case .portAllocationFailed:
            return "Unable to allocate a free localhost port"
        case .missingPeerEndpoint:
            return "Tunnel config missing Peer Endpoint"
        case let .missingTool(name):
            return "\(name) not installed"
        case .wrapperExited:
            return "Stealth wrapper process exited unexpectedly"
        case .wrapperNotReady:
            return "Stealth wrapper listener not ready"
        }
    }
}
