import Foundation

/// Stable, privacy-safe values persisted in diagnostics and history.
public enum KVoiceErrorCode: String, Codable, Sendable, Equatable, CaseIterable {
    case appBusy = "APP-BUSY"
    case appCancelled = "APP-CANCELLED"
    case appInternal = "APP-INTERNAL"

    case permissionMicrophoneNotDetermined = "PERM-MIC-NOT-DETERMINED"
    case permissionMicrophoneDenied = "PERM-MIC-DENIED"
    case permissionMicrophoneRestricted = "PERM-MIC-RESTRICTED"
    case permissionAccessibilityDenied = "PERM-AX-DENIED"
    case permissionAccessibilityLost = "PERM-AX-LOST"

    case hotkeyRegistrationFailed = "HOTKEY-REGISTRATION-FAILED"
    case hotkeyKeyUpLost = "HOTKEY-KEYUP-LOST"

    case audioEngineStartFailed = "AUD-ENGINE-START-FAILED"
    case audioInputUnavailable = "AUD-INPUT-UNAVAILABLE"
    case audioInputChanged = "AUD-INPUT-CHANGED"
    case audioInterrupted = "AUD-INTERRUPTED"
    case audioNoSamples = "AUD-NO-SAMPLES"
    case audioTooShort = "AUD-TOO-SHORT"
    case audioTooLong = "AUD-TOO-LONG"
    case audioConversionFailed = "AUD-CONVERSION-FAILED"

    case modelNotInstalled = "MODEL-NOT-INSTALLED"
    case modelInsufficientDisk = "MODEL-INSUFFICIENT-DISK"
    case modelDownloadFailed = "MODEL-DOWNLOAD-FAILED"
    case modelDownloadCancelled = "MODEL-DOWNLOAD-CANCELLED"
    case modelIntegrityFailed = "MODEL-INTEGRITY-FAILED"
    case modelIncompatible = "MODEL-INCOMPATIBLE"
    case modelPathUnreadable = "MODEL-PATH-UNREADABLE"
    case modelLoadFailed = "MODEL-LOAD-FAILED"
    case modelOfflineAssetMissing = "MODEL-OFFLINE-ASSET-MISSING"
    case modelRuntimeNetworkAttempt = "MODEL-RUNTIME-NETWORK-ATTEMPT"

    case sttInvalidAudio = "STT-INVALID-AUDIO"
    case sttEmpty = "STT-EMPTY"
    case sttCancelled = "STT-CANCELLED"
    case sttFailed = "STT-FAILED"
    case sttTimeout = "STT-TIMEOUT"

    case aiConfigurationMissing = "AI-CONFIG-MISSING"
    case aiURLInvalid = "AI-URL-INVALID"
    case aiInsecureRemoteURL = "AI-INSECURE-REMOTE-URL"
    case aiUnreachable = "AI-UNREACHABLE"
    case aiTimeout = "AI-TIMEOUT"
    case aiAuthentication = "AI-AUTHENTICATION"
    case aiRateLimited = "AI-RATE-LIMITED"
    case aiHTTPError = "AI-HTTP-ERROR"
    case aiMalformedResponse = "AI-MALFORMED-RESPONSE"
    case aiEmptyResponse = "AI-EMPTY-RESPONSE"
    case aiOversizedResponse = "AI-OVERSIZED-RESPONSE"
    case aiCancelled = "AI-CANCELLED"
    /// ADR-024: the on-device model cannot take a request right now (the
    /// availability reason is an environment fact, not carried here).
    case aiProviderUnavailable = "AI-PROVIDER-UNAVAILABLE"
    /// ADR-024: the prompt would not fit the on-device model's context
    /// window; the raw transcript is inserted (the ordinary AI fallback).
    case aiInputTooLong = "AI-INPUT-TOO-LONG"
    /// ADR-027: the user's daily Private Cloud Compute allotment is used up
    /// (not a rate limit: waiting minutes does not help).
    case aiQuotaExhausted = "AI-QUOTA-EXHAUSTED"

