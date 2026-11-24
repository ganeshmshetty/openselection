// FocusedAppIdentity.swift
// OpenSelection
//
// Decides whether the AX focused application still belongs to the app a retrieval was requested for.
// Chromium/CEF browsers expose their accessibility tree from a helper process inside the app bundle
// (Yab reports `dev.serafim.fast.core` from `Yab.app/Contents/Frameworks/YabCore.app`), so raw PID
// equality rejects a valid selection. A focused PID that AX reports but AppKit cannot resolve is not
// treated as a helper: it still fails closed.
import AppKit
import Foundation

internal struct FocusedAppIdentity: Sendable {
    internal struct Descriptor: Sendable, Equatable {
        internal let processIdentifier: pid_t
        internal let bundleIdentifier: String?
        internal let bundleURL: URL?

        internal init(processIdentifier: pid_t,
                      bundleIdentifier: String? = nil,
                      bundleURL: URL? = nil) {
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
            self.bundleURL = bundleURL
        }

        internal init?(_ app: NSRunningApplication?) {
            guard let app else { return nil }
            self.init(processIdentifier: app.processIdentifier,
                      bundleIdentifier: app.bundleIdentifier,
                      bundleURL: app.bundleURL)
        }

        internal init?(pid: pid_t) {
            self.init(NSRunningApplication(processIdentifier: pid))
        }
    }

    /// `focusedPID` is nil only when `AXUIElementGetPid` itself failed. A PID that AX reports but
    /// `NSRunningApplication` cannot resolve stays a mismatch and is rejected.
    internal static func accepts(requested: Descriptor,
                                 focusedPID: pid_t?,
                                 focused: Descriptor?) -> Bool {
        guard let focusedPID else { return true }
        if focusedPID == requested.processIdentifier { return true }
        guard let focused else { return false }
        if let requestedID = requested.bundleIdentifier,
           focused.bundleIdentifier == requestedID {
            return true
        }
        // Chromium/CEF browsers expose AX from a helper nested in the app bundle.
        if let requestedURL = requested.bundleURL,
           let focusedURL = focused.bundleURL,
           isContained(focusedURL, in: requestedURL) {
            return true
        }
        return false
    }

    private static func isContained(_ child: URL, in parent: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }
}
