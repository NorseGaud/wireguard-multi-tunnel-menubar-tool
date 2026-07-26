import Cocoa

/// Control graph for the Stealth preferences form (keeps StealthPreferencesView under lint limits).
final class StealthPreferencesControls {
    let tunnelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let amneziaCheckbox = NSButton(checkboxWithTitle: "AmneziaWG", target: nil, action: nil)
    let udp2rawCheckbox = NSButton(checkboxWithTitle: "udp2raw", target: nil, action: nil)
    let wstunnelCheckbox = NSButton(checkboxWithTitle: "wstunnel", target: nil, action: nil)

    let amneziaStatusLabel = NSTextField(labelWithString: "")
    let udp2rawStatusLabel = NSTextField(labelWithString: "")
    let wstunnelStatusLabel = NSTextField(labelWithString: "")

    let amneziaFieldsStack = NSStackView()
    let udp2rawFieldsStack = NSStackView()
    let wstunnelFieldsStack = NSStackView()

    let jcField = NSTextField(string: "0")
    let jminField = NSTextField(string: "0")
    let jmaxField = NSTextField(string: "0")
    let s1Field = NSTextField(string: "0")
    let s2Field = NSTextField(string: "0")
    let h1Field = NSTextField(string: "1")
    let h2Field = NSTextField(string: "2")
    let h3Field = NSTextField(string: "3")
    let h4Field = NSTextField(string: "4")

    let udpHostField = NSTextField(string: "")
    let udpPortField = NSTextField(string: "")
    let udpPasswordField = NSSecureTextField(string: "")
    let udpModePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    let wsURLField = NSTextField(string: "")
    /// When checked: omit `--tls-verify-certificate` (wstunnel v9+ default). When unchecked: verify.
    let wsTLSSkipCheckbox = NSButton(
        checkboxWithTitle: "Skip TLS certificate verification",
        target: nil,
        action: nil
    )

    let installHintsLabel = NSTextField(wrappingLabelWithString: "")

    func embed(in host: NSView, target: AnyObject, change: Selector, tunnelChange: Selector) {
        host.translatesAutoresizingMaskIntoConstraints = false

        let tunnelLabel = NSTextField(labelWithString: "Tunnel:")
        tunnelPopup.target = target
        tunnelPopup.action = tunnelChange

        for checkbox in [amneziaCheckbox, udp2rawCheckbox, wstunnelCheckbox, wsTLSSkipCheckbox] {
            checkbox.target = target
            checkbox.action = change
        }

        udpModePopup.removeAllItems()
        udpModePopup.addItems(withTitles: [
            Udp2RawSettings.RawMode.faketcp.rawValue,
            Udp2RawSettings.RawMode.udp.rawValue,
            Udp2RawSettings.RawMode.icmp.rawValue,
        ])
        udpModePopup.target = target
        udpModePopup.action = change

        let numeric = [jcField, jminField, jmaxField, s1Field, s2Field,
                       h1Field, h2Field, h3Field, h4Field, udpPortField]
        configureFields(numeric, target: target, change: change, numericWidth: 100)
        configureFields([udpHostField, wsURLField], target: target, change: change, numericWidth: nil)
        udpPasswordField.target = target
        udpPasswordField.action = change
        if let delegate = target as? NSTextFieldDelegate {
            udpPasswordField.delegate = delegate
        }

        configureStack(amneziaFieldsStack, rows: [
            ("Jc", jcField), ("Jmin", jminField), ("Jmax", jmaxField),
            ("S1", s1Field), ("S2", s2Field),
            ("H1", h1Field), ("H2", h2Field), ("H3", h3Field), ("H4", h4Field),
        ])
        configureStack(udp2rawFieldsStack, rows: [
            ("Remote host", udpHostField), ("Remote port", udpPortField),
            ("Password", udpPasswordField), ("Raw mode", udpModePopup),
        ])
        configureStack(wstunnelFieldsStack, rows: [
            ("Server URL", wsURLField),
        ])
        wstunnelFieldsStack.insertArrangedSubview(wsTLSSkipCheckbox, at: 1)

        for label in [amneziaStatusLabel, udp2rawStatusLabel, wstunnelStatusLabel] {
            label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
        }
        installHintsLabel.font = NSFont.monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular
        )
        installHintsLabel.textColor = .secondaryLabelColor
        installHintsLabel.isHidden = true

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false

        let tunnelRow = NSStackView(views: [tunnelLabel, tunnelPopup])
        tunnelRow.orientation = .horizontal
        tunnelRow.spacing = 8
        content.addArrangedSubview(tunnelRow)

        let layers = NSTextField(labelWithString: "Layers")
        layers.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        content.addArrangedSubview(layers)
        content.addArrangedSubview(layerBlock(amneziaCheckbox, amneziaStatusLabel, amneziaFieldsStack))
        content.addArrangedSubview(layerBlock(udp2rawCheckbox, udp2rawStatusLabel, udp2rawFieldsStack))
        content.addArrangedSubview(layerBlock(wstunnelCheckbox, wstunnelStatusLabel, wstunnelFieldsStack))
        content.addArrangedSubview(installHintsLabel)

        scroll.documentView = content
        host.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    private func configureFields(
        _ fields: [NSTextField],
        target: AnyObject,
        change: Selector,
        numericWidth: CGFloat?
    ) {
        for field in fields {
            if let delegate = target as? NSTextFieldDelegate {
                field.delegate = delegate
            }
            field.target = target
            field.action = change
            if let numericWidth {
                field.widthAnchor.constraint(equalToConstant: numericWidth).isActive = true
            }
        }
    }

    private func configureStack(_ stack: NSStackView, rows: [(String, NSView)]) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        for (title, control) in rows {
            stack.addArrangedSubview(labeledRow(title, control))
        }
    }

    private func layerBlock(_ checkbox: NSButton, _ status: NSTextField, _ fields: NSStackView) -> NSStackView {
        let header = NSStackView(views: [checkbox, status])
        header.orientation = .horizontal
        header.spacing = 12
        header.alignment = .centerY
        let stack = NSStackView(views: [header, fields])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func labeledRow(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }
}
