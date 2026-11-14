import AppKit
import ApplicationServices
import XCTest
@testable import OpenSelection

@MainActor
final class ChatGPTCopySafetyTests: XCTestCase {
    func testStaticTextDragWithoutAXSelectionRequiresEnabledCopy() async {
        for length in [nil, 0] as [Int?] {
            var range = CFRange(location: 0, length: length ?? 0)
            let target = AXElementInspector.Target(
                role: "AXStaticText",
                selectedTextRange: length == nil ? nil : AXValueCreate(.cfRange, &range)
            )
            let evidence = SelectionRetrievalCoordinator.copyEvidence(
                .keyboardCopy, target: target, cursor: .beam,
                bundleID: "com.openai.chat", isFallbackFromAX: true, trigger: .dragEnd
            )
            XCTAssertEqual(evidence?.strength, .weak,
                           "A drag over static text is intent, not proof of selected text")
            guard let evidence else { return XCTFail("Expected weak text context") }
            let board = NSPasteboard(name: .init("com.openselection.tests.chatgpt.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.setString("Clipboard sentinel", forType: .string)
            let changeCount = board.changeCount
            let response = await AutomaticCopyCapture.captureResponse(
                request: CopyRequest(trigger: { XCTFail("Must not post Copy without selection proof") },
                                     evidence: evidence, requiresEnabledCopyMenu: true),
                pasteboard: board, frontmostPID: { 42 }, menuState: { _ in .disabled },
                overlayPresent: { false }
            )
            XCTAssertNil(response.result)
            XCTAssertEqual(board.changeCount, changeCount)
            XCTAssertEqual(board.string(forType: .string), "Clipboard sentinel")
        }
    }

    func testStaticTextWithActualSelectionHasStrongEvidence() {
        for bundleID in ["com.openai.chat", "com.test.reader"] {
            let evidence = SelectionRetrievalCoordinator.copyEvidence(
                .keyboardCopy, target: AXElementInspector.Target(role: "AXStaticText", selectedText: "Selected fixture"),
                cursor: .beam, bundleID: bundleID, isFallbackFromAX: true, trigger: .dragEnd
            )
            XCTAssertEqual(evidence?.strength, .strong)
            XCTAssertEqual(evidence?.reason, "ax-selected-text")
        }
    }

    func testStaticTextInListGestureUsesEnabledMenuGate() async {
        for trigger: TriggerSource in [.dragEnd, .doubleClick] {
            for menu: CopyMenuState in [.enabled, .disabled] {
                let fixture = StaticTextCopyFixture(menu: menu)
                defer { fixture.board.releaseGlobally() }
                let target = AXElementInspector.Target(
                    role: "AXStaticText",
                    containedInRoles: ["AXApplication", "AXGroup", "AXList", "AXScrollArea", "AXSplitGroup", "AXWindow"]
                )
                let coordinator = SelectionRetrievalCoordinator(
                    inspect: { target },
                    copyCapture: { request in await fixture.capture(request) }
                )
                let result = await coordinator.retrieve(
                    for: AppIdentity(bundleIdentifier: "com.openai.chat"),
                    policy: SelectionPolicy(retrievalMode: .keyboardCopy),
                    cursor: .beam,
                    trigger: trigger
                )
                XCTAssertEqual(fixture.requests, 1)
                XCTAssertEqual(result?.text, menu == .enabled ? "Selected fixture" : nil)
                XCTAssertEqual(fixture.copies, menu == .enabled ? 1 : 0)
                XCTAssertEqual(fixture.board.string(forType: .string), "Clipboard sentinel")
            }
        }
    }

    func testStaticListWithoutWebSurfaceAvoidsWebSettleRetriesAndKeepsCopyGate() async {
        for trigger: TriggerSource in [.dragEnd, .doubleClick] {
            for menu: CopyMenuState in [.enabled, .disabled, .unknown(.timeout)] {
                let fixture = StaticTextCopyFixture(menu: menu)
                defer { fixture.board.releaseGlobally() }
                let count = InspectionCount()
                let coordinator = SelectionRetrievalCoordinator(
                    inspect: {
                        count.value += 1
                        return AXElementInspector.Target(role: "AXStaticText", containedInRoles: ["AXList"])
                    },
                    copyCapture: { request in await fixture.capture(request) }
                )
                let result = await coordinator.retrieve(
                    for: AppIdentity(bundleIdentifier: "com.test.document"),
                    policy: SelectionPolicy(retrievalMode: .axWebArea),
                    cursor: .beam, trigger: trigger
                )
                XCTAssertEqual(count.value, 1, "No web surface exists to settle; do not repeat inspection")
                XCTAssertEqual(result?.text, menu == .enabled ? "Selected fixture" : nil)
                XCTAssertEqual(fixture.copies, menu == .enabled ? 1 : 0)
                XCTAssertEqual(fixture.board.string(forType: .string), "Clipboard sentinel")
            }
        }
    }

    func testAXOnlyStaticListStillWaitsForDelayedSelection() async {
        let count = InspectionCount()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: {
                count.value += 1
                return AXElementInspector.Target(role: "AXStaticText", containedInRoles: ["AXList"],
                    selectedText: count.value >= 3 ? "Delayed AX selection" : nil)
            },
            copyCapture: { _ in XCTFail("Copy fallback is forbidden"); return nil }
        )
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.document"),
            policy: SelectionPolicy(retrievalMode: .axWebArea), cursor: .beam,
            allowCopyFallback: false, trigger: .dragEnd
        )
        XCTAssertEqual(result?.text, "Delayed AX selection")
        XCTAssertEqual(count.value, 3)
    }

