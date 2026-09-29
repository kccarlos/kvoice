import Foundation

/// The inventory of English sentences and names KvoiceDomain hands to a
/// user-facing surface (HUD, status menu, Settings pickers).
///
/// KvoiceDomain stays free of bundles and catalogs: it composes plain English
/// (`KVoiceErrorCode.userFacingMessage`, `BlockReason.message`,
/// `CompletionSummary.warningMessage`, the enum `displayName`s), and the English
/// text is the *key*. `KvoiceUI`'s `DomainCopy` resolves each key against its
/// `DomainCopy.xcstrings` table at display time — the localization seam.
///
/// This list exists so a test in KvoiceUI can prove every key has a
/// translation (`DomainCopyTests`). When you add a user-facing string to the
/// domain, add it here and to `DomainCopy.xcstrings`; the test fails until
/// both are done. Strings not listed here are shown in English.
public enum DomainUserFacingCopy {
    /// `CompletionSummary.attaching` appends this line when the hard cap
    /// stopped the recording; `%@` is one of `limitUnitFormats` filled in.
    public static let recordingCapFormat = "Recording stopped at the %@ limit."
    /// `CompletionSummary.limitDescription` shapes, as format strings.
    public static let limitUnitFormats = ["%lld-hour", "%lld-minute", "%lld-second"]
    /// The reducer's warning for an insertion fallback that carries no reason.
    public static let clipboardFallbackGeneric = "Result copied to the clipboard."

    /// Every sentence the dictation pipeline can surface: error copy, block
    /// reasons, the reducer's fixed lines, and the cap formats.
    public static var messages: [String] {
        var all: [String] = []
        all += KVoiceErrorCode.allCases.map(\.userFacingMessage)
        all += BlockReason.builtIn.map(\.message)
        all.append(clipboardFallbackGeneric)
        all.append(recordingCapFormat)
        all += limitUnitFormats
        // ADR-022 item 3: the availability projection's footnotes.
        all += SettingAvailabilityReason.allCases.map(\.message)
        // ADR-024: the on-device provider's availability footnotes.
        all += AIProviderUnavailableReason.allCases.map(\.message)
        // ADR-027: the Private Cloud Compute quota lines.
        all.append(AIProviderQuota.approachingLimitMessage)
        all.append(AIProviderQuota.limitReachedMessage)
        // ADR-025: a system-managed model's card copy (Apple Speech).
        all += SystemManagedUnavailableReason.allCases.map(\.message)
        all += SystemManagedAssetError.messageInventory
        // ADR-025 amendment: the Blocked HUD's pointer after the card's reason.
        all.append(BlockReason.systemManagedUnavailableHint)
        return unique(all)
    }

    /// Every enum `displayName` the UI shows as a picker choice, badge, or
    /// menu title.
    public static var displayNames: [String] {
        var all: [String] = []
        all += RecordingInteraction.allCases.map(\.displayName)
        all += ShortcutDefinition.ModifierOnlyKey.allCases.map(\.displayName)
        all += RecordingDurationLimit.allCases.map(\.displayName)
        all += HistoryTimeRange.allCases.map(\.displayName)
        all += HistoryDurationBucket.allCases.map(\.displayName)
        all += SpeechComputeUnits.allCases.map(\.displayName)
        all += SpeechComputeUnits.allCases.map(\.expectedDeviceDisplayName)
        all += ComputeDeviceKind.allCases.map(\.displayName)
        all += SpeechModelRuntime.allCases.map(\.displayName)
        all += SpeechModelHosting.allCases.map(\.displayName)
        all += SpeechTranscriptionMode.allCases.map(\.displayName)
        all += AIProviderKind.allCases.map(\.displayName)
        return unique(all)
    }

    public static var all: [String] { unique(messages + displayNames) }

    private static func unique(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }
    }
}

public extension BlockReason {
    /// The reasons the domain itself can raise, for the copy inventory.
    static let builtIn: [BlockReason] = [
        .microphonePermission,
        .accessibilityPermission,
        .modelUnavailable,
        .microphoneNotRequested,
        .modelLoading,
        .modelOptimizing,
        // ADR-025 amendment: the system-managed default's own block copy.
        .systemManagedAssetsMissing
    ]
}
