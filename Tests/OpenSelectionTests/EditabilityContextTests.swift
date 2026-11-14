import XCTest
import ApplicationServices
@testable import OpenSelection

final class EditabilityContextTests: XCTestCase {
    private func target(
        role: String?,
        valueSettable: Bool? = nil,
        textSettable: Bool? = nil,
        rangeLength: Int? = nil
    ) -> AXElementInspector.Target {
        var range: AnyObject?
        if let length = rangeLength {
            var cfRange = CFRange(location: 0, length: length)
            range = AXValueCreate(.cfRange, &cfRange)
        }
        return AXElementInspector.Target(
            role: role,
            selectedTextRange: range,
            isValueSettable: valueSettable,
            isSelectedTextSettable: textSettable
        )
    }

    /// Read-only NSTextView / text area: the role and range look editable, the settable
    /// attributes prove otherwise. This is the false positive that kept Cut visible.
    func testReadOnlyTextControlIsNotEditable() {
        let readOnly = target(role: "AXTextArea", valueSettable: false, textSettable: false, rangeLength: 4)
        XCTAssertFalse(SelectionRetrievalCoordinator.isEditableContext(readOnly))
    }

    func testSettableValueIsEditable() {
        let editable = target(role: "AXTextArea", valueSettable: true, textSettable: false)
        XCTAssertTrue(SelectionRetrievalCoordinator.isEditableContext(editable))
    }

    func testSettableSelectedTextIsEditable() {
        let editable = target(role: "AXWebArea", valueSettable: false, textSettable: true)
        XCTAssertTrue(SelectionRetrievalCoordinator.isEditableContext(editable))
    }

    func testUnknownSettableStateKeepsRoleFallback() {
        let unknown = target(role: "AXTextField")
        XCTAssertTrue(SelectionRetrievalCoordinator.isEditableContext(unknown))
    }

    /// A selection range on non-editable content (static text in a page or document) is
    /// selectable, not editable.
    func testRangeAloneIsNotEditable() {
        let staticText = target(role: "AXStaticText", rangeLength: 12)
        XCTAssertFalse(SelectionRetrievalCoordinator.isEditableContext(staticText))
    }

    func testNonTextRoleIsNotEditable() {
        XCTAssertFalse(SelectionRetrievalCoordinator.isEditableContext(target(role: "AXButton")))
        XCTAssertFalse(SelectionRetrievalCoordinator.isEditableContext(target(role: nil)))
    }
}
