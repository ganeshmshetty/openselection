// EditabilityProbeTests.swift
// OpenSelectionTests
import XCTest
@testable import OpenSelection

final class EditabilityProbeTests: XCTestCase {
    func testProbeReturnsLookupResult() async {
        let probe = EditabilityProbe(lookup: { _ in true })
        let result = await probe.probe()
        XCTAssertEqual(result, true)
    }

    func testProbeReturnsNilWhenFocusedElementIsUnavailable() async {
        let probe = EditabilityProbe(lookup: { _ in nil })
        let result = await probe.probe()
        XCTAssertNil(result)
    }

    func testProbeRespectsDeadlineWatchdog() async {
        let probe = EditabilityProbe(
            lookup: { _ in
                Thread.sleep(forTimeInterval: 0.1)
                return true
            },
            timeout: 0.02
        )
        let result = await probe.probe()
        XCTAssertNil(result, "a lookup past the deadline must not answer")
    }
}
