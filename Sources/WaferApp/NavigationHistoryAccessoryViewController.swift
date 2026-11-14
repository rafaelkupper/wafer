import AppKit

/// Leading titlebar accessory hosting the back/forward history chevrons,
/// styled with the same palette tokens as the statistics icon buttons.
@MainActor
final class NavigationHistoryAccessoryViewController: NSTitlebarAccessoryViewController, ThemeApplying {
    private let backButton = TitlebarAccessoryIconButtonView(symbolName: "chevron.left")
    private let forwardButton = TitlebarAccessoryIconButtonView(symbolName: "chevron.right")

    var onGoBack: (() -> Void)?
    var onGoForward: (() -> Void)?

    #if DEBUG
    var backButtonIsEnabledForTesting: Bool {
        backButton.isEnabled
    }

    var backButtonForTesting: TitlebarAccessoryIconButtonView {
        backButton
    }

    var forwardButtonIsEnabledForTesting: Bool {
        forwardButton.isEnabled
    }
    #endif

    private let containerView = NSView()

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .left
        fullScreenMinHeight = TitlebarAccessoryIconButtonView.defaultSize.height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        backButton.accessibilityLabelText = "Back"
        forwardButton.accessibilityLabelText = "Forward"
        backButton.onActivate = { [weak self] in
            self?.onGoBack?()
        }
        forwardButton.onActivate = { [weak self] in
            self?.onGoForward?()
        }

        // Titlebar accessories size from their root view's FRAME; a root with
        // a zero frame collapses invisibly (left accessories especially never
        // receive a layout pass before display). Keep the root frame-based
        // with an explicit size and pin the stack inside with constraints.

        let stackView = NSStackView(views: [backButton, forwardButton])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 6
        stackView.translatesAutoresizingMaskIntoConstraints = false
        backButton.setContentHuggingPriority(.required, for: .horizontal)
        forwardButton.setContentHuggingPriority(.required, for: .horizontal)

        containerView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -4),
            stackView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
        ])
        containerView.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: containerView.fittingSize.width,
                height: max(containerView.fittingSize.height, TitlebarAccessoryIconButtonView.defaultSize.height + 6)
            )
        )
        view = containerView

        setNavigationState(canGoBack: false, canGoForward: false)
        applyCurrentTheme()
    }

    func setNavigationState(canGoBack: Bool, canGoForward: Bool) {
        loadViewIfNeeded()
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
    }

    #if DEBUG
    func triggerBackForTesting() {
        guard backButton.isEnabled else {
            return
        }
        backButton.onActivate?()
    }

    func triggerForwardForTesting() {
        guard forwardButton.isEnabled else {
            return
        }
        forwardButton.onActivate?()
    }
    #endif

    func applyCurrentTheme() {
        backButton.applyCurrentTheme()
        forwardButton.applyCurrentTheme()
    }
}
