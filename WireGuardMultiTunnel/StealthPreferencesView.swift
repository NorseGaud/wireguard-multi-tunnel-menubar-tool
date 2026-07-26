import Cocoa

/// Programmatic Preferences → Stealth editor for per-tunnel obfuscation settings.
final class StealthPreferencesView: NSView {
    var store: StealthSettingsStore?
    var tunnelNamesProvider: (() -> [String])?
    var toolsStatusProvider: ((@escaping (String) -> Void) -> Void)?

    private let controls = StealthPreferencesControls()
    private var toolsStatus = StealthToolsStatus()
    private var isLoadingProfile = false
    private var selectedTunnelName: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        controls.embed(
            in: self,
            target: self,
            change: #selector(controlChanged),
            tunnelChange: #selector(tunnelChanged)
        )
        updateFieldVisibility()
        updateToolStatusLabels()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        controls.embed(
            in: self,
            target: self,
            change: #selector(controlChanged),
            tunnelChange: #selector(tunnelChanged)
        )
        updateFieldVisibility()
        updateToolStatusLabels()
    }

    func reload() {
        reloadTunnelList()
        refreshToolsStatus()
        loadSelectedProfile()
    }

    func reloadToolsStatus(json: String) {
        if let data = json.data(using: .utf8),
           let status = try? JSONDecoder().decode(StealthToolsStatus.self, from: data) {
            toolsStatus = status
        } else {
            toolsStatus = StealthToolsStatus()
        }
        updateToolStatusLabels()
        updateEnabledStateForTools()
    }

    private func reloadTunnelList() {
        let names = tunnelNamesProvider?() ?? []
        let previous = controls.tunnelPopup.selectedItem?.title
        controls.tunnelPopup.removeAllItems()
        if names.isEmpty {
            controls.tunnelPopup.addItem(withTitle: "(no tunnels)")
            controls.tunnelPopup.isEnabled = false
            selectedTunnelName = nil
        } else {
            controls.tunnelPopup.addItems(withTitles: names)
            controls.tunnelPopup.isEnabled = true
            if let previous, names.contains(previous) {
                controls.tunnelPopup.selectItem(withTitle: previous)
            }
            selectedTunnelName = controls.tunnelPopup.titleOfSelectedItem
        }
    }

    private func refreshToolsStatus() {
        toolsStatusProvider? { [weak self] json in
            DispatchQueue.main.async {
                self?.reloadToolsStatus(json: json)
            }
        }
    }

    private func loadSelectedProfile() {
        guard let store, let name = selectedTunnelName, controls.tunnelPopup.isEnabled else {
            clearFields()
            return
        }
        isLoadingProfile = true
        defer { isLoadingProfile = false }

        let profile = store.profile(for: name)
        apply(profile)
        updateFieldVisibility()
        updateEnabledStateForTools()
    }

    private func apply(_ profile: StealthProfile) {
        controls.amneziaCheckbox.state = profile.amnezia.enabled ? .on : .off
        controls.jcField.stringValue = String(profile.amnezia.jc)
        controls.jminField.stringValue = String(profile.amnezia.jmin)
        controls.jmaxField.stringValue = String(profile.amnezia.jmax)
        controls.s1Field.stringValue = String(profile.amnezia.s1)
        controls.s2Field.stringValue = String(profile.amnezia.s2)
        controls.h1Field.stringValue = String(profile.amnezia.h1)
        controls.h2Field.stringValue = String(profile.amnezia.h2)
        controls.h3Field.stringValue = String(profile.amnezia.h3)
        controls.h4Field.stringValue = String(profile.amnezia.h4)

        controls.udp2rawCheckbox.state = profile.udp2raw.enabled ? .on : .off
        controls.udpHostField.stringValue = profile.udp2raw.remoteHost
        controls.udpPortField.stringValue = profile.udp2raw.remotePort == 0 ? "" : String(profile.udp2raw.remotePort)
        controls.udpPasswordField.stringValue = profile.udp2raw.password
        controls.udpModePopup.selectItem(withTitle: profile.udp2raw.rawMode.rawValue)
        controls.udpExtraArgsField.stringValue = profile.udp2raw.extraArgs.joined(separator: " ")

        controls.wstunnelCheckbox.state = profile.wstunnel.enabled ? .on : .off
        controls.wsURLField.stringValue = profile.wstunnel.serverURL
        controls.wsTLSSkipCheckbox.state = profile.wstunnel.tlsSkipVerify ? .on : .off
        controls.wsExtraArgsField.stringValue = profile.wstunnel.extraArgs.joined(separator: " ")
    }

    private func clearFields() {
        isLoadingProfile = true
        defer { isLoadingProfile = false }
        controls.amneziaCheckbox.state = .off
        controls.udp2rawCheckbox.state = .off
        controls.wstunnelCheckbox.state = .off
        updateFieldVisibility()
    }

    private func currentProfileFromUI() -> StealthProfile {
        var profile = StealthProfile()
        profile.amnezia.enabled = controls.amneziaCheckbox.state == .on
        profile.amnezia.jc = Int(controls.jcField.stringValue) ?? 0
        profile.amnezia.jmin = Int(controls.jminField.stringValue) ?? 0
        profile.amnezia.jmax = Int(controls.jmaxField.stringValue) ?? 0
        profile.amnezia.s1 = Int(controls.s1Field.stringValue) ?? 0
        profile.amnezia.s2 = Int(controls.s2Field.stringValue) ?? 0
        profile.amnezia.h1 = UInt32(controls.h1Field.stringValue) ?? 1
        profile.amnezia.h2 = UInt32(controls.h2Field.stringValue) ?? 2
        profile.amnezia.h3 = UInt32(controls.h3Field.stringValue) ?? 3
        profile.amnezia.h4 = UInt32(controls.h4Field.stringValue) ?? 4

        profile.udp2raw.enabled = controls.udp2rawCheckbox.state == .on
        profile.udp2raw.remoteHost = controls.udpHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.udp2raw.remotePort = UInt16(controls.udpPortField.stringValue) ?? 0
        profile.udp2raw.password = controls.udpPasswordField.stringValue
        if let mode = Udp2RawSettings.RawMode(rawValue: controls.udpModePopup.titleOfSelectedItem ?? "") {
            profile.udp2raw.rawMode = mode
        }
        profile.udp2raw.extraArgs = splitArgs(controls.udpExtraArgsField.stringValue)

        profile.wstunnel.enabled = controls.wstunnelCheckbox.state == .on
        profile.wstunnel.serverURL = controls.wsURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.wstunnel.tlsSkipVerify = controls.wsTLSSkipCheckbox.state == .on
        profile.wstunnel.extraArgs = splitArgs(controls.wsExtraArgsField.stringValue)
        return profile
    }

    private func splitArgs(_ value: String) -> [String] {
        value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private func autosave() {
        guard !isLoadingProfile,
              let store,
              let name = selectedTunnelName,
              controls.tunnelPopup.isEnabled
        else { return }
        do {
            try store.save(profile: currentProfileFromUI(), for: name)
        } catch {
            NSLog("Failed to save stealth profile for \(name): \(error)")
        }
    }

    private func updateFieldVisibility() {
        controls.amneziaFieldsStack.isHidden = controls.amneziaCheckbox.state != .on
        controls.udp2rawFieldsStack.isHidden = controls.udp2rawCheckbox.state != .on
        controls.wstunnelFieldsStack.isHidden = controls.wstunnelCheckbox.state != .on
    }

    private func updateToolStatusLabels() {
        controls.amneziaStatusLabel.stringValue = toolsStatus.amnezia ? "Installed" : "Missing"
        controls.udp2rawStatusLabel.stringValue = toolsStatus.udp2raw ? "Installed" : "Missing"
        controls.wstunnelStatusLabel.stringValue = toolsStatus.wstunnel ? "Installed" : "Missing"

        var hints: [String] = []
        if !toolsStatus.wstunnel { hints.append("brew install wstunnel") }
        if !toolsStatus.udp2raw { hints.append("brew install udp2raw") }
        if !toolsStatus.amnezia {
            hints.append("# Amnezia: build awg-quick + amneziawg-go into $(brew --prefix)/bin")
        }
        controls.installHintsLabel.stringValue = hints.joined(separator: "\n")
        controls.installHintsLabel.isHidden = hints.isEmpty
    }

    private func updateEnabledStateForTools() {
        // Allow enable only when tool installed; always allow uncheck when layer is on.
        controls.amneziaCheckbox.isEnabled =
            toolsStatus.amnezia || controls.amneziaCheckbox.state == .on
        setEnabled(
            controls.amneziaFieldsStack,
            toolsStatus.amnezia && controls.amneziaCheckbox.state == .on
        )

        controls.udp2rawCheckbox.isEnabled =
            toolsStatus.udp2raw || controls.udp2rawCheckbox.state == .on
        setEnabled(
            controls.udp2rawFieldsStack,
            toolsStatus.udp2raw && controls.udp2rawCheckbox.state == .on
        )

        controls.wstunnelCheckbox.isEnabled =
            toolsStatus.wstunnel || controls.wstunnelCheckbox.state == .on
        setEnabled(
            controls.wstunnelFieldsStack,
            toolsStatus.wstunnel && controls.wstunnelCheckbox.state == .on
        )
        controls.wsTLSSkipCheckbox.isEnabled =
            toolsStatus.wstunnel && controls.wstunnelCheckbox.state == .on
    }

    private func setEnabled(_ view: NSView, _ enabled: Bool) {
        if let control = view as? NSControl {
            control.isEnabled = enabled
        }
        for sub in view.subviews {
            setEnabled(sub, enabled)
        }
    }

    @objc private func tunnelChanged() {
        selectedTunnelName = controls.tunnelPopup.isEnabled ? controls.tunnelPopup.titleOfSelectedItem : nil
        loadSelectedProfile()
    }

    @objc private func controlChanged() {
        updateFieldVisibility()
        updateEnabledStateForTools()
        autosave()
    }
}

extension StealthPreferencesView: NSTextFieldDelegate {
    func controlTextDidChange(_: Notification) {
        autosave()
    }
}
