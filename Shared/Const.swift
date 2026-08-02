// Constants

import Foundation

let runPath = "/var/run/wireguard"
/// Symlinks with wg-quick-compatible names for tunnels whose config basename exceeds 15 characters
let wgQuickAliasPath = "/var/run/wireguard-multitunnel"

let wireguardInstallURL =
    "https://www.wireguard.com/install/" +
    "#macos-homebrew-and-macports-basic-cli-homebrew-userspace-go-homebrew-tools-macports-userspace-go-macports-tools"

let installInstructions = """
Currently this application does not come with WireGuard binaries. \
It is required to manually install these using Homebrew:

  brew install wireguard-tools

Or follow the instructions on:

  \(wireguardInstallURL)

and restart this application afterwards.
"""

let defaultBrewPrefix = "/opt/homebrew"
let defaultConfigPath = "/etc/wireguard"

enum DefaultSettings {
    static let App = [
        "showAllTunnelDetails": false,
        "showConnectedTunnelDetails": true,
    ]
    static let Helper = [
        // Prefix path for etc/wireguard, bin/wg, bin/wireguard-go and bin/bash (bash 4),
        // can be overridden by the user via root defaults to allow custom location for Homebrew.
        "brewPrefix": defaultBrewPrefix,
        "wgquickBinPath": "",
    ]
}
