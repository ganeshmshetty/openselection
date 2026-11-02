import XCTest
import AppKit
import os
@testable import OpenSelection

@MainActor
final class AutomaticCopyCaptureTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: .init("com.openselection.tests.automatic-copy.\(UUID().uuidString)"))
        board.setString("Original clipboard", forType: .string)
        return board
    }

    func testDisabledMenuWithWeakEvidenceDoesNotTriggerOrTouchClipboard() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let changeCount = board.changeCount
        let request = CopyRequest(
            trigger: { XCTFail("A disabled Copy command with weak evidence must never be triggered") },
            evidence: CopyEvidence("test-weak", .weak)
        )
        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .disabled },
            overlayPresent: { false }
        )
        XCTAssertNil(result)
        XCTAssertEqual(board.changeCount, changeCount)
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testStrongEvidenceProceedsEvenIfMenuIsDisabled() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                board.clearContents()
                board.setString("Selected text", forType: .string)
            },
            evidence: CopyEvidence("test-strong", .strong)
        )
        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in
                XCTFail("Menu probe must NOT be consulted for strong evidence")
                return .disabled
            },
            overlayPresent: { false }
        )
        XCTAssertEqual(triggers, 1)
        XCTAssertEqual(result?.text, "Selected text")
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testStrongAXEvidenceBypassesStrictWeakMenuRequirement() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                board.clearContents()
                board.setString("Selected text", forType: .string)
            },
            evidence: CopyEvidence("ax-selected-text", .strong),
            requiresEnabledCopyMenu: true
        )

        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in
                XCTFail("Strong selected-text evidence must bypass the menu probe")
                return .unknown(.timeout)
            },
            overlayPresent: { false }
        )

        XCTAssertEqual(result?.text, "Selected text")
        XCTAssertEqual(triggers, 1)
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    /// Waived evidence is an explicit request, not proof of a selection. It is still weak context,
    /// so a target whose Copy command is disabled must not receive the event: that is what AppKit
    /// answers with its alert sound.
    func testWaivedEvidenceRefusesDisabledCopyCommand() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let changeCount = board.changeCount
        let response = await AutomaticCopyCapture.captureResponse(
            request: CopyRequest(
                trigger: { XCTFail("A disabled Copy command must not be triggered by a waiver") },
                evidence: CopyEvidence("waived-explicit-request", .weak),
                evidenceRequirement: .waived
            ),
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .disabled },
            overlayPresent: { false }
        )
        XCTAssertNil(response.result)
        XCTAssertEqual(response.status, .copyBlocked)
        XCTAssertEqual(board.changeCount, changeCount)
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    /// "Couldn't tell" is not "disabled": a terminal omits the Copy item entirely. The permissive
    /// legacy handling still proceeds there, while an explicit request can demand a confirmed
    /// command — the two knobs are independent.
    func testWaivedEvidenceHandlesUnknownMenuByRequirement() async {
        func capture(strict: Bool) async -> (result: SelectionResult?, triggers: Int) {
            let board = pasteboard()
            defer { board.releaseGlobally() }
            final class Counter: @unchecked Sendable { var value = 0 }
            let counter = Counter()
            let request = CopyRequest(
                trigger: {
                    counter.value += 1
                    board.clearContents()
                    board.setString("Selected text", forType: .string)
                },
                evidence: CopyEvidence("waived-explicit-request", .weak),
                evidenceRequirement: .waived,
                requiresEnabledCopyMenu: strict
            )
            let result = await AutomaticCopyCapture.capture(
                request: request,
                pasteboard: board,
                frontmostPID: { 42 },
                menuState: { _ in .unknown(.noCopyItem) },
                overlayPresent: { false }
            )
            return (result, counter.value)
        }

        let permissive = await capture(strict: false)
        XCTAssertEqual(permissive.triggers, 1, "an unreadable menu is not a disabled one")
        XCTAssertEqual(permissive.result?.text, "Selected text")

        let strict = await capture(strict: true)
        XCTAssertEqual(strict.triggers, 0, "a strict caller requires a confirmed enabled command")
        XCTAssertNil(strict.result)
    }

    /// A waiver is not proof of a selection: it never bypasses the Copy command check, even if a
    /// caller attaches strong marker evidence to it.
    func testWaivedRequestAlwaysConsultsTheCopyMenu() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let changeCount = board.changeCount
        let response = await AutomaticCopyCapture.captureResponse(
            request: CopyRequest(
                trigger: { XCTFail("A waived request must still be vouched for by the Copy command") },
                evidence: CopyEvidence("waived-explicit-request", .strong),
                evidenceRequirement: .waived,
                requiresEnabledCopyMenu: true
            ),
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .disabled },
            overlayPresent: { false }
        )
        XCTAssertNil(response.result)
        XCTAssertEqual(response.status, .copyBlocked)
        XCTAssertEqual(board.changeCount, changeCount)
    }

    func testEnabledMenuCapturesAndRestoresClipboard() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                board.clearContents()
                board.setString("Selected text", forType: .string)
            },
            evidence: CopyEvidence("test-weak", .weak)
        )
        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { pid in
                XCTAssertEqual(pid, 42)
                return .enabled
            },
            overlayPresent: { false }
        )
        XCTAssertEqual(triggers, 1)
        XCTAssertEqual(result?.text, "Selected text")
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testUnknownMenuStateProceedsWithWeakEvidence() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                board.clearContents()
                board.setString("Selected text", forType: .string)
            },
            evidence: CopyEvidence("test-weak", .weak)
        )
        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .unknown(.timeout) },
            overlayPresent: { false }
        )
        XCTAssertEqual(triggers, 1)
        XCTAssertEqual(result?.text, "Selected text")
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testStrictWeakEvidenceRequiresEnabledMenuBeforeTouchingClipboard() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let changeCount = board.changeCount
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                XCTFail("Unknown menu state must not trigger copy for automatic retrieval")
            },
            evidence: CopyEvidence("ax-text-control", .weak),
            requiresEnabledCopyMenu: true
        )

        let response = await AutomaticCopyCapture.captureResponse(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .unknown(.timeout) },
            overlayPresent: { false }
        )

        XCTAssertNil(response.result)
        XCTAssertEqual(response.status, .copyBlocked)
        XCTAssertEqual(triggers, 0)
        XCTAssertEqual(board.changeCount, changeCount)
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    /// A blocked Chromium read must say why in a default (debug-level) log dump, not only at trace.
    func testMenuGateBlockIsLoggedAtDebugWithStateAndEvidence() async {
        final class DebugSink: OpenSelectionDiagnosticsSink, @unchecked Sendable {
            let minimumLevel: LogLevel = .debug
            let events = OSAllocatedUnfairLock<[DiagnosticEvent]>(initialState: [])
            func record(_ event: DiagnosticEvent) { events.withLock { $0.append(event) } }
            func finish(_ report: CascadeReport) {}
        }
        DiagnosticsHub.shared.reset()
        let sink = DebugSink()
        DiagnosticsHub.shared.install(sink)
        defer { DiagnosticsHub.shared.reset() }
        let board = pasteboard()
        defer { board.releaseGlobally() }

        let response = await AutomaticCopyCapture.captureResponse(
            request: CopyRequest(trigger: {}, evidence: CopyEvidence("selection-gesture:dragEnd", .weak),
                                 requiresEnabledCopyMenu: true),
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .disabled },
            overlayPresent: { false }
        )
        await DiagnosticsHub.shared.flush()

        XCTAssertEqual(response.status, .copyBlocked)
        let blocked = sink.events.withLock { $0 }.first { $0.message.contains("without enabled Copy command") }
        XCTAssertEqual(blocked?.level, .debug)
        XCTAssertNotNil(blocked?.fields["menuState"])
        XCTAssertNotNil(blocked?.fields["evidence"])
    }

    func testStrictWeakEvidenceStillRunsWhenMenuEnabled() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                board.clearContents()
                board.setString("Selected text", forType: .string)
            },
            evidence: CopyEvidence("ax-text-control", .weak),
            requiresEnabledCopyMenu: true
        )

        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .enabled },
            overlayPresent: { false }
        )

        XCTAssertEqual(result?.text, "Selected text")
        XCTAssertEqual(triggers, 1)
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testIssue159CoordinatorEmptyTextFieldWithUnknownMenuNeverCopies() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let originalChangeCount = board.changeCount
        let boardBox = PasteboardBox(board)
        let configuration = SelectionConfiguration(evidenceSettleMaxRetries: 0)
        let target = AXElementInspector.Target(role: "AXTextArea")
        let coordinator = SelectionRetrievalCoordinator(
            configuration: configuration,
            inspect: { target },
            detailedCopyCapture: { request in
                await AutomaticCopyCapture.captureResponse(
                    configuration: configuration,
                    request: request,
                    pasteboard: boardBox.pasteboard,
                    frontmostPID: { 42 },
                    menuState: { _ in .unknown(.timeout) },
                    overlayPresent: { false }
                )
            }
        )

        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.microsoft.Outlook"),
            policy: SelectionPolicy(strategy: .keyboardCopy),
            cursor: .unknown,
            trigger: .doubleClick
        )

        XCTAssertNil(result)
        XCTAssertEqual(board.changeCount, originalChangeCount)
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testNoCopyItemMenuStateProceedsWithWeakEvidence() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                board.clearContents()
                board.setString("Selected text", forType: .string)
            },
            evidence: CopyEvidence("test-weak", .weak)
        )
        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .unknown(.noCopyItem) },
            overlayPresent: { false }
        )
        XCTAssertEqual(triggers, 1)
        XCTAssertEqual(result?.text, "Selected text")
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testNoMenuBarMenuStateProceedsWithWeakEvidence() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                board.clearContents()
                board.setString("Selected text", forType: .string)
            },
            evidence: CopyEvidence("test-weak", .weak)
        )
        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .unknown(.noMenuBar) },
            overlayPresent: { false }
        )
        XCTAssertEqual(triggers, 1)
        XCTAssertEqual(result?.text, "Selected text")
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testAppSwitchDuringProbeDoesNotCopyIntoNewApp() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let changeCount = board.changeCount
        var pid: pid_t = 42
        let request = CopyRequest(
            trigger: { XCTFail("The old gesture must not send Copy to the new app") },
            evidence: CopyEvidence("test-weak", .weak)
        )
        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { pid },
            menuState: { _ in
                pid = 43
                return .enabled
            },
            overlayPresent: { false }
        )
        XCTAssertNil(result)
        XCTAssertEqual(board.changeCount, changeCount)
    }

    func testCancellationDuringProbeDoesNotTriggerCopy() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let changeCount = board.changeCount
        let task = Task { @MainActor in
            let request = CopyRequest(
                trigger: { XCTFail("A cancelled gesture must not trigger Copy") },
                evidence: CopyEvidence("test-weak", .weak)
            )
            return await AutomaticCopyCapture.capture(
                request: request,
                pasteboard: board,
                frontmostPID: { 42 },
                menuState: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .enabled
                },
                overlayPresent: { false }
            )
        }
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(board.changeCount, changeCount)
    }

    func testEnabledCopyStillRespectsForeignOverlayGate() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let changeCount = board.changeCount
        let request = CopyRequest(
            trigger: { XCTFail("An overlay must not receive the copy shortcut") },
            evidence: CopyEvidence("test-weak", .weak)
        )
        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .enabled },
            overlayPresent: { true }
        )
        XCTAssertNil(result)
        XCTAssertEqual(board.changeCount, changeCount)
    }

    func testCopyMenuProbeEnforcesDeadlineWhenWorkerBlocks() async {
        let probe = CopyMenuProbe()
        let start = Date()
        let result = await probe.run(hardLimit: 0.05, fallback: "fallback") {
            Thread.sleep(forTimeInterval: 0.5)
            return "finished"
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result, "fallback")
        XCTAssertLessThan(elapsed, 0.25, "watchdog must enforce deadline even if worker blocks queue")
    }
    func testCopyMenuWorkerRetainsPermitAfterDeadline() async {
        let probe = CopyMenuProbe()
        probe.maxConcurrent = 1
        let unblock = DispatchSemaphore(value: 0)
        defer { unblock.signal() }
        let first = await probe.run(hardLimit: 0.03, fallback: false) {
            unblock.wait()
            return true
        }
        XCTAssertFalse(first)
        let capped = await probe.run(hardLimit: 0.03, fallback: false) {
            XCTFail("A timed-out worker must retain its permit")
            return true
        }
        XCTAssertFalse(capped)
        unblock.signal()
        try? await Task.sleep(nanoseconds: 30_000_000)
        let recovered = await probe.run(hardLimit: 0.1, fallback: false) { true }
        XCTAssertTrue(recovered)
    }

}

private final class PasteboardBox: @unchecked Sendable {
    let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }
}
