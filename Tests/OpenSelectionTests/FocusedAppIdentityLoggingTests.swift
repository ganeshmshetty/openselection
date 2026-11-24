import ApplicationServices
import os
import XCTest
@testable import OpenSelection

final class FocusedAppIdentityLoggingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DiagnosticsHub.shared.reset()
    }

    override func tearDown() {
        DiagnosticsHub.shared.reset()
        super.tearDown()
    }

    func testUnavailableFocusedPIDIsLoggedWithRequestedIdentity() async {
        final class EventSink: OpenSelectionDiagnosticsSink, @unchecked Sendable {
            let minimumLevel: LogLevel = .trace
            let lock = OSAllocatedUnfairLock<[DiagnosticEvent]>(initialState: [])

            func record(_ event: DiagnosticEvent) {
                lock.withLock { $0.append(event) }
            }

            var events: [DiagnosticEvent] {
                lock.withLock { $0 }
            }
        }

        let sink = EventSink()
        DiagnosticsHub.shared.install(sink)

        let coordinator = SelectionRetrievalCoordinator(
            inspect: { _ in
                // AXUIElementGetPid fails for this element, which is the unreadable-identity path.
                AXElementInspector.Target(
                    focusedApp: AXUIElementCreateApplication(-1),
                    role: "AXTextField",
                    selectedText: "selected text"
                )
            },
            copyCapture: { _ in nil }
        )

        _ = await coordinator.retrieveResponse(
            for: AppIdentity(bundleIdentifier: "com.test.app", processIdentifier: 1234),
            policy: SelectionPolicy(),
            cursor: .beam
        )
        await DiagnosticsHub.shared.flush()

        let event = sink.events.first {
            $0.message == "focused app accepted"
                && $0.fields["focusedPID"] == .token("unavailable")
        }
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.fields["requestedPID"], .int(1234))
        XCTAssertEqual(event?.fields["focusedBundle"], .token("unknown"))
    }
}
