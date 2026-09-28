import Foundation
import AppKit
@preconcurrency import ApplicationServices

/// Production bridge for the small AX surface required by insertion.  Every
/// method is synchronous by design; `SerialAXExecutor` owns the queue and the
/// lifetime of each native element reference.
public struct NativeAXElementClient: AXElementClient {
    private let messagingTimeoutSeconds: Float

    public init(timeout: Duration = .seconds(1)) {
        let components = timeout.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        messagingTimeoutSeconds = Float(max(0.001, seconds))
    }

    public func focusedElement() throws -> AXElementHandle? {
        let systemWide = AXUIElementCreateSystemWide()
        configureTimeout(on: systemWide)

        var rawValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &rawValue
        )
        guard result == .success else {
            if result == .noValue || result == .attributeUnsupported || result == .apiDisabled {
                return nil
            }
            throw map(result)
        }
        guard let rawValue else { return nil }
        let identifier = "ax-\(ObjectIdentifier(rawValue as AnyObject).hashValue)"
        return AXElementHandle(nativeObject: rawValue as AnyObject, identifier: identifier)
    }

    public func focusedElement(inApplication processIdentifier: pid_t) throws -> AXElementHandle? {
        let application = AXUIElementCreateApplication(processIdentifier)
        configureTimeout(on: application)
        var rawValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &rawValue
        )
        guard result == .success else {
            if result == .noValue || result == .attributeUnsupported || result == .apiDisabled
                || result == .cannotComplete {
                return nil
            }
            throw map(result)
        }
        guard let rawValue else { return nil }
        let identifier = "ax-\(ObjectIdentifier(rawValue as AnyObject).hashValue)"
        return AXElementHandle(nativeObject: rawValue as AnyObject, identifier: identifier)
    }

    /// Electron documents `AXManualAccessibility`; Chromium proper honours
    /// `AXEnhancedUserInterface` (the attribute VoiceOver sets). Both are
    /// written; a native app returns `attributeUnsupported`, which is fine.
    /// The attributes stay set for the process's lifetime, so the second
    /// dictation into the same app finds its focused element at once.
    public func enableAccessibility(inApplication processIdentifier: pid_t) throws {
        let application = AXUIElementCreateApplication(processIdentifier)
        configureTimeout(on: application)
        for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            let result = AXUIElementSetAttributeValue(application, attribute as CFString, kCFBooleanTrue)
            switch result {
            case .success, .attributeUnsupported, .noValue, .notImplemented, .cannotComplete, .illegalArgument:
                continue
            default:
                throw map(result)
            }
        }
    }

    public func processIdentifier(of element: AXElementHandle) throws -> pid_t {
        let native = try nativeElement(from: element)
        var processIdentifier: pid_t = 0
        let result = AXUIElementGetPid(native, &processIdentifier)
        guard result == .success else { throw map(result) }
        return processIdentifier
    }

    /// Whether the element advertises itself as disabled.
    ///
    /// `AXEnabled` is optional, and plain text areas generally do not publish
    /// it — TextEdit's document area is one. Treating an absent attribute as
    /// "disabled" made every such element `notEditable`, so insertion failed
    /// closed to the clipboard. Absence means "no disabled state advertised",
    /// so only an explicit `false` counts as disabled.
    public func isEnabled(_ element: AXElementHandle) throws -> Bool {
        try Self.isEnabled(enabledAttribute: try value(.enabled, of: element))
    }

    /// Pure `AXEnabled` interpretation, separated so it can be tested without a
    /// live Accessibility element.
    static func isEnabled(enabledAttribute: AXAttributeValue?) throws -> Bool {
        guard let enabledAttribute else { return true }
        guard case .boolean(let enabled) = enabledAttribute else {
            throw AXClientError.unsupportedValue
        }
        return enabled
    }

    public func isSecure(_ element: AXElementHandle) throws -> Bool {
        switch try secureMetadata(element) {
        case .secure: return true
        case .notSecure, .unavailable: return false
        }
    }

    public func secureMetadata(_ element: AXElementHandle) throws -> AXSecureMetadata {
        // `AXSubrole` is optional in the Accessibility API and is absent for
        // most plain text areas — TextEdit's document area reports
        // AXRole=AXTextArea with no subrole at all. Requiring a subrole here
        // therefore rejected the common case and fell back to the clipboard for
        // essentially every standard text area. Only the role is mandatory.
        let role: String
        let subrole: String?
        do {
            guard let roleValue = try value(.role, of: element),
                  case .string(let roleString) = roleValue,
                  !roleString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .unavailable
            }
            role = roleString

            if let subroleValue = try value(.subrole, of: element),
               case .string(let subroleString) = subroleValue,
               !subroleString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                subrole = subroleString
            } else {
                subrole = nil
            }
        } catch AXClientError.noValue,
                AXClientError.unsupportedAttribute,
                AXClientError.unsupportedValue {
            return .unavailable
        }

        return Self.classify(role: role, subrole: subrole)
    }

    /// Pure role/subrole classification, separated so the security decision can
    /// be tested without a live Accessibility element.
    static func classify(role: String?, subrole: String?) -> AXSecureMetadata {
        guard let role,
              !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .unavailable
        }

        // Secure fields are identified by role, so a missing subrole cannot
        // cause one to be misread as editable.
        if role == "AXSecureTextField"
            || subrole == "AXSecureTextField"
            || subrole == "AXSecureTextFieldSubrole" {
            return .secure
        }

        // Known editable text roles. An unrecognised role stays ambiguous and
        // must fail closed.
        let knownTextRoles: Set<String> = [
            "AXTextField",
            "AXTextArea",
            "AXTextView",
            "AXSearchField",
            "AXComboBox",
            "AXWebArea"
        ]
        guard knownTextRoles.contains(role) else { return .unavailable }

        // A present subrole must also be recognised; an unknown subrole on a
        // text role is still ambiguous. Absent is the normal case and is fine.
        guard let subrole,
              !subrole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .notSecure
        }

        let knownNonSecureSubroles: Set<String> = [
            "AXStandardTextField",
            "AXStandardTextArea",
            "AXTextArea",
            "AXTextView",
            "AXSearchField",
            "AXComboBox",
            "AXWebArea",
            "AXContentList"
        ]
        return knownNonSecureSubroles.contains(subrole) ? .notSecure : .unavailable
    }

    public func isAttributeSettable(
        _ attribute: AXAttribute,
        on element: AXElementHandle
    ) throws -> Bool {
        let native = try nativeElement(from: element)
        configureTimeout(on: native)
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            native,
            attribute.rawValue as CFString,
            &settable
        )
        guard result == .success else { throw map(result) }
        return settable.boolValue
    }

    public func value(
        _ attribute: AXAttribute,
        of element: AXElementHandle
    ) throws -> AXAttributeValue? {
        let native = try nativeElement(from: element)
        configureTimeout(on: native)
        var rawValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            native,
            attribute.rawValue as CFString,
            &rawValue
        )
        guard result == .success else {
            if result == .noValue || result == .attributeUnsupported {
                return nil
            }
            throw map(result)
        }
        guard let rawValue else { return nil }

        switch attribute {
        case .enabled:
            guard let enabled = rawValue as? Bool else { throw AXClientError.unsupportedValue }
            return .boolean(enabled)
        case .role, .subrole, .selectedText, .value:
            guard let string = rawValue as? String else { throw AXClientError.unsupportedValue }
            return .string(string)
        case .domIdentifier:
            // Presence is the signal; Chromium's value is often "".
            return .string(rawValue as? String ?? "")
        case .selectedTextRange:
            guard CFGetTypeID(rawValue) == AXValueGetTypeID() else {
                throw AXClientError.unsupportedValue
            }
            let axValue = rawValue as! AXValue
            guard AXValueGetType(axValue) == .cfRange else {
                throw AXClientError.unsupportedValue
            }
            var range = CFRange()
            guard AXValueGetValue(axValue, .cfRange, &range) else {
                throw AXClientError.unsupportedValue
            }
            return .range(AXTextRange(location: range.location, length: range.length))
        }
    }

    public func set(
        _ value: AXAttributeValue,
        for attribute: AXAttribute,
        on element: AXElementHandle
    ) throws {
        let native = try nativeElement(from: element)
        configureTimeout(on: native)
        let nativeValue: CFTypeRef
        switch value {
        case .boolean(let boolean):
            nativeValue = (boolean as NSNumber)
        case .string(let string):
            nativeValue = string as CFString
        case .range(let range):
            var cfRange = CFRange(location: range.location, length: range.length)
            guard let axValue = AXValueCreate(.cfRange, &cfRange) else {
                throw AXClientError.unsupportedValue
            }
            nativeValue = axValue
        }

        let result = AXUIElementSetAttributeValue(
            native,
            attribute.rawValue as CFString,
            nativeValue
        )
        guard result == .success else { throw map(result) }
    }

    private func nativeElement(from handle: AXElementHandle) throws -> AXUIElement {
        guard let nativeObject = handle.nativeObject else {
            throw AXClientError.unsupportedValue
        }
        return nativeObject as! AXUIElement
    }

    private func stringValue(_ attribute: AXAttribute, of element: AXElementHandle) throws -> String? {
        guard let value = try value(attribute, of: element) else { return nil }
        guard case .string(let string) = value else { throw AXClientError.unsupportedValue }
        return string
    }

    private func configureTimeout(on element: AXUIElement) {
        _ = AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)
    }

    private func map(_ error: AXError) -> AXClientError {
        switch error {
        case .cannotComplete:
            return .cannotComplete
        case .noValue:
            return .noValue
        case .apiDisabled:
            return .noValue
        case .attributeUnsupported, .actionUnsupported, .notImplemented,
             .parameterizedAttributeUnsupported:
            return .unsupportedAttribute
        default:
            return .failed(code: error.rawValue)
        }
    }
}

public struct SystemFrontmostApplicationProvider: FrontmostApplicationProviding {
    public init() {}

    public func frontmostApplication() -> FrontmostApplicationSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostApplicationSnapshot(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName
        )
    }
}

public struct SystemAccessibilityTrustProvider: AccessibilityTrustProviding {
    public init() {}

    public func isTrusted(prompt: Bool) -> Bool {
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        return AXIsProcessTrusted()
    }
}
