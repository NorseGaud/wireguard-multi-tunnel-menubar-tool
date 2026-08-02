import Cocoa

/// Compact menu switch that paints green when on (system NSSwitch follows accent/graphite).
final class TunnelMenuSwitch: NSControl {
    var tunnelName = ""
    /// Currently only `enabled`
    var controlKind = ""

    private var switchState: NSControl.StateValue = .off

    var state: NSControl.StateValue {
        get { switchState }
        set {
            switchState = newValue
            needsDisplay = true
        }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 38, height: 22)
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with _: NSEvent) {
        guard isEnabled else { return }
        let nextOn = state != .on
        if let row = superview as? TunnelSwitchMenuItemView {
            row.setSwitchOn(nextOn)
        } else {
            state = nextOn ? .on : .off
        }
        sendAction(action, to: target)
    }

    override func draw(_: NSRect) {
        let trackHeight: CGFloat = 16
        let trackWidth: CGFloat = 34
        let trackRect = NSRect(
            x: bounds.midX - trackWidth / 2,
            y: bounds.midY - trackHeight / 2,
            width: trackWidth,
            height: trackHeight
        )
        let radius = trackHeight / 2
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius)

        let onColor = NSColor.systemGreen
        let offColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.35)
        let fill = state == .on ? onColor : offColor
        (isEnabled ? fill : fill.withAlphaComponent(0.45)).setFill()
        trackPath.fill()

        let knobDiameter: CGFloat = 12
        let inset: CGFloat = 2
        let knobX = state == .on
            ? trackRect.maxX - knobDiameter - inset
            : trackRect.minX + inset
        let knobRect = NSRect(
            x: knobX,
            y: trackRect.midY - knobDiameter / 2,
            width: knobDiameter,
            height: knobDiameter
        )
        let knobPath = NSBezierPath(ovalIn: knobRect)
        NSColor.white.setFill()
        knobPath.fill()
    }
}

/// Indented menu row: label + trailing switch (Enabled).
final class TunnelSwitchMenuItemView: TunnelRowMenuItemView {
    let menuSwitch: TunnelMenuSwitch
    private let titleLabel: NSTextField
    private(set) var isOnAppearance = false

    init(title: String, isOn: Bool, tunnelName: String, controlKind: String, menuWidth: CGFloat, target: AnyObject?,
         action: Selector?) {
        menuSwitch = TunnelMenuSwitch()
        titleLabel = NSTextField(labelWithString: title)
        super.init(width: menuWidth)

        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        menuSwitch.tunnelName = tunnelName
        menuSwitch.controlKind = controlKind
        menuSwitch.target = target
        menuSwitch.action = action
        menuSwitch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(menuSwitch)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: menuSwitch.leadingAnchor, constant: -8),
            menuSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            menuSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuSwitch.widthAnchor.constraint(equalToConstant: 38),
            menuSwitch.heightAnchor.constraint(equalToConstant: 22),
        ])

        setSwitchOn(isOn)
    }

    /// Keep switch knob and row label in sync (including failed optimistic toggles).
    func setSwitchOn(_ isOn: Bool) {
        menuSwitch.state = isOn ? .on : .off
        applyOnBackground(isOn: isOn)
    }

    func applyOnBackground(isOn: Bool) {
        isOnAppearance = isOn
        titleLabel.textColor = isOn ? .systemGreen : .labelColor
        needsDisplay = true
    }
}
