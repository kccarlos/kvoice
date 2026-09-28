import Foundation

/// The range representation used at the Accessibility boundary.
///
/// Accessibility text ranges are UTF-16 code-unit offsets.  Keeping the
/// representation explicit prevents adapters from accidentally using Swift
/// `String.Index` values for AX ranges.
public struct AXTextRange: Sendable, Equatable, Hashable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var isCollapsed: Bool {
        length == 0
    }
}

/// Conservative bounds for data crossing the Accessibility text boundary.
///
/// AX values and ranges are returned by another process.  The insertion
/// adapter validates them before using them to create an NSString or a
/// replacement value, so a malformed or unexpectedly large AX response
/// cannot cause an unbounded allocation.
public enum AXInsertionLimits {
    public static let maxUTF8Bytes = 64 * 1024
    public static let maxUTF16Units = 64 * 1024

    public static func isBounded(_ text: String) -> Bool {
        text.utf8.count <= maxUTF8Bytes
            && text.utf16.count <= maxUTF16Units
    }

    public static func isBounded(_ range: AXTextRange) -> Bool {
        guard range.location >= 0,
              range.length >= 0,
              range.location <= maxUTF16Units,
              range.length <= maxUTF16Units
        else {
            return false
        }
        return range.location <= maxUTF16Units - range.length
    }
}

/// The security state of an AX element's role metadata.
///
/// A missing or malformed role/subrole is not evidence that a field is safe
/// to edit.  Native adapters therefore report `.unavailable` and callers
/// fail closed without attempting a mutation.
public enum AXSecureMetadata: Sendable, Equatable {
    case secure
    case notSecure
    case unavailable
}

/// Per-insertion fence used to prevent a timed-out operation from mutating
/// after its caller has switched to clipboard fallback.  `beginMutation()`
/// must be called immediately before each AX set operation.
public final class AXOperationGate: @unchecked Sendable {
    public let generation: UUID

    private let lock = NSLock()
    private var invalidated = false
    private var cancellationRequested = false
    private var mutationStarted = false
    private var fallbackStarted = false

    public init(generation: UUID = UUID()) {
        self.generation = generation
    }

    public var isInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }

    public var isMutationStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mutationStarted
    }

    public func invalidate() {
        invalidateForCancellation()
    }

    func invalidateForCancellation() {
        lock.lock()
        invalidated = true
        cancellationRequested = true
        lock.unlock()
    }

    func invalidateForTimeout() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    public func beginMutation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else { return false }
        mutationStarted = true
        return true
    }

    /// Runs the one permitted clipboard fallback while holding the gate lock.
    /// A timeout may claim this only when no AX mutation started; cancellation
    /// always rejects the claim. Holding the lock through the writer call
    /// establishes the linearization point for a fallback versus a racing
    /// cancellation handler.
    func performFallback<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !cancellationRequested,
              !mutationStarted,
              !fallbackStarted
        else {
            throw AXOperationGateError.invalidated
        }
        fallbackStarted = true
        return try operation()
    }
}

/// A short-lived reference to an Accessibility element.
///
/// The insertion service never stores this value.  It is created and used
/// within one serial AX operation, then released when that operation returns.
/// The unchecked conformance is limited to this opaque bridge because native
/// AX references are Core Foundation objects and the serial executor is the
/// ownership boundary.
public struct AXElementHandle: @unchecked Sendable, Hashable {
    internal let nativeObject: AnyObject?
    public let identifier: String

    /// Creates a synthetic handle for deterministic adapter tests.
    public init(identifier: String) {
        self.nativeObject = nil
        self.identifier = identifier
    }

    internal init(nativeObject: AnyObject, identifier: String) {
        self.nativeObject = nativeObject
        self.identifier = identifier
    }

    public static func == (lhs: AXElementHandle, rhs: AXElementHandle) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

public enum AXAttribute: String, Sendable, Equatable, CaseIterable {
    case enabled = "AXEnabled"
    case role = "AXRole"
    case subrole = "AXSubrole"
    case selectedText = "AXSelectedText"
    case selectedTextRange = "AXSelectedTextRange"
    case value = "AXValue"
    /// Chromium/Electron only: present (possibly empty) on every node of web
    /// content, absent from native views. Used to recognise a web editor.
    case domIdentifier = "AXDOMIdentifier"
}

public enum AXAttributeValue: Sendable, Equatable {
    case boolean(Bool)
    case string(String)
    case range(AXTextRange)
}

public enum AXClientError: Error, Sendable, Equatable {
    case cannotComplete
    case noValue
    case unsupportedAttribute
    case unsupportedValue
    case timeout
    case failed(code: Int32)
}

/// A process snapshot used by target-affinity checks.  No window title or
/// document value is carried across this boundary.
public struct FrontmostApplicationSnapshot: Sendable, Equatable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    public let localizedName: String?

    public init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        localizedName: String?
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
    }
}

public protocol FrontmostApplicationProviding: Sendable {
    func frontmostApplication() -> FrontmostApplicationSnapshot?
}

public protocol AccessibilityTrustProviding: Sendable {
    func isTrusted(prompt: Bool) -> Bool
}

/// Synchronous operations are intentional: callers execute them on the
/// dedicated serial AX executor, so a fake can model each native message
/// deterministically without introducing another executor.
public protocol AXElementClient: Sendable {
    func focusedElement() throws -> AXElementHandle?
    /// The focused element as reported by one application's own AX root
    /// rather than the system-wide element. Chromium answers this one before
    /// it answers the system-wide query; defaults to `focusedElement()`.
    func focusedElement(inApplication processIdentifier: pid_t) throws -> AXElementHandle?
    /// Asks a process to build its accessibility tree. Electron/Chromium
    /// apps expose no focused element until an assistive client sets
    /// `AXManualAccessibility` / `AXEnhancedUserInterface` on their
    /// application element; native apps ignore the attributes. Default no-op.
    func enableAccessibility(inApplication processIdentifier: pid_t) throws
    func processIdentifier(of element: AXElementHandle) throws -> pid_t
    func isEnabled(_ element: AXElementHandle) throws -> Bool
    func isSecure(_ element: AXElementHandle) throws -> Bool
    func secureMetadata(_ element: AXElementHandle) throws -> AXSecureMetadata
    func isAttributeSettable(_ attribute: AXAttribute, on element: AXElementHandle) throws -> Bool
    func value(_ attribute: AXAttribute, of element: AXElementHandle) throws -> AXAttributeValue?
    func set(_ value: AXAttributeValue, for attribute: AXAttribute, on element: AXElementHandle) throws
}

public extension AXElementClient {
    func focusedElement(inApplication processIdentifier: pid_t) throws -> AXElementHandle? {
        try focusedElement()
    }

    func enableAccessibility(inApplication processIdentifier: pid_t) throws {}

    /// Compatibility default for adapters that only expose the original
    /// boolean security contract.  Native adapters override this to preserve
    /// the distinction between a known-safe role and missing metadata.
    func secureMetadata(_ element: AXElementHandle) throws -> AXSecureMetadata {
        try isSecure(element) ? .secure : .notSecure
    }
}

public protocol ClipboardWriting: Sendable {
    func write(_ text: String) throws
}

public enum AXExecutionError: Error, Sendable, Equatable {
    case timeout
}

public enum AXOperationGateError: Error, Sendable, Equatable {
    case invalidated
}
