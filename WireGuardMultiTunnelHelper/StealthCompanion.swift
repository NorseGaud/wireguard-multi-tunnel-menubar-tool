import Foundation

/// Load/save `<tunnel>.stealth.json` beside the WireGuard `.conf`.
enum StealthCompanion {
    static func filePath(for tunnelName: String, configFilePath: String) -> String {
        let directory = (configFilePath as NSString).deletingLastPathComponent
        return (directory as NSString).appendingPathComponent("\(tunnelName).stealth.json")
    }

    static func load(tunnelName: String, configFilePath: String) -> StealthProfile {
        let path = filePath(for: tunnelName, configFilePath: configFilePath)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let profile = try? JSONDecoder().decode(StealthProfile.self, from: data)
        else {
            return StealthProfile()
        }
        return profile
    }

    static func save(profile: StealthProfile, tunnelName: String, configFilePath: String) throws {
        let path = filePath(for: tunnelName, configFilePath: configFilePath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
