// Interface with WireGuard using `wg-quick` or `wg` processes

import CryptoKit
import Foundation

struct WireGuard {
    let brewPrefix: String
    let wireguardBinPath: String
    let wgquickBinPath: String
    let configPaths: [String]
    let runPath: String

    // wg-quick accepts interface names up to 15 characters with this charset
    // swiftlint:disable:next force_try
    static let wgQuickInterfaceNameRegex = try! NSRegularExpression(pattern: "^[a-zA-Z0-9_=+.-]{1,15}$")

    // Tunnel config basenames may be longer; keep the same safe charset as wg-quick
    // swiftlint:disable:next force_try
    static let tunnelNameRegex = try! NSRegularExpression(pattern: "^[a-zA-Z0-9_=+.-]{1,251}$")

    static func validateTunnelName(tunnelName: String) -> Bool {
        return tunnelNameRegex.firstMatch(in: tunnelName,
                                          range: NSRange(location: 0, length: tunnelName.count)) != nil
    }

    static func isWgQuickInterfaceName(_ name: String) -> Bool {
        return wgQuickInterfaceNameRegex.firstMatch(in: name,
                                                    range: NSRange(location: 0, length: name.count)) != nil
    }

    /// wg-quick only accepts interface names up to 15 characters; map longer tunnel names deterministically.
    static func wgQuickInterfaceName(for tunnelName: String) -> String {
        if isWgQuickInterfaceName(tunnelName) {
            return tunnelName
        }

        let digest = SHA256.hash(data: Data(tunnelName.utf8))
        let hashPrefix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "wg-" + hashPrefix
    }

    /// censor sensitive information like private keys from configuration data
    static func censorConfigurationData(_ configData: String) -> String {
        // swiftlint:disable:next force_try
        let censorPrivateKey = try! NSRegularExpression(pattern: "^(PrivateKey|PresharedKey).*$",
                                                        options: [.anchorsMatchLines, .caseInsensitive])

        return censorPrivateKey.stringByReplacingMatches(in: configData,
                                                         options: [],
                                                         range: NSRange(location: 0, length: configData.count),
                                                         withTemplate: "PrivateKey = ***")
    }

    /// return a list of tunnel names from configuration files or active tunnels
    func tunnelNames() -> [String] {
        var tunnelNames = [String]()

        // get names of all tunnel configurations
        for configPath in configPaths {
            let enumerator = FileManager.default.enumerator(atPath: configPath)
            while let configFile = enumerator?.nextObject() as? String {
                // ignore non config file
                if !configFile.hasSuffix(".conf") {
                    // don't descend into subdirectories
                    enumerator?.skipDescendants()
                    continue
                }

                let tunnelName = configFile.replacingOccurrences(of: ".conf", with: "")
                if tunnelNames.contains(tunnelName) {
                    NSLog("Skipping '\(configFile)' as this tunnel already exists from a higher configuration path.")
                } else {
                    tunnelNames.append(tunnelName)
                }
            }
        }
        return tunnelNames
    }

    /// return name of tunnel interface (if tunnel is connected)
    func interfaceName(_ tunnelName: String) -> String {
        let wgQuickName = WireGuard.wgQuickInterfaceName(for: tunnelName)
        NSLog("Reading interface name for tunnel \(tunnelName) (wg-quick name: \(wgQuickName))")
        var interfaceName: String
        if let tunnelNameFileContents = try? String(contentsOfFile: runPath + "/" + wgQuickName + ".name",
                                                    encoding: .utf8) {
            interfaceName = tunnelNameFileContents.trimmingCharacters(in: NSCharacterSet.whitespacesAndNewlines)
        } else {
            // tunnel is not connected
            interfaceName = ""
        }
        return interfaceName
    }

    func configFilePath(for tunnelName: String) -> String? {
        for configPath in configPaths {
            let configFile = "\(configPath)/\(tunnelName).conf"
            if FileManager.default.fileExists(atPath: configFile) {
                return configFile
            }
        }
        return nil
    }

    /// return configuration for tunnel
    func tunnelConfig(_ tunnelName: String) -> String {
        guard let configFile = configFilePath(for: tunnelName) else {
            NSLog("Could not find configuration file for tunnel '\(tunnelName)'")
            return ""
        }

        // TODO: read configuration data from wg showconf as well
        NSLog("Reading config file: \(configFile)")
        if let configFileContents = try? String(contentsOfFile: configFile,
                                                encoding: .utf8) {
            return WireGuard.censorConfigurationData(configFileContents)
        }
        NSLog("Could not read configuration file for tunnel '\(tunnelName)'")
        return ""
    }

