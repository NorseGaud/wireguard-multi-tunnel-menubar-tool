// Helper main logic

import Foundation

/// amount of ms to debounce filesystem events to prevent sending update notifications to the App to often
let fseventDebounce = 100

class Helper: NSObject, HelperProtocol, SKQueueDelegate {
    private var app: AppXPC?

    private var queue: SKQueue?

    /// Prefix path for etc/wireguard, bin/wg, bin/wireguard-go and bin/bash (bash 4),
    /// can be overridden by the user via root defaults to allow custom location for Homebrew.
    private var brewPrefix: String
    // Path to wg-quick, can be overriden by the user via root defaults.
    // NOTICE: the root defaults override feature is a half implemented feature
    // the GUI App will not be aware of these settings and might falsely warn that WireGuard
    // is not installed. This warning can be ignored.
    // Example, to set defaults as root for wgquickBinPath run:
    // sudo defaults write WireGuardMultiTunnelHelper wgquickBinPath /opt/local/bin/wg-quick
    private var wgquickBinPath: String
    /// Path use to determine if WireGuard Homebrew package is installed and query wg for tunnel names and configuration
    /// To check wg binary is enough to also guarentee wg-quick and wireguard-go when installed with Homebrew.
    private var wireguardBinPath: String

    let defaults = UserDefaults.standard

    let wireguard: WireGuard

    /// Read preferences set via root defaults.
    override init() {
        defaults.register(defaults: DefaultSettings.Helper)

        let configuredBrewPrefix = defaults.string(forKey: "brewPrefix") ?? defaultBrewPrefix
        if let validatedBrewPrefix = PathSecurity.validateDirectoryPath(configuredBrewPrefix) {
            brewPrefix = validatedBrewPrefix
        } else {
            NSLog("Invalid brewPrefix '\(configuredBrewPrefix)', using default '\(defaultBrewPrefix)'")
            brewPrefix = defaultBrewPrefix
        }
        if brewPrefix != DefaultSettings.Helper["brewPrefix"] {
            NSLog("Overriding 'brewPrefix' with: \(brewPrefix)")
        }
        wireguardBinPath = "\(brewPrefix)/bin/wg"

        let defaultWgQuickPath = "\(brewPrefix)/bin/wg-quick"
        if let configuredWgQuickPath = defaults.string(forKey: "wgquickBinPath"), !configuredWgQuickPath.isEmpty {
            if let validatedWgQuickPath = PathSecurity.validateBinaryPath(configuredWgQuickPath,
                                                                          expectedBasename: "wg-quick") {
                wgquickBinPath = validatedWgQuickPath
                NSLog("Overriding 'wgquickBinPath' with: \(wgquickBinPath)")
            } else {
                NSLog("Invalid wgquickBinPath '\(configuredWgQuickPath)', using '\(defaultWgQuickPath)'")
                wgquickBinPath = defaultWgQuickPath
            }
        } else {
            wgquickBinPath = defaultWgQuickPath
        }

        // Homebrew installs WireGuard configs under ${brewPrefix}/etc/wireguard
        let configPaths = ["\(brewPrefix)\(defaultConfigPath)"]

        wireguard = WireGuard(
            brewPrefix: brewPrefix,
            wireguardBinPath: wireguardBinPath,
            wgquickBinPath: wgquickBinPath,
            configPaths: configPaths,
            runPath: runPath
        )
    }

    /// Starts the helper daemon
    func run() {
        // create XPC to App
        app = AppXPC(exportedObject: self, onConnect: abortShutdown, onClose: shutdown)

        // watch configuration and runstate directories for changes to notify App
        registerWireGuardStateWatch()

        // keep running (last XPC connection closing quits)
        // TODO: Helper needs to live for at least 10 seconds or launchd will get unhappy
        CFRunLoopRun()
    }

