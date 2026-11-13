import AppKit

@MainActor
protocol ThemeApplying: AnyObject {
    func applyCurrentTheme()
}

@MainActor
extension NSView {
    func applyCurrentThemeRecursively() {
        (self as? ThemeApplying)?.applyCurrentTheme()
        subviews.forEach { $0.applyCurrentThemeRecursively() }
    }
}
