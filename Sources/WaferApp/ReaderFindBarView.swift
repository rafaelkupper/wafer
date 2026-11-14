import AppKit
import WaferCore

@MainActor
final class ReaderFindBarView: NSView {
    let searchField = NSSearchField()
    let statusLabel = NSTextField(labelWithString: "")
    let previousButton = NSButton()
    let nextButton = NSButton()
    let closeButton = NSButton()

    func configure(target: AnyObject, delegate: NSSearchFieldDelegate) {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        isHidden = true

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = delegate
        searchField.placeholderString = "Find in Document"
        searchField.focusRingType = .none

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail

        configureFindButton(
            previousButton,
            target: target,
            symbolName: "chevron.up",
            action: #selector(ReaderFindController.findPreviousMatch(_:))
        )
        configureFindButton(
            nextButton,
            target: target,
            symbolName: "chevron.down",
            action: #selector(ReaderFindController.findNextMatch(_:))
        )
        configureFindButton(
            closeButton,
            target: target,
            symbolName: "xmark",
            action: #selector(ReaderFindController.hideFindInterface(_:))
        )

        let buttonStack = NSStackView(views: [previousButton, nextButton, closeButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 6
        buttonStack.alignment = .centerY

        let contentStack = NSStackView(views: [searchField, statusLabel, buttonStack])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 8
        contentStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 220),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
    }

    private func configureFindButton(_ button: NSButton, target: AnyObject, symbolName: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = target
        button.action = action
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }
}
