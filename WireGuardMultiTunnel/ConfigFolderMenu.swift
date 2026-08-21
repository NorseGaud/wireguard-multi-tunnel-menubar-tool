import Cocoa

func normalizedConfigDirectory(_ path: String?) -> String? {
    guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
        return nil
    }
    guard path.hasPrefix("/"), !path.contains("..") else {
        return nil
    }
    return path
}

func configDirectoryURL(from path: String) -> URL? {
    guard let normalized = normalizedConfigDirectory(path) else {
        return nil
    }
    return URL(fileURLWithPath: normalized, isDirectory: true)
}

func buildConfigFolderMenuItems(
    configDirectory: String?,
    target: AnyObject?,
    action: Selector?
) -> [NSMenuItem] {
    guard let path = normalizedConfigDirectory(configDirectory) else {
        return []
    }

    let separator = NSMenuItem.separator()
    separator.tag = MenuItemTypes.configFolder.rawValue

    let pathTitle = "Config folder: \(path.truncated(limit: maxMenuItemChars, position: .middle))"
    let pathItem = NSMenuItem(title: pathTitle, action: nil, keyEquivalent: "")
    pathItem.toolTip = path
    pathItem.isEnabled = false
    pathItem.tag = MenuItemTypes.configFolder.rawValue

    let openItem = NSMenuItem(title: "Open Folder", action: action, keyEquivalent: "")
    openItem.target = target
    openItem.tag = MenuItemTypes.configFolder.rawValue
    openItem.isEnabled = true

    return [separator, pathItem, openItem]
}
