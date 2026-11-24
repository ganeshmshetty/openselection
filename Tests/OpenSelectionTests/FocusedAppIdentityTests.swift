import XCTest
@testable import OpenSelection

final class FocusedAppIdentityTests: XCTestCase {
    private let requested = FocusedAppIdentity.Descriptor(
        processIdentifier: 27049,
        bundleIdentifier: "dev.serafim.fast",
        bundleURL: URL(fileURLWithPath: "/Applications/yab.app")
    )

    private func accepts(_ focusedPID: pid_t?, _ focused: FocusedAppIdentity.Descriptor?) -> Bool {
        FocusedAppIdentity.accepts(requested: requested, focusedPID: focusedPID, focused: focused)
    }

    func testExactProcessAccepted() {
        XCTAssertTrue(accepts(27049, requested))
    }

    func testUnreadableFocusedPIDIsTreatedAsUnknown() {
        XCTAssertTrue(accepts(nil, nil))
    }

    func testCurrentProcessIsNotAutomaticallyAccepted() {
        let current = FocusedAppIdentity.Descriptor(
            processIdentifier: 555,
            bundleIdentifier: "com.test.host",
            bundleURL: URL(fileURLWithPath: "/Applications/TestHost.app")
        )
        XCTAssertFalse(accepts(555, current))
    }

    func testHelperInsideRequestedBundleAccepted() {
        let helper = FocusedAppIdentity.Descriptor(
            processIdentifier: 27054,
            bundleIdentifier: "dev.serafim.fast.core",
            bundleURL: URL(fileURLWithPath: "/Applications/yab.app/Contents/Frameworks/YabCore.app")
        )
        XCTAssertTrue(accepts(27054, helper))
    }

    func testSameBundleIdentifierAccepted() {
        let helper = FocusedAppIdentity.Descriptor(
            processIdentifier: 27060,
            bundleIdentifier: "dev.serafim.fast",
            bundleURL: URL(fileURLWithPath: "/Users/test/Applications/yab.app")
        )
        XCTAssertTrue(accepts(27060, helper))
    }

    func testUnrelatedAppRejected() {
        let other = FocusedAppIdentity.Descriptor(
            processIdentifier: 900,
            bundleIdentifier: "com.apple.Safari",
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app")
        )
        XCTAssertFalse(accepts(900, other))
    }

    func testPrefixLookalikeRejected() {
        let lookalike = FocusedAppIdentity.Descriptor(
            processIdentifier: 901,
            bundleIdentifier: "dev.serafim.fast.evil",
            bundleURL: URL(fileURLWithPath: "/Applications/yab.app.evil")
        )
        XCTAssertFalse(accepts(901, lookalike))
    }

    func testReportedButUnresolvedPIDRejected() {
        XCTAssertFalse(accepts(2002, nil))
    }
}