    case accessibilityNoFrontmostApp = "AX-NO-FRONTMOST-APP"
    case accessibilityTargetAppChanged = "AX-TARGET-APP-CHANGED"
    case accessibilityNoFocusedElement = "AX-NO-FOCUSED-ELEMENT"
    case accessibilityNotEditable = "AX-NOT-EDITABLE"
    case accessibilitySecureTarget = "AX-SECURE-TARGET"
    case accessibilityUnsupportedValueType = "AX-UNSUPPORTED-VALUE-TYPE"
    /// ADR-026: too long to type; copied instead.
    case accessibilityTextTooLarge = "AX-TEXT-TOO-LARGE"
    case accessibilitySetFailed = "AX-SET-FAILED"
    case accessibilityVerifyFailed = "AX-VERIFY-FAILED"
    case accessibilityTimeout = "AX-TIMEOUT"
    case clipboardWriteFailed = "CLIPBOARD-WRITE-FAILED"

    case historyOpenFailed = "HISTORY-OPEN-FAILED"
    case historyMigrationFailed = "HISTORY-MIGRATION-FAILED"
    case historyWriteFailed = "HISTORY-WRITE-FAILED"
    case settingsCorrupt = "SETTINGS-CORRUPT"
    case secretsFileInsecure = "SECRETS-FILE-INSECURE"

    public var subsystemPrefix: String {
        String(rawValue.prefix { $0 != "-" })
    }

    public var defaultRetryable: Bool {
        switch self {
        case .permissionMicrophoneRestricted,
             .modelRuntimeNetworkAttempt,
             .accessibilitySecureTarget:
            return false
        default:
            return true
        }
    }
}

/// Naming used by the immutable `DictationJob` aggregate for AI-stage fallback.
public typealias AIErrorCode = KVoiceErrorCode

/// A typed error crossing a module boundary. `metadata` uses the same bounded
/// diagnostic catalog so adapters cannot smuggle runtime strings or content into
/// logs while still carrying status/byte/timing evidence.
public struct KVoiceError: Error, LocalizedError, Codable, Sendable, Equatable {
    public let code: KVoiceErrorCode
    public let retryable: Bool
    public let metadata: DiagnosticAttributes

    public init(
        code: KVoiceErrorCode,
        retryable: Bool? = nil,
        metadata: DiagnosticAttributes = .init()
    ) {
        self.code = code
        self.retryable = retryable ?? code.defaultRetryable
        self.metadata = metadata
    }

    public var errorDescription: String? {
        code.rawValue
    }
}

// MARK: - User-facing copy

