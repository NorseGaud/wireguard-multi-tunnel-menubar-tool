import Cocoa

struct MenuBuildOptions {
    var menuItemWidth: CGFloat = 200
    var pendingTunnels: PendingTunnelOperations = [:]
    var switchTarget: AnyObject?
    var switchAction: Selector?
    var allTunnelDetails = false
    var connectedTunnelDetails = true
}

struct TunnelSwitchRow {
    let title: String
    let controlKind: String
    let isOn: Bool
}
