import Foundation

struct AmneziaSettings: Codable, Equatable {
    var enabled: Bool = false
    // AmneziaWG junk-packet field names are protocol identifiers (Jc/Jmin/S1/H1…).
    // swiftlint:disable identifier_name
    var jc: Int = 0
    var jmin: Int = 0
    var jmax: Int = 0
    var s1: Int = 0
    var s2: Int = 0
    var h1: UInt32 = 1
    var h2: UInt32 = 2
    var h3: UInt32 = 3
    var h4: UInt32 = 4
    // swiftlint:enable identifier_name
}

struct Udp2RawSettings: Codable, Equatable {
    enum RawMode: String, Codable, Equatable {
        case faketcp
        case udp
        case icmp
    }

    var enabled: Bool = false
    var remoteHost: String = ""
    var remotePort: UInt16 = 0
    var password: String = ""
    var rawMode: RawMode = .faketcp
    var extraArgs: [String] = []
}

struct WsTunnelSettings: Codable, Equatable {
    var enabled: Bool = false
    var serverURL: String = ""
    var tlsSkipVerify: Bool = false
    var extraArgs: [String] = []
}

struct StealthProfile: Codable, Equatable {
    var schemaVersion: Int = 1
    var amnezia: AmneziaSettings = .init()
    var udp2raw: Udp2RawSettings = .init()
    var wstunnel: WsTunnelSettings = .init()

    var hasAnyLayerEnabled: Bool {
        amnezia.enabled || udp2raw.enabled || wstunnel.enabled
    }

    func validate() throws {
        if amnezia.enabled {
            guard amnezia.jmin >= 0, amnezia.jmax >= amnezia.jmin, amnezia.jc >= 0 else {
                throw StealthValidationError.invalidAmneziaParams
            }
        }
        if udp2raw.enabled {
            guard !udp2raw.remoteHost.isEmpty, udp2raw.remotePort > 0, !udp2raw.password.isEmpty else {
                throw StealthValidationError.incompleteUdp2Raw
            }
            try StealthArgSecurity.validateExtraArgs(udp2raw.extraArgs)
        }
        if wstunnel.enabled {
            guard let url = URL(string: wstunnel.serverURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "ws" || scheme == "wss"
            else {
                throw StealthValidationError.incompleteWsTunnel
            }
            try StealthArgSecurity.validateExtraArgs(wstunnel.extraArgs)
        }
    }

    func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw StealthValidationError.invalidJSON
        }
        return string
    }

    static func parse(jsonString: String) throws -> StealthProfile {
        if jsonString.isEmpty {
            return StealthProfile()
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw StealthValidationError.invalidJSON
        }
        return try JSONDecoder().decode(StealthProfile.self, from: data)
    }
}

struct StealthToolsStatus: Codable, Equatable {
    var amnezia: Bool = false
    var udp2raw: Bool = false
    var wstunnel: Bool = false
}

enum StealthValidationError: Error, Equatable {
    case invalidAmneziaParams
    case incompleteUdp2Raw
    case incompleteWsTunnel
    case invalidJSON
    case invalidExtraArgs(String)
}

/// Routes setTunnel enable/disable before touching WireGuard or the orchestrator.
/// Disable never parses/validates profile JSON (teardown uses runtime state alone).
enum StealthSetTunnelPlan: Equatable {
    case down
    case upPlain
    case upStealth(StealthProfile)
}

enum StealthSetTunnelPlanner {
    static func plan(enable: Bool, stealthProfileJSON: String) throws -> StealthSetTunnelPlan {
        guard enable else { return .down }
        let profile = try StealthProfile.parse(jsonString: stealthProfileJSON)
        try profile.validate()
        return profile.hasAnyLayerEnabled ? .upStealth(profile) : .upPlain
    }
}
