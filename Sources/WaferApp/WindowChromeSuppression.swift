import AppKit
import WaferCore

@MainActor
enum WindowChromeSuppression {
    static func suppress(in window: NSWindow) {
        guard let frameView = window.contentView?.superview else { return }
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = ReaderTheme.backgroundColor.cgColor

        // Private AppKit decoration is optional. Unknown OS layouts keep the
        // public transparent-titlebar styling supplied by the window controller.
        guard supportsPrivateDecoration(on: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) else { return }
        for subview in frameView.subviews where subview !== window.contentView {
            styleDecorationTree(subview, topLevel: true)
        }
    }

    static func supportsPrivateDecoration(on majorVersion: Int) -> Bool {
        [14, 15, 26, 27].contains(majorVersion)
    }

    private static func styleDecorationTree(_ view: NSView, topLevel: Bool) {
        let className = NSStringFromClass(type(of: view))
        let superviewName = view.superview.map { NSStringFromClass(type(of: $0)) }
        applyFlatBackgroundIfNeeded(to: view, named: className, superviewName: superviewName)
        if shouldHideView(named: className, topLevel: topLevel) { view.isHidden = true }
        for child in view.subviews { styleDecorationTree(child, topLevel: false) }
    }

    static func shouldHideView(named className: String, topLevel: Bool) -> Bool {
        if topLevel && className == "NSVisualEffectView" {
            return true
        }

        if className == "_NSTitlebarDecorationView" || className == "NSTitlebarBackgroundView" {
            return true
        }

        return className.contains("ScrollPocket")
    }

    static func shouldStyleView(named className: String, superviewName: String?) -> Bool {
        if className == "NSTitlebarContainerView" || className == "NSTitlebarView" {
            return true
        }

        return className == "NSView" && superviewName == "NSTitlebarView"
    }

    private static func applyFlatBackgroundIfNeeded(to view: NSView, named className: String, superviewName: String?) {
        guard shouldStyleView(named: className, superviewName: superviewName) else {
            return
        }

        view.wantsLayer = true
        view.layer?.backgroundColor = ReaderTheme.backgroundColor.cgColor
    }

}