public extension KVoiceErrorCode {
    /// Plain-language copy for HUD and menu surfaces (D.10 error-writing rules:
    /// what happened, what kvoice did with the text, and the next action). The
    /// raw code stays in diagnostics and history; it is never shown as a title.
    var userFacingMessage: String {
        switch self {
        case .appBusy:
            return "KVoice is still finishing the previous dictation."
        case .appCancelled:
            return "Dictation cancelled."
        case .appInternal:
            return "Something went wrong inside KVoice. Nothing was inserted."

        case .permissionMicrophoneNotDetermined:
            return "Microphone access has not been granted yet. Allow it in Setup or Settings."
        case .permissionMicrophoneDenied:
            return "Microphone access is denied. Enable KVoice in System Settings › Privacy & Security › Microphone."
        case .permissionMicrophoneRestricted:
            return "Microphone access is restricted on this Mac."
        case .permissionAccessibilityDenied, .permissionAccessibilityLost:
            return "Accessibility permission is missing, so the result was copied to the clipboard."

        case .hotkeyRegistrationFailed:
            return "The shortcut could not be registered. Choose another one in Settings."
        case .hotkeyKeyUpLost:
            return "The shortcut release was not received. Recording stopped."

        case .audioEngineStartFailed:
            return "The microphone could not be started. Check the input device and try again."
        case .audioInputUnavailable:
            return "No microphone is available. Connect or select an input device and try again."
        case .audioInputChanged:
            return "The input device changed during recording. Nothing was inserted; try again."
        case .audioInterrupted:
            return "Recording was interrupted. Nothing was inserted; try again."
        case .audioNoSamples, .audioTooShort:
            return "No usable speech was recorded. Hold the shortcut a little longer and try again."
        case .audioTooLong:
            return "Recording reached the maximum length."
        case .audioConversionFailed:
            return "The audio could not be prepared for transcription. Try again."

        case .modelNotInstalled:
            return "No transcription model is installed. Download or choose one in Settings › Model."
        case .modelInsufficientDisk:
            return "Not enough free disk space to install the model."
        case .modelDownloadFailed:
            return "The model download failed. Retry from Settings › Model."
        case .modelDownloadCancelled:
            return "The model download was cancelled."
        case .modelIntegrityFailed, .modelIncompatible, .modelPathUnreadable,
             .modelLoadFailed, .modelOfflineAssetMissing, .modelRuntimeNetworkAttempt:
            return "The transcription model is unavailable. Open Settings › Model to repair it."

        case .sttInvalidAudio:
            return "No usable speech was recorded. Try again."
        case .sttEmpty:
            return "No transcript was produced. Nothing was inserted; try again."
        case .sttCancelled:
            return "Transcription cancelled."
        case .sttFailed, .sttTimeout:
            return "Transcription failed. Nothing was inserted; try again."

        case .aiConfigurationMissing:
            return "AI is not configured. Inserted the local transcript instead."
        case .aiURLInvalid, .aiInsecureRemoteURL:
            return "The AI endpoint URL is invalid. Inserted the local transcript instead."
        case .aiUnreachable:
            return "The AI endpoint could not be reached. Inserted the local transcript instead."
        case .aiTimeout:
            return "AI did not respond in time. Inserted the local transcript instead."
        case .aiAuthentication:
            return "AI authentication failed. Inserted the local transcript instead."
        case .aiRateLimited:
            return "The AI endpoint is rate-limited. Inserted the local transcript instead."
        case .aiHTTPError:
            return "The AI endpoint returned an error. Inserted the local transcript instead."
        case .aiMalformedResponse, .aiEmptyResponse, .aiOversizedResponse:
            return "The AI response was unusable. Inserted the local transcript instead."
        case .aiCancelled:
            return "AI skipped. Inserted the local transcript instead."
        case .aiProviderUnavailable:
            return "Apple Intelligence isn't available right now. Inserted the local transcript instead."
        case .aiInputTooLong:
            return "The transcript is too long for the on-device model. Inserted the local transcript instead."
        case .aiQuotaExhausted:
            return "Today's Private Cloud Compute limit is reached. Inserted the local transcript instead."

        case .accessibilityNoFrontmostApp:
            return "No application was in front. Copied the result to the clipboard."
        case .accessibilityTargetAppChanged:
            return "The target application changed. Copied the result to the clipboard."
        case .accessibilityNoFocusedElement:
            return "No editable field was focused. Copied the result to the clipboard."
        case .accessibilityNotEditable, .accessibilityUnsupportedValueType:
            return "The focused field cannot be edited directly. Copied the result to the clipboard."
        case .accessibilitySecureTarget:
            return "Cannot insert into a secure field. Copied the result to the clipboard."
        case .accessibilityTextTooLarge:
            return "The result is too long to type. Copied it to the clipboard."
        case .accessibilitySetFailed, .accessibilityVerifyFailed, .accessibilityTimeout:
            return "The application did not accept the text. Copied the result to the clipboard."
        case .clipboardWriteFailed:
            return "The result could not be copied to the clipboard. It is kept in History and shown below."

        case .historyOpenFailed, .historyMigrationFailed, .historyWriteFailed:
            return "History is unavailable. Dictation continues without it."
        case .settingsCorrupt:
            return "Settings could not be read and defaults are in use."
        case .secretsFileInsecure:
            return "The API key file has unsafe permissions. AI is disabled until it is repaired."
        }
    }
}

public extension ClipboardFallbackReason {
    /// The `KVoiceErrorCode` that carries this reason's user-facing copy.
    var errorCode: KVoiceErrorCode {
        switch self {
        case .noFrontmostApplication: return .accessibilityNoFrontmostApp
        case .targetApplicationChanged: return .accessibilityTargetAppChanged
        case .noFocusedElement: return .accessibilityNoFocusedElement
        case .notEditable: return .accessibilityNotEditable
        case .secureTarget: return .accessibilitySecureTarget
        case .unsupportedValueType: return .accessibilityUnsupportedValueType
        case .setFailed: return .accessibilitySetFailed
        case .verifyFailed: return .accessibilityVerifyFailed
        case .timeout: return .accessibilityTimeout
        case .permissionNotGranted: return .permissionAccessibilityDenied
        case .textTooLarge: return .accessibilityTextTooLarge
        }
    }

    var userFacingMessage: String { errorCode.userFacingMessage }
}
