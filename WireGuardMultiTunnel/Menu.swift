// Menu building

import Cocoa

enum MenuItemTypes: Int {
    case none = 0, tunnel, tunnelplaceholder, disableAll, disableAllSeparator
}

class TunnelDetailMenuItem: NSMenuItem {
    override var indentationLevel: Int {
        get {
            return 1
        }
        set {
            self.indentationLevel = newValue
        }
    }
}

private let tunnelMenuItemHeight: CGFloat = 22

/// Full-width menu row; NSMenu otherwise sizes custom views to fit their subviews only.
class TunnelRowMenuItemView: NSView {
    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: tunnelMenuItemHeight))
        autoresizingMask = .width
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func resizeToMenuWidth(_ menuWidth: CGFloat) {
        setFrameSize(NSSize(width: menuWidth, height: tunnelMenuItemHeight))
        needsDisplay = true
    }
}

/// Tunnel name row. Green full-width background when enabled (connected or bringing up).
///
/// Paints green in `draw(_:)` like `TunnelSwitchMenuItemView`. Appearance can be
/// updated in place — `NSMenu.update()` often will not replace custom views while
/// the menu is open.
final class TunnelTitleMenuItemView: TunnelRowMenuItemView {
    private var showsEnabledBackground: Bool
    private let nameLabel: NSTextField
    private var accessoryView: NSView?
    private var dynamicConstraints: [NSLayoutConstraint] = []

    init(title: String, menuWidth: CGFloat, isEnabled: Bool, isPending: Bool) {
        showsEnabledBackground = isEnabled
        nameLabel = NSTextField(labelWithString: title)
        super.init(width: max(menuWidth, 1))

        // Give NSMenu a stable size even before resizeTunnelMenuItemViews runs.
        setFrameSize(NSSize(width: max(menuWidth, 160), height: tunnelMenuItemHeight))

        nameLabel.font = NSFont.menuFont(ofSize: 0)
        nameLabel.drawsBackground = false
        nameLabel.isBordered = false
        nameLabel.isEditable = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        applyAppearance(isEnabled: isEnabled, isPending: isPending)
    }

    /// Update green/title state without replacing the menu item view (needed while menu is open).
    func applyAppearance(isEnabled: Bool, isPending: Bool) {
        showsEnabledBackground = isEnabled
        nameLabel.textColor = isEnabled ? .black : .labelColor

        NSLayoutConstraint.deactivate(dynamicConstraints)
        dynamicConstraints.removeAll()
        accessoryView?.removeFromSuperview()
        accessoryView = nil

        if isPending {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            addSubview(spinner)
            spinner.startAnimation(nil)
            accessoryView = spinner

            dynamicConstraints = [
                nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -8),
                spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        } else if isEnabled {
            let statusLabel = NSTextField(labelWithString: "(connected)")
            statusLabel.font = NSFont.menuFont(ofSize: 0)
            statusLabel.textColor = NSColor.black.withAlphaComponent(0.6)
            statusLabel.drawsBackground = false
            statusLabel.isBordered = false
            statusLabel.isEditable = false
            statusLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(statusLabel)
            accessoryView = statusLabel

            dynamicConstraints = [
                statusLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
                statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            ]
        } else {
            dynamicConstraints = [
                nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            ]
        }

        NSLayoutConstraint.activate(dynamicConstraints)
        needsDisplay = true
        displayIfNeeded()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: tunnelMenuItemHeight)
    }

    override var isOpaque: Bool {
        showsEnabledBackground
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsEnabledBackground {
            NSColor.systemGreen.setFill()
            bounds.fill()
        }
        super.draw(dirtyRect)
    }
}

/// Immediately refresh tunnel title/switch rows in an already-open menu.
func syncOpenMenuTunnelAppearance(
    in menu: NSMenu,
    tunnelName: String,
    connected: Bool,
    pendingTarget: Bool?
) {
    let isPending = pendingTarget != nil
    let titleEnabled = connected || pendingTarget == true
    let enabledSwitchOn = pendingTarget ?? connected

    for item in menu.items {
        if let titleView = item.view as? TunnelTitleMenuItemView,
           item.representedObject as? String == tunnelName {
            titleView.applyAppearance(isEnabled: titleEnabled, isPending: isPending)
        }
        if let switchView = item.view as? TunnelSwitchMenuItemView,
           switchView.menuSwitch.tunnelName == tunnelName {
            switchView.menuSwitch.isEnabled = !isPending
            if switchView.menuSwitch.controlKind == "enabled" {
                switchView.menuSwitch.state = enabledSwitchOn ? .on : .off
            }
            switchView.applyOnBackground(isOn: switchView.menuSwitch.state == .on)
        }
    }
}