    func registerWireGuardStateWatch() {
        // register watchers to respond to changes in wireguard config/runtime state
        // will trigger: receivedNotification
        if queue == nil {
            queue = SKQueue(delegate: self)!
        }
        for directory in wireguard.configPaths + [runPath] {
            // skip already watched paths
            if queue!.isPathWatched(directory) { continue }

            if FileManager.default.fileExists(atPath: directory) {
                NSLog("Watching \(directory) for changes")
                queue!.addPath(directory)
            } else {
                NSLog("Not watching '\(directory)' as it does not exist")
            }
        }
    }

    var debounceFilesystemEvents: DispatchWorkItem?

    // SKQueue: handle incoming file/directory change events
    func receivedNotification(_: SKQueueNotification, path: String, queue _: SKQueue) {
        if wireguard.configPaths.contains(path) {
            NSLog("Configuration files changed, reloading")
        }
        if path == runPath {
            NSLog("Tunnel state changed, reloading")
        }
        // TODO: only send events on actual changes (/var/run/tunnel.name, /etc/wireguard/tunnel.conf)
        // not for every change in either run or config directories

        // prevent sending notifications about changes to config/runtime state to fast after another
        if debounceFilesystemEvents == nil {
            debounceFilesystemEvents = DispatchWorkItem {
                self.debounceFilesystemEvents = nil
                self.appUpdateState()
            }
            let deadline = DispatchTime.now() + DispatchTimeInterval.milliseconds(fseventDebounce)
            DispatchQueue.main.asyncAfter(deadline: deadline,
                                          execute: debounceFilesystemEvents!)
        }
    }

    /// Send a signal to the App that tunnel state/configuration might have changed
    func appUpdateState() {
        for connection in app!.connections {
            if let remoteObject = connection.remoteObjectProxy as? AppProtocol {
                remoteObject.updateState()
            } else {
                NSLog("Failed to notify App of configuration/state changes.")
            }
        }
    }

    // XPC: return raw data to be used by App to construct tunnel configuration/state
    func getTunnels(reply: @escaping (TunnelInfo) -> Void) {
        reply(Dictionary(uniqueKeysWithValues: wireguard.tunnelNames().map { tunnelName in
            (tunnelName, [wireguard.interfaceName(tunnelName), wireguard.tunnelConfig(tunnelName)])
        }))
    }

    // XPC: called by App to have Helper change the state of a tunnel to up or down
    func setTunnel(tunnelName: String, enable: Bool, reply:
        @escaping (_ success: Bool, _ errorMessage: String) -> Void) {
        setTunnel(tunnelName: tunnelName, enable: enable, stealthProfileJSON: "", reply: reply)
    }

    // XPC: tunnel up/down with optional stealth profile JSON (empty = plain WireGuard)
    func setTunnel(tunnelName: String, enable: Bool, stealthProfileJSON: String, reply:
        @escaping (_ success: Bool, _ errorMessage: String) -> Void) {
        if !WireGuard.validateTunnelName(tunnelName: tunnelName) {
            NSLog("Invalid tunnel name '\(tunnelName)'")
            reply(false, "Invalid tunnel name '\(tunnelName)'")
            return
        }

        let profile: StealthProfile
        do {
            profile = try StealthProfile.parse(jsonString: stealthProfileJSON)
            try profile.validate()
        } catch {
            reply(false, "Invalid stealth profile: \(error)")
            return
        }

        let (success, errorMessage): (Bool, String)
        if !enable {
            (success, errorMessage) = bringTunnelDown(tunnelName: tunnelName, profile: profile)
        } else if profile.hasAnyLayerEnabled {
            (success, errorMessage) = bringStealthTunnelUp(tunnelName: tunnelName, profile: profile)
        } else {
            NSLog("Set tunnel \(tunnelName) up")
            (success, errorMessage) = wireguard.setTunnel(tunnelName: tunnelName, enable: true)
        }

        reply(success, errorMessage)
        // /var/run/wireguard may be created on first up; re-register watchers and notify App.
        registerWireGuardStateWatch()
        appUpdateState()
    }

