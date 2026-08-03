import Foundation

enum TunnelRestoreKeys {
    static let lastConnectedTunnelNames = "lastConnectedTunnelNames"
}

struct TunnelRestoreStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String] {
        defaults.stringArray(forKey: TunnelRestoreKeys.lastConnectedTunnelNames) ?? []
    }

    func save(_ names: [String]) {
        defaults.set(names, forKey: TunnelRestoreKeys.lastConnectedTunnelNames)
    }

    func saveConnectedTunnels(_ tunnels: Tunnels) {
        save(tunnels.filter(\.connected).map(\.name))
    }
}

struct TunnelRestorePlan {
    let namesToEnable: [String]
    let namesToDrop: [String]
}

func planTunnelRestore(storedNames: [String], tunnels: Tunnels) -> TunnelRestorePlan {
    var namesToEnable: [String] = []
    var namesToDrop: [String] = []

    for name in storedNames {
        guard let tunnel = tunnels.first(where: { $0.name == name }) else {
            namesToDrop.append(name)
            continue
        }
        if !tunnel.connected {
            namesToEnable.append(name)
        }
    }

    return TunnelRestorePlan(namesToEnable: namesToEnable, namesToDrop: namesToDrop)
}
