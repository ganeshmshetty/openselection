import AppKit
import XCTest
@testable import OpenSelection

@MainActor
final class MenuLessCopyTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: .init("com.openselection.tests.menu-less.\(UUID().uuidString)"))
        board.setString("Original clipboard", forType: .string)
        return board
    }

    /// CEF/Electron-style wrappers (Viber) keep no Edit ▸ Copy item, so the probe reports
    /// `noCopyItem` — an absent command, not a disabled one. Refusing there leaves the app with
    /// no read path; the trigger still snapshots and restores the clipboard around the copy.
    func testNoCopyItemProceedsUnderWeakEvidence() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                board.clearContents()
                board.setString("Selected text", forType: .string)
            },
            evidence: CopyEvidence("beam-cursor+text-control", .weak),
            requiresEnabledCopyMenu: true
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

    func testDisabledAndInconclusiveMenuStatesStillBlock() async {
        for state: CopyMenuState in [.disabled, .unknown(.timeout), .unknown(.unreadable)] {
            let board = pasteboard()
            defer { board.releaseGlobally() }
            var triggers = 0
            let request = CopyRequest(
                trigger: { triggers += 1 },
                evidence: CopyEvidence("beam-cursor+text-control", .weak),
                requiresEnabledCopyMenu: true
            )
            let result = await AutomaticCopyCapture.capture(
                request: request,
                pasteboard: board,
                frontmostPID: { 42 },
                menuState: { _ in state },
                overlayPresent: { false }
            )
            XCTAssertNil(result, "\(state)")
            XCTAssertEqual(triggers, 0, "\(state)")
            XCTAssertEqual(board.string(forType: .string), "Original clipboard", "\(state)")
        }
    }
}
