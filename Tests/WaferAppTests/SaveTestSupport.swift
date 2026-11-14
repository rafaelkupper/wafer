import XCTest
@testable import WaferApp

/// Legacy assertions can await completion while pumping the test run loop.
/// These helpers are test-only; production save APIs never drain a queue.
@MainActor
private func saveResult<Value>(_ operation: (@escaping @MainActor (Value) -> Void) -> Void) -> Value {
    let finished = XCTestExpectation(description: "save completion")
    var value: Value?
    operation { value = $0; finished.fulfill() }
    XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 15), .completed)
    return value!
}

@MainActor
extension MarkdownEditSession {
    func saveAndWait(_ text: String, interactive: Bool) -> Outcome {
        saveResult { save(text, interactive: interactive, completion: $0) }
    }

    func saveAndWait(_ snapshot: EditSnapshot, interactive: Bool) -> Outcome {
        saveResult { save(snapshot, interactive: interactive, completion: $0) }
    }
}

@MainActor
extension MarkdownReaderDocument {
    func flushEditsAndWait(interactive: Bool) -> Bool {
        saveResult { flushEdits(interactive: interactive, completion: $0) }
    }

    @discardableResult
    func endEditingAndWait() -> Bool {
        saveResult { endEditing(completion: $0) }
    }
}

@MainActor
extension MarkdownSaveWorker {
    func performAndWait(_ request: MarkdownSaveRequest) -> MarkdownSaveAttempt {
        saveResult { completion in
            performInBackground(request) { attempt in
                DispatchQueue.main.async { completion(attempt) }
            }
        }
    }
}