    func testStaticTextListExceptionDoesNotAuthorizeOtherSurfacesOrGestures() {
        for cursor: CursorClass in [.arrow, .pointingHand, .unknown] {
            XCTAssertNil(SelectionRetrievalCoordinator.copyEvidence(
                .keyboardCopy, target: AXElementInspector.Target(role: "AXStaticText", containedInRoles: ["AXList"]),
                cursor: cursor, trigger: .dragEnd
            ))
        }
        for role in ["AXList", "AXRow", "AXImage", "AXCollection"] {
            XCTAssertNil(SelectionRetrievalCoordinator.copyEvidence(
                .keyboardCopy, target: AXElementInspector.Target(role: role, containedInRoles: ["AXList"]),
                cursor: .beam, trigger: .dragEnd
            ))
        }
        for ancestor in ["AXImage", "AXCollection", "AXRow", "AXCell", "AXTable", "AXOutline", "AXGrid"] {
            XCTAssertNil(SelectionRetrievalCoordinator.copyEvidence(
                .keyboardCopy, target: AXElementInspector.Target(role: "AXStaticText", containedInRoles: ["AXList", ancestor]),
                cursor: .beam, trigger: .dragEnd
            ))
        }
        for trigger: TriggerSource in [.programmatic, .keyboardShortcut, TriggerSource(raw: "mouseHold")] {
            XCTAssertNil(SelectionRetrievalCoordinator.copyEvidence(
                .keyboardCopy, target: AXElementInspector.Target(role: "AXStaticText", containedInRoles: ["AXList"]),
                cursor: .beam, trigger: trigger
            ))
        }
    }
}

@MainActor
private final class StaticTextCopyFixture {
    let menu: CopyMenuState
    let board = NSPasteboard(name: .init("com.openselection.tests.static-list.\(UUID().uuidString)"))
    var requests = 0
    var copies = 0

    init(menu: CopyMenuState) {
        self.menu = menu
        board.setString("Clipboard sentinel", forType: .string)
    }

    func capture(_ request: CopyRequest) async -> SelectionResult? {
        requests += 1
        XCTAssertEqual(request.evidence.strength, .weak)
        XCTAssertTrue(request.requiresEnabledCopyMenu)
        return await AutomaticCopyCapture.capture(
            request: CopyRequest(trigger: {
                self.copies += 1
                self.board.clearContents()
                self.board.setString("Selected fixture", forType: .string)
            }, evidence: request.evidence, requiresEnabledCopyMenu: request.requiresEnabledCopyMenu),
            pasteboard: board, frontmostPID: { 42 }, menuState: { _ in self.menu }, overlayPresent: { false }
        )
    }
}

private final class InspectionCount: @unchecked Sendable { var value = 0 }