let maxMenuItemChars = 40

private let aboutPanelRepositoryURL = "https://github.com/NorseGaud/macos-menubar-wireguard"
private let aboutPanelUpstreamURL = "https://github.com/aequitas/macos-menubar-wireguard"
private let aboutPanelWireGuardURL = "https://www.wireguard.com/"

func aboutPanelCredits() -> NSAttributedString {
    let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let baseAttributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]

    let credits = NSMutableAttributedString()
    var isFirstLine = true

    func appendLine() {
        guard !isFirstLine else {
            isFirstLine = false
            return
        }
        credits.append(NSAttributedString(string: "\n", attributes: baseAttributes))
    }

    func appendText(_ text: String, link: String? = nil) {
        appendLine()
        var attributes = baseAttributes
        if let link {
            attributes[.link] = link
        }
        credits.append(NSAttributedString(string: text, attributes: attributes))
    }

    appendText(aboutPanelRepositoryURL, link: aboutPanelRepositoryURL)
    appendLine()
    credits.append(NSAttributedString(string: "Forked from ", attributes: baseAttributes))
    credits.append(NSAttributedString(
        string: aboutPanelUpstreamURL,
        attributes: baseAttributes.merging([.link: aboutPanelUpstreamURL]) { _, new in new }
    ))
    appendText(aboutPanelWireGuardURL, link: aboutPanelWireGuardURL)

    return credits
}

/// Width needed to fit standard (non-view) menu items; avoids `menu.update()` during rebuild.
func tunnelMenuRowWidth(in menu: NSMenu) -> CGFloat {
    var width = menu.minimumWidth
    let font = NSFont.menuFont(ofSize: 0)
    for item in menu.items where item.view == nil {
        let titleWidth = (item.title as NSString).size(withAttributes: [.font: font]).width
        width = max(width, titleWidth + 36)
    }
    return width
}

/// Match custom tunnel row views to the menu width after items are inserted.
func resizeTunnelMenuItemViews(in menu: NSMenu) {
    let menuWidth = max(tunnelMenuRowWidth(in: menu), menu.size.width)
    for item in menu.items where item.tag == MenuItemTypes.tunnel.rawValue {
        guard let view = item.view as? TunnelRowMenuItemView else { continue }
        view.resizeToMenuWidth(menuWidth)
    }
}

extension String {
    enum TruncationPosition {
        case head
        case middle
        case tail
    }

    func truncated(limit: Int, position: TruncationPosition = .tail, leader: String = "...") -> String {
        guard count > limit else { return self }

        switch position {
        case .head:
            return leader + suffix(limit)
        case .middle:
            let headCharactersCount = Int(ceil(Float(limit - leader.count) / 2.0))

            let tailCharactersCount = Int(floor(Float(limit - leader.count) / 2.0))

            return "\(prefix(headCharactersCount))\(leader)\(suffix(tailCharactersCount))"
        case .tail:
            return prefix(limit) + leader
        }
    }
}

// contruct menu with all tunnels found in configuration
// TODO: find out if it is possible to have a dynamic bound IB menu with variable contents
/// Target enabled state for tunnels with an in-flight wg-quick up/down.
typealias PendingTunnelOperations = [String: Bool]

