import Cocoa

struct MenuBuildOptions {
    var menuItemWidth: CGFloat = 200
    var pendingTunnels: PendingTunnelOperations = [:]
    var stealthProfiles: [String: StealthProfile] = [:]
    var switchTarget: AnyObject?
    var switchAction: Selector?
    var allTunnelDetails = false
    var connectedTunnelDetails = true
}

struct StealthSwitchRow {
    let title: String
    let controlKind: String
    let isOn: Bool
}
