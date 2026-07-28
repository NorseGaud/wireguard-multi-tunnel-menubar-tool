import Cocoa

/// Whether the Disable All menu item should be enabled.
func shouldEnableDisableAll(tunnels: Tunnels, pending: PendingTunnelOperations) -> Bool {
    tunnels.contains { $0.connected || pending[$0.name] == true }
}

/// Disable All row plus separator, for insertion above the tunnel list.
func buildDisableAllMenuItems(
    tunnels: Tunnels,
    pending: PendingTunnelOperations,
    target: AnyObject?,
    action: Selector?
) -> [NSMenuItem] {
    let item = NSMenuItem(title: "Disable All", action: action, keyEquivalent: "")
    item.tag = MenuItemTypes.disableAll.rawValue
    item.target = target
    item.isEnabled = shouldEnableDisableAll(tunnels: tunnels, pending: pending)
    let separator = NSMenuItem.separator()
    separator.tag = MenuItemTypes.disableAllSeparator.rawValue
    return [item, separator]
}