func buildMenu(tunnels: Tunnels, options: MenuBuildOptions = MenuBuildOptions()) -> [NSMenuItem] {
    guard !tunnels.isEmpty else {
        return [NSMenuItem(title: "No tunnel configurations found",
                           action: nil, keyEquivalent: "")]
    }

    var items: [NSMenuItem] = []
    for tunnel in tunnels.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
        let item = NSMenuItem(title: tunnel.name, action: nil, keyEquivalent: "")
        items.append(item)
        item.representedObject = tunnel.name
        // Keep name rows enabled so AppKit does not dim custom-view labels.
        // Action is nil; connect/disconnect is only via the Enabled switch.
        let pendingTarget = options.pendingTunnels[tunnel.name]
        let isPending = pendingTarget != nil
        // Green while connected, or while bringing up (Enabled on / pending true).
        let titleEnabled = tunnel.connected || pendingTarget == true
        item.view = TunnelTitleMenuItemView(
            title: tunnel.name,
            menuWidth: options.menuItemWidth,
            isEnabled: titleEnabled,
            isPending: isPending
        )
        item.isEnabled = true

        let profile = options.stealthProfiles[tunnel.name] ?? StealthProfile()
        let switchesEnabled = options.pendingTunnels[tunnel.name] == nil
            && options.switchTarget != nil
            && options.switchAction != nil
        items.append(contentsOf: stealthSwitchMenuItems(
            tunnelName: tunnel.name,
            connected: tunnel.connected,
            profile: profile,
            options: options,
            switchesEnabled: switchesEnabled
        ))

        if tunnel.connected && (options.connectedTunnelDetails || options.allTunnelDetails),
           let interface = tunnel.interface {
            items.append(TunnelDetailMenuItem(title: "Interface: \(interface)",
                                              action: nil, keyEquivalent: ""))
        }

        if (tunnel.connected && options.connectedTunnelDetails) || options.allTunnelDetails {
            if let config = tunnel.config {
                items.append(TunnelDetailMenuItem(title: "Address: \(config.address)",
                                                  action: nil, keyEquivalent: ""))
                for peer in config.peers {
                    let endpointTitle = "Endpoint: \(peer.endpoint)"
                    let endpointItem = TunnelDetailMenuItem(title: endpointTitle.truncated(limit: maxMenuItemChars,
                                                                                           position: .middle),
                                                            action: nil, keyEquivalent: "")
                    endpointItem.toolTip = endpointTitle
                    items.append(endpointItem)

                    let ipsTitle = "Allowed IPs: \(peer.allowedIps.joined(separator: ", "))"
                    let ipsItem = TunnelDetailMenuItem(title: ipsTitle.truncated(limit: maxMenuItemChars,
                                                                                 position: .middle),
                                                       action: nil, keyEquivalent: "")
                    ipsItem.toolTip = ipsTitle
                    items.append(ipsItem)
                }
            } else {
                items.append(TunnelDetailMenuItem(title: "Could not parse tunnel configuration!",
                                                  action: nil, keyEquivalent: ""))
            }
        }
    }

    return items
}

private func stealthSwitchMenuItems(
    tunnelName: String,
    connected: Bool,
    profile: StealthProfile,
    options: MenuBuildOptions,
    switchesEnabled: Bool
) -> [NSMenuItem] {
    let pendingTarget = options.pendingTunnels[tunnelName]
    let enabledIsOn = pendingTarget ?? connected
    let rows = [
        StealthSwitchRow(title: "Enabled", controlKind: "enabled", isOn: enabledIsOn),
        StealthSwitchRow(title: "Amnezia", controlKind: "amnezia", isOn: profile.amnezia.enabled),
        StealthSwitchRow(title: "udp2raw", controlKind: "udp2raw", isOn: profile.udp2raw.enabled),
        StealthSwitchRow(title: "wstunnel", controlKind: "wstunnel", isOn: profile.wstunnel.enabled),
    ]
    return rows.map { row in
        let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
        let view = TunnelSwitchMenuItemView(
            title: row.title,
            isOn: row.isOn,
            tunnelName: tunnelName,
            controlKind: row.controlKind,
            menuWidth: options.menuItemWidth,
            target: switchesEnabled ? options.switchTarget : nil,
            action: switchesEnabled ? options.switchAction : nil
        )
        view.menuSwitch.isEnabled = switchesEnabled
        item.view = view
        item.isEnabled = switchesEnabled
        return item
    }
}

private let activeMenuBarGreen = NSColor.systemGreen

private func greenFilledMenuBarImage(from image: NSImage) -> NSImage {
    guard let tinted = image.copy() as? NSImage else { return image }
    tinted.isTemplate = false
    tinted.lockFocus()
    activeMenuBarGreen.set()
    NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}

/// Drop pending entries once tunnel state matches the requested target.
func resolvePendingTunnelOperations(_ pending: inout PendingTunnelOperations, tunnels: Tunnels) {
    for (tunnelName, targetEnabled) in pending {
        guard let tunnel = tunnels.first(where: { $0.name == tunnelName }) else { continue }
        if tunnel.connected == targetEnabled {
            pending.removeValue(forKey: tunnelName)
        }
    }
}

func menuImage(tunnels: Tunnels) -> NSImage {
    let connectedTunnels = tunnels.filter { $0.connected }
    if connectedTunnels.isEmpty {
        let icon = NSImage(named: .disabled)!
        icon.isTemplate = true
        return icon
    } else {
        return greenFilledMenuBarImage(from: NSImage(named: .connected)!)
    }
}