    func stealthToolsStatus(_ reply: @escaping (String) -> Void) {
        let status = currentStealthToolsStatus()
        guard let data = try? JSONEncoder().encode(status),
              let json = String(data: data, encoding: .utf8)
        else {
            reply("{\"amnezia\":false,\"udp2raw\":false,\"wstunnel\":false}")
            return
        }
        reply(json)
    }

    // XPC: allow App to query version of helper to allow updating when a new version is available
    func getVersion(_ reply: (String) -> Void) {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            reply(version)
        } else {
            NSLog("Unable to get version information")
            reply("n/a")
        }
    }

    func wireguardInstalled(_ reply: (Bool) -> Void) {
        let wireguardInstalled = PathSecurity.validateExecutableBinaryPath(wireguardBinPath,
                                                                           expectedBasename: "wg") != nil
        let wgquickInstalled = PathSecurity.validateExecutableBinaryPath(wgquickBinPath,
                                                                         expectedBasename: "wg-quick") != nil
        reply(wgquickInstalled && wireguardInstalled)
    }

    // Launchd throttles services that restart to soon (<10 seconds), provide a mechanism to prevent this.
    // set the time in the future when it is safe to shutdown the helper without launchd penalty
    let launchdMinimaltimeExpired = DispatchTime.now() + DispatchTimeInterval.seconds(10)
    var shutdownTask: DispatchWorkItem?

    func shutdown() {
        NSLog("Going to shut down")
        shutdownConnectedTunnelsClearingStealth()
        // Dispatch the shutdown of the runloop to at least 10 seconds after starting the application.
        // This will shutdown immidiately if the deadline already passed.
        shutdownTask = DispatchWorkItem {
            CFRunLoopStop(CFRunLoopGetCurrent())
            NSLog("Shutting down")
        }
        // Dispatch to main queue since that is the thread where the runloop is
        DispatchQueue.main.asyncAfter(deadline: launchdMinimaltimeExpired, execute: shutdownTask!)
    }

    /// allow shutdown to be aborted (eg: when a new XPC connection comes in)
    func abortShutdown() {
        if let shutdownTask = shutdownTask {
            NSLog("Aborting shutdown")
            shutdownTask.cancel()
            self.shutdownTask = nil
        }
    }
}

private extension Helper {
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

    func bringTunnelDown(tunnelName: String, profile: StealthProfile) -> (Bool, String) {
        let orchestrator = makeStealthOrchestrator()
        guard let state = orchestrator.runtimeState(for: tunnelName) else {
            NSLog("Set tunnel \(tunnelName) down")
            return wireguard.setTunnel(tunnelName: tunnelName, enable: false)
        }

        let toolPaths = resolveStealthToolPaths()
        let useAmnezia = state.useAmnezia ?? profile.amnezia.enabled
        let quickBin = quickBinPath(useAmnezia: useAmnezia, toolPaths: toolPaths)
        let aliasName = state.aliasName

        NSLog("Set stealth tunnel \(tunnelName) down")
        let (success, errorMessage) = orchestrator.bringDown(tunnelName: tunnelName) {
            self.downEphemeralInterface(aliasName: aliasName, quickBinPath: quickBin)
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
            let toolPaths = self.resolveStealthToolPaths()
            let useAmnezia = state.useAmnezia ?? false
            let quickBin = self.quickBinPath(useAmnezia: useAmnezia, toolPaths: toolPaths)
            let aliasName = state.aliasName
            return orchestrator.bringDown(tunnelName: tunnelName) {
                self.downEphemeralInterface(aliasName: aliasName, quickBinPath: quickBin)
            }
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
            let toolPaths = resolveStealthToolPaths()
            let useAmnezia = state.useAmnezia ?? false
            let quickBin = quickBinPath(useAmnezia: useAmnezia, toolPaths: toolPaths)
            _ = orchestrator.bringDown(tunnelName: tunnelName) {
                self.downEphemeralInterface(aliasName: state.aliasName, quickBinPath: quickBin)
            }
        }
    }
}
