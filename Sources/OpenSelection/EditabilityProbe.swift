// EditabilityProbe.swift
// OpenSelection
//
// Answers whether the focused element accepts text insertion, without reading a selection.
// Palette-style entry points open with no selected text, so they cannot reuse a selection read
// to learn where a pasted result would land.
import ApplicationServices
import Foundation

public struct EditabilityProbe: Sendable {
    public typealias Lookup = @Sendable (_ deadline: Date?) -> Bool?

    private let lookup: Lookup
    public let timeout: TimeInterval

    public init(configuration: SelectionConfiguration = .default) {
        self.timeout = configuration.axReadTimeout
        self.lookup = { deadline in
            let trace = SelectionTrace.create(trigger: .programmatic)
            if let deadline { trace.refreshDeadline(deadline) }
            let target = AXElementInspector.inspect(trace: trace)
            guard target.focusedElement != nil else { return nil }
            return SelectionRetrievalCoordinator.isEditableContext(target)
        }
    }

    init(lookup: @escaping Lookup, timeout: TimeInterval = 0.5) {
        self.lookup = lookup
        self.timeout = timeout
    }

    /// True when the focused element positively accepts text edits, false when it positively
    /// does not, nil when Accessibility could not answer before the deadline.
    public func probe() async -> Bool? {
        let timeoutSeconds = timeout
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let lookup = self.lookup
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let resume = OnceResume<Bool?>()
            let watchdog = TaskBox()
            watchdog.set(Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if resume.resume(continuation, with: nil) {
                    DiagnosticsHub.shared.log(.warning, .ax, "editability probe deadline exceeded", fields: [
                        "timeoutMicros": .micros(UInt32(timeoutSeconds * 1_000_000))
                    ])
                }
            })

            Self.probeQueue.async {
                let editable = lookup(deadline)
                Task {
                    if resume.resume(continuation, with: editable) { watchdog.cancel() }
                }
            }
        }
    }

    private static let probeQueue = DispatchQueue(
        label: "com.openselection.editability-probe",
        qos: .userInitiated
    )
}
