import Foundation

struct StealthProfilesFile: Codable {
    var schemaVersion: Int = 1
    var profiles: [String: StealthProfile] = [:]
}

final class StealthSettingsStore {
    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "StealthSettingsStore.io")

    init(directoryURL: URL) {
        fileURL = directoryURL.appendingPathComponent("stealth-profiles.json")
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    static var defaultDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WireGuardMultiTunnel", isDirectory: true)
    }

    func profile(for tunnelName: String) -> StealthProfile {
        ioQueue.sync { load().profiles[tunnelName] ?? StealthProfile() }
    }

    func save(profile: StealthProfile, for tunnelName: String) throws {
        try ioQueue.sync {
            var file = load()
            file.profiles[tunnelName] = profile
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL, options: .atomic)
        }
    }

    func removeProfile(for tunnelName: String) throws {
        try ioQueue.sync {
            var file = load()
            file.profiles.removeValue(forKey: tunnelName)
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() -> StealthProfilesFile {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(StealthProfilesFile.self, from: data)
        else {
            return StealthProfilesFile()
        }
        return file
    }
}
