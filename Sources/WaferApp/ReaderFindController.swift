import AppKit
import WebKit

@MainActor
final class ReaderFindController: NSObject, NSSearchFieldDelegate, NSUserInterfaceValidations {
    enum FindDirection {
        case next
        case previous
    }

    typealias Find = (String, WKFindConfiguration, @escaping @MainActor (Bool) -> Void) -> Void
    let bar = ReaderFindBarView()
    private let find: Find
    private let clearSelection: (String) -> Void
    private let focusContent: () -> Void
    #if DEBUG
    var suppressFindExecutionForTesting = false
    var suppressedFindMatchResultForTesting: Bool?
    private(set) var lastFindQueryForTesting: String?
    private(set) var lastFindDirectionForTesting: String?
    private(set) var lastFindMatchFoundForTesting: Bool?
    #endif

    init(find: @escaping Find, clearSelection: @escaping (String) -> Void, focusContent: @escaping () -> Void) {
        self.find = find
        self.clearSelection = clearSelection
        self.focusContent = focusContent
        super.init()
        bar.configure(target: self, delegate: self)
        updateFindStatus(nil)
    }

    @objc func showFindInterface(_ sender: Any?) {
        ensureFindBarVisible()
        bar.window?.makeFirstResponder(bar.searchField)
        bar.searchField.selectText(nil)
    }

    @objc func findNextMatch(_ sender: Any?) {
        guard !normalizedFindQuery().isEmpty else {
            showFindInterface(sender)
            updateFindStatus(nil)
            return
        }

        ensureFindBarVisible()
        performFind(direction: .next)
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        guard !normalizedFindQuery().isEmpty else {
            showFindInterface(sender)
            updateFindStatus(nil)
            return
        }

        ensureFindBarVisible()
        performFind(direction: .previous)
    }

    @objc func hideFindInterface(_ sender: Any?) {
        bar.isHidden = true
        updateFindStatus(nil)
        clearBrowserSelection()
        focusContent()
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(showFindInterface(_:)):
            return true
        case #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)):
            return !normalizedFindQuery().isEmpty
        default:
            return true
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === bar.searchField else {
            return
        }

        if normalizedFindQuery().isEmpty {
            #if DEBUG
            lastFindQueryForTesting = nil
            lastFindMatchFoundForTesting = nil
            #endif
            updateFindStatus(nil)
            clearBrowserSelection()
            return
        }

        performFind(direction: .next)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === bar.searchField else {
            return false
        }

        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            hideFindInterface(control)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            findNextMatch(control)
            return true
        default:
            return false
        }
    }

    private func ensureFindBarVisible() {
        bar.isHidden = false
    }

    private func normalizedFindQuery() -> String {
        bar.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func performFind(direction: FindDirection) {
        let query = normalizedFindQuery()
        guard !query.isEmpty else {
            updateFindStatus(nil)
            return
        }

        #if DEBUG
        lastFindQueryForTesting = query
        lastFindDirectionForTesting = direction == .previous ? "previous" : "next"
        #endif

        #if DEBUG
        if suppressFindExecutionForTesting {
            let matchFound = suppressedFindMatchResultForTesting ?? true
            lastFindMatchFoundForTesting = matchFound
            updateFindStatus(matchFound ? nil : "No matches")
            return
        }

        #endif

        let configuration = WKFindConfiguration()
        configuration.backwards = direction == .previous
        configuration.wraps = true
        configuration.caseSensitive = false
        find(query, configuration) { [weak self] matchFound in
            guard let self else {
                return
            }

            #if DEBUG
            self.lastFindMatchFoundForTesting = matchFound
            #endif
            self.updateFindStatus(matchFound ? nil : "No matches")
        }
    }

    private func updateFindStatus(_ text: String?) {
        bar.statusLabel.stringValue = text ?? ""
        bar.statusLabel.isHidden = text == nil || text?.isEmpty == true
    }

    private func clearBrowserSelection() {
        clearSelection("""
        (function() {
          const selection = window.getSelection && window.getSelection();
          if (selection) {
            selection.removeAllRanges();
          }
          return true;
        })();
        """)
    }

}
