import ApplicationServices
import XCTest
import os
@testable import OpenSelection

@MainActor
final class CopyMenuProbeTests: XCTestCase {
    func testDisabledCachedElementIsRediscovered() async {
        let probes = OSAllocatedUnfairLock(initialState: 0)
        let probe = CopyMenuProbe(
            readEnabled: { _, _ in .value(false) },
            discover: { pid, _, _ in
                let count = probes.withLock { $0 += 1; return $0 }
                return .found(AXUIElementCreateApplication(pid), isEnabled: count > 1)
            }
        )
        let initial = await probe.state(for: 42, timeout: 0.05)
        XCTAssertEqual(initial, .disabled)
        let refreshed = await probe.state(for: 42, timeout: 0.05)
        XCTAssertEqual(refreshed, .enabled)
        XCTAssertEqual(probes.withLock { $0 }, 2)
    }

    func testEnabledCachedElementKeepsFastPath() async {
        let probes = OSAllocatedUnfairLock(initialState: 0)
        let probe = CopyMenuProbe(
            readEnabled: { _, _ in .value(true) },
            discover: { pid, _, _ in
                probes.withLock { $0 += 1 }
                return .found(AXUIElementCreateApplication(pid), isEnabled: true)
            }
        )
        _ = await probe.state(for: 42, timeout: 0.05)
        let cached = await probe.state(for: 42, timeout: 0.05)
        XCTAssertEqual(cached, .enabled)
        XCTAssertEqual(probes.withLock { $0 }, 1)
    }

    func testRediscoveryStillHonorsDisabledMenu() async {
        let probe = CopyMenuProbe(
            readEnabled: { _, _ in .value(false) },
            discover: { pid, _, _ in .found(AXUIElementCreateApplication(pid), isEnabled: false) }
        )
        _ = await probe.state(for: 42, timeout: 0.05)
        let refreshed = await probe.state(for: 42, timeout: 0.05)
        XCTAssertEqual(refreshed, .disabled)
    }

    func testRediscoveryTimeoutDoesNotAuthorizeCopy() async {
        let probes = OSAllocatedUnfairLock(initialState: 0)
        let probe = CopyMenuProbe(
            readEnabled: { _, _ in .value(false) },
            discover: { pid, _, _ in
                let count = probes.withLock { $0 += 1; return $0 }
                return count == 1 ? .found(AXUIElementCreateApplication(pid), isEnabled: false) : .timedOut
            }
        )
        _ = await probe.state(for: 42, timeout: 0.05)
        let refreshed = await probe.state(for: 42, timeout: 0.05)
        XCTAssertEqual(refreshed, .unknown(.timeout))
    }
}
