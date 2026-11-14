import AppKit
import WaferCore

/// Section header for the "Linked From" backlink list at the bottom of the
/// Outline sidebar view (library mode only).
@MainActor
final class SidebarBacklinkHeaderView: NSView, ThemeApplying {
    private let titleLabel: NSTextField
    private let ruleView = NSView()

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title.uppercased())
        super.init(frame: .zero)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)

        ruleView.translatesAutoresizingMaskIntoConstraints = false
        ruleView.wantsLayer = true
        titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(ruleView)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            ruleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            ruleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ruleView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            ruleView.heightAnchor.constraint(equalToConstant: 1),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: ruleView.bottomAnchor, constant: 8),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])

        applyCurrentTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func applyCurrentTheme() {
        titleLabel.textColor = ReaderTheme.sidebarSecondaryTextColor
        ruleView.layer?.backgroundColor = ReaderTheme.sidebarChromeBorderColor.cgColor
    }
}

/// One backlink row: the linking file's title plus its linking context.
@MainActor
final class SidebarBacklinkRowView: NSView, ThemeApplying {
    private let titleLabel: NSTextField
    private let snippetLabel: NSTextField
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else {
                return
            }
            applyCurrentTheme()
        }
    }

    var onActivate: (() -> Void)?

    #if DEBUG
    var titleForTesting: String {
        titleLabel.stringValue
    }
    #endif

    init(backlink: Backlink) {
        titleLabel = NSTextField(labelWithString: backlink.sourceTitle)
        snippetLabel = NSTextField(wrappingLabelWithString: backlink.contextSnippet)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Linked from \(backlink.sourceTitle)")

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        snippetLabel.font = NSFont.systemFont(ofSize: 11)
        snippetLabel.maximumNumberOfLines = 2
        snippetLabel.translatesAutoresizingMaskIntoConstraints = false
        snippetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(titleLabel)
        addSubview(snippetLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            snippetLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            snippetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            snippetLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            snippetLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        applyCurrentTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newTrackingArea)
        trackingArea = newTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        onActivate?()
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    func applyCurrentTheme() {
        layer?.backgroundColor = isHovering
            ? ReaderTheme.sidebarHoverColor.cgColor
            : NSColor.clear.cgColor
        titleLabel.textColor = ReaderTheme.sidebarPrimaryTextColor
        snippetLabel.textColor = ReaderTheme.sidebarSecondaryTextColor
    }
}