    /// Bring down every tunnel that is currently connected.
    /// - Parameter stealthBringDown: Optional per-tunnel stealth teardown. Return non-nil when the
    ///   tunnel had stealth state and was handled (skip plain setTunnel).
    func shutdownConnectedTunnels(stealthBringDown: ((String) -> (Bool, String)?)? = nil) {
        for tunnelName in tunnelNames() {
            if let stealthBringDown, let result = stealthBringDown(tunnelName) {
                if !result.0 {
                    NSLog("Failed to shut down stealth tunnel '\(tunnelName)' on quit: \(result.1)")
                }
                continue
            }
            guard !interfaceName(tunnelName).isEmpty else { continue }
            NSLog("Shutting down tunnel '\(tunnelName)' on app quit")
            let (success, errorMessage) = setTunnel(tunnelName: tunnelName, enable: false)
            if !success {
                NSLog("Failed to shut down tunnel '\(tunnelName)' on quit: \(errorMessage)")
            }
        }
    }

    func setTunnel(tunnelName: String, enable: Bool) -> (Bool, String) {
        setTunnel(tunnelName: tunnelName, enable: enable, quickBinPath: wgquickBinPath)
    }

    func setTunnel(tunnelName: String, enable: Bool, quickBinPath: String) -> (Bool, String) {
        let state = enable ? "up" : "down"
        let wgQuickName = WireGuard.wgQuickInterfaceName(for: tunnelName)

        if wgQuickName == tunnelName {
            return wgQuick([state, tunnelName], quickBinPath: quickBinPath)
        }

        guard let configFile = configFilePath(for: tunnelName) else {
            return (false, "Could not find configuration file for tunnel '\(tunnelName)'")
        }

        do {
            let aliasConfigFile = try createConfigAlias(configFile: configFile, wgQuickName: wgQuickName)
            let result = wgQuick([state, aliasConfigFile], quickBinPath: quickBinPath)
            if !enable, result.0 {
                try? FileManager.default.removeItem(atPath: aliasConfigFile)
            }
            return result
        } catch {
            let errorMessage = "Failed to prepare tunnel '\(tunnelName)' for wg-quick: \(error.localizedDescription)"
            NSLog(errorMessage)
            return (false, errorMessage)
        }
    }

    private func createConfigAlias(configFile: String, wgQuickName: String) throws -> String {
        try FileManager.default.createDirectory(atPath: wgQuickAliasPath,
                                                withIntermediateDirectories: true)
        let aliasConfigFile = "\(wgQuickAliasPath)/\(wgQuickName).conf"
        if FileManager.default.fileExists(atPath: aliasConfigFile) {
            try FileManager.default.removeItem(atPath: aliasConfigFile)
        }
        try FileManager.default.createSymbolicLink(atPath: aliasConfigFile, withDestinationPath: configFile)
        return aliasConfigFile
    }

    func wg(_ arguments: [String]) -> Process {
        let task = Process()
        task.launchPath = wireguardBinPath
        task.arguments = arguments
        let outpipe = Pipe()
        task.standardOutput = outpipe
        let errpipe = Pipe()
        task.standardError = errpipe
        task.launch()
        task.waitUntilExit()

        return task
    }

    func wgQuick(_ arguments: [String]) -> (Bool, String) {
        wgQuick(arguments, quickBinPath: wgquickBinPath)
    }

    func wgQuick(_ arguments: [String], quickBinPath: String) -> (Bool, String) {
        // prevent passing an invalid path or else task.launch will result in a fatal NSInvalidArgumentException
        guard FileManager.default.fileExists(atPath: quickBinPath) else {
            NSLog("Path '\(quickBinPath)' for quick binary is invalid!")
            return (false, "Path '\(quickBinPath)' for quick binary is invalid!")
        }

        let task = Process()
        task.launchPath = quickBinPath
        task.arguments = arguments
        // Add brew bin to path as wg-quick requires Bash 4 instead of macOS provided Bash 3
        task.environment = ["PATH": "\(brewPrefix)/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        let outpipe = Pipe()
        task.standardOutput = outpipe
        let errpipe = Pipe()
        task.standardError = errpipe
        task.launch()
        task.waitUntilExit()

        let errdata = errpipe.fileHandleForReading.readDataToEndOfFile()
        let errorMessage = String(data: errdata, encoding: String.Encoding.utf8) ?? ""

        if task.terminationStatus != 0 {
            let sanitizedError = WireGuard.censorConfigurationData(errorMessage)
            let logMessage = sanitizedError.trimmingCharacters(in: .whitespacesAndNewlines)
            let truncatedMessage = logMessage.count > 200
                ? String(logMessage.prefix(200)) + "..."
                : logMessage
            let binName = URL(fileURLWithPath: quickBinPath).lastPathComponent
            let commandSummary = "\(binName) \(arguments.joined(separator: " "))"
            NSLog("\(commandSummary) failed (exit \(task.terminationStatus)): \(truncatedMessage)")
        }

        return (task.terminationStatus == 0, errorMessage)
    }
}
