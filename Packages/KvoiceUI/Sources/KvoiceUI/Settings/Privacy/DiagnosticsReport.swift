import Foundation
import KvoiceDomain

/// Everything Copy Diagnostics (FR-DIAG-005) is allowed to know.
///
/// The fields are typed rather than free text on purpose: a transcript, an
/// API key, or a full endpoint URL has no field to travel in. The only URL is
/// reduced to scheme and host before it is rendered.
public struct DiagnosticsSnapshot: Sendable, Equatable {
    public var appVersion: String
    public var buildNumber: String
    public var macOSVersion: String
    /// "accessory" or "regular" — whether the Dock icon is shown.
    public var activationPolicy: String
    public var modelState: ModelLifecycleState
    public var shortcut: ShortcutDefinition?
    public var shortcutRegistration: ShortcutRegistrationState
    public var recordingInteraction: RecordingInteraction
    public var aiMode: DictationMode
    public var aiEndpoint: URL?
    /// ADR-024: where AI requests go, and — for the on-device transport —
    /// whether the model was available at the last observation. Scalars.
    public var aiProvider: AIProviderTransport
    public var appleIntelligenceAvailability: AIProviderAvailability?
    /// ADR-027: the Private Cloud Compute availability fact (scalars only).
    public var privateCloudComputeAvailability: AIProviderAvailability?
    public var historyEnabled: Bool
    public var escapeMonitorStatus: String
    public var typedInsertionEnabled: Bool
    public var launchAtLoginStatus: LaunchAtLoginStatus

    public init(
        appVersion: String,
        buildNumber: String,
        macOSVersion: String,
        activationPolicy: String,
        modelState: ModelLifecycleState,
        shortcut: ShortcutDefinition?,
        shortcutRegistration: ShortcutRegistrationState,
        recordingInteraction: RecordingInteraction,
        aiMode: DictationMode,
        aiEndpoint: URL?,
        aiProvider: AIProviderTransport = .openAICompatible,
        appleIntelligenceAvailability: AIProviderAvailability? = nil,
        privateCloudComputeAvailability: AIProviderAvailability? = nil,
        historyEnabled: Bool,
        escapeMonitorStatus: String,
        typedInsertionEnabled: Bool,
        launchAtLoginStatus: LaunchAtLoginStatus = .unknown
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.macOSVersion = macOSVersion
        self.activationPolicy = activationPolicy
        self.modelState = modelState
        self.shortcut = shortcut
        self.shortcutRegistration = shortcutRegistration
        self.recordingInteraction = recordingInteraction
        self.aiMode = aiMode
        self.aiEndpoint = aiEndpoint
        self.aiProvider = aiProvider
        self.appleIntelligenceAvailability = appleIntelligenceAvailability
        self.privateCloudComputeAvailability = privateCloudComputeAvailability
        self.historyEnabled = historyEnabled
        self.escapeMonitorStatus = escapeMonitorStatus
        self.typedInsertionEnabled = typedInsertionEnabled
        self.launchAtLoginStatus = launchAtLoginStatus
    }
}

/// Renders the redacted plain-text block Copy Diagnostics puts on the
/// pasteboard.
public enum DiagnosticsReport {
    public static func render(_ snapshot: DiagnosticsSnapshot, generatedAt: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("KVoice diagnostics")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: generatedAt))")
        lines.append("App version: \(snapshot.appVersion) (\(snapshot.buildNumber))")
        lines.append("macOS: \(snapshot.macOSVersion)")
        lines.append("Runtime: WhisperKit 1.1.0")
        lines.append("Activation policy: \(snapshot.activationPolicy)")
        lines.append("Launch at Login: \(snapshot.launchAtLoginStatus.rawValue)")
        lines.append("Model: \(describe(snapshot.modelState))")
        lines.append("Shortcut: \(describe(snapshot.shortcut))")
        lines.append("Shortcut registration: \(describe(snapshot.shortcutRegistration))")
        lines.append("Recording mode: \(snapshot.recordingInteraction.rawValue)")
        lines.append("AI mode: \(snapshot.aiMode.rawValue)")
        lines.append("AI provider: \(snapshot.aiProvider.rawValue)")
        lines.append("AI endpoint: \(describeEndpoint(provider: snapshot.aiProvider, url: snapshot.aiEndpoint))")
        lines.append("Apple Intelligence: \(describe(snapshot.appleIntelligenceAvailability))")
        lines.append("Private Cloud Compute: \(describe(snapshot.privateCloudComputeAvailability))")
        lines.append("History enabled: \(snapshot.historyEnabled)")
        lines.append("Escape monitor: \(snapshot.escapeMonitorStatus)")
        lines.append("Typed insertion: \(snapshot.typedInsertionEnabled)")
        return lines.joined(separator: "\n")
    }

    /// Scheme, host, and port only. Userinfo, path, query, and fragment are
    /// where credentials end up, so none of them survive.
    /// ADR-027: an Apple transport has no URL of ours to redact.
    private static func describeEndpoint(provider: AIProviderTransport, url: URL?) -> String {
        switch provider {
        case .openAICompatible: return redactedEndpoint(url)
        case .appleIntelligence: return "on-device"
        case .privateCloudCompute: return "private-cloud-compute"
        }
    }

    private static func describe(_ availability: AIProviderAvailability?) -> String {
        switch availability {
        case nil: return "not observed"
        case .available?: return "available"
        case .unavailable(let reason)?: return "unavailable (\(reason.rawValue))"
        }
    }

    public static func redactedEndpoint(_ url: URL?) -> String {
        guard let url else { return "not configured" }
        guard let scheme = url.scheme, let host = url.host() else {
            return "configured (unparseable)"
        }
        var description = "\(scheme)://\(host)"
        if let port = url.port {
            description += ":\(port)"
        }
        return description
    }

    /// Case names, identifiers, and failure codes. Failure *messages* are
    /// omitted: they can echo file-system paths or a folder the user chose.
    static func describe(_ state: ModelLifecycleState) -> String {
        switch state {
        case .absent: return "absent"
        case .validatingExternal: return "validatingExternal"
        case .downloading(let completed, let total): return "downloading \(completed)/\(total) bytes"
        case .downloadPaused(let resumable): return "downloadPaused resumable=\(resumable.map(String.init) ?? "nil")"
        case .verifying(let done, let total): return "verifying \(done)/\(total) files"
        case .installing: return "installing"
        case .loading: return "loading"
        case .ready(let summary): return "ready \(describe(summary))"
        case .inference(let summary, _): return "inference \(describe(summary))"
        case .corrupt(let failure): return "corrupt code=\(failure.code)"
        case .incompatible(let failure): return "incompatible code=\(failure.code)"
        case .deleting(let summary): return "deleting \(describe(summary))"
        case .error(let failure): return "error code=\(failure.code)"
        case .unavailable(let failure): return "unavailable code=\(failure.code)"
        }
    }

    private static func describe(_ summary: InstalledModelSummary) -> String {
        "\(summary.modelID)@\(summary.revision) (\(summary.ownership.rawValue))"
    }

    private static func describe(_ shortcut: ShortcutDefinition?) -> String {
        guard let shortcut else { return "none" }
        return GeneralSettingsViewModel.displayName(for: shortcut)
    }

    private static func describe(_ state: ShortcutRegistrationState) -> String {
        switch state {
        case .unregistered: return "unregistered"
        case .registered: return "registered"
        case .failed(let code): return "failed code=\(code.rawValue)"
        }
    }
}
