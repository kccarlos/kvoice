import Foundation

public struct DiagnosticEventName: RawRepresentable, Codable, Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let appLaunch = Self(rawValue: "app.launch")
    public static let appReady = Self(rawValue: "app.ready")
    public static let appTerminationRequested = Self(rawValue: "app.termination.requested")
    public static let appTerminationCompleted = Self(rawValue: "app.termination.completed")
    /// The bounded quit handshake (2026-09-16, `TerminationHandshake`):
    /// every shutdown step returned before the deadline;
    /// `durationMilliseconds` is how long they took.
    public static let appTerminateCompleted = Self(rawValue: "app.terminate.completed")
    /// The deadline fired first and the app replied "terminate" anyway.
    /// `site` names the step that was still running (`dictationController`
    /// / `modelInstallation` / `transcriptionEngine`), so a stalled quit
    /// can be located from the log alone.
    public static let appTerminateTimedOut = Self(rawValue: "app.terminate.timedOut")
    /// The relaunched instance found the old one still running at launch
    /// (`InstanceHandoff`). `durationMilliseconds` is how long it waited,
    /// `instanceCount` how many it found, `reason` how they went away:
    /// `exited` on their own, `terminated`, `forceTerminated`, or
    /// `stillRunning` (a failure; the hotkey may be contested).
    public static let appInstanceHandoffCompleted = Self(rawValue: "app.instanceHandoff.completed")
    public static let permissionMicrophoneStatus = Self(rawValue: "permission.microphone.status")
    public static let permissionMicrophoneRequested = Self(rawValue: "permission.microphone.requested")
    public static let permissionAccessibilityStatus = Self(rawValue: "permission.accessibility.status")
    public static let permissionAccessibilityPrompted = Self(rawValue: "permission.accessibility.prompted")
    public static let hotkeyRegistrationStarted = Self(rawValue: "hotkey.registration.started")
    public static let hotkeyRegistrationCompleted = Self(rawValue: "hotkey.registration.completed")
    public static let hotkeyActivation = Self(rawValue: "hotkey.activation")
    public static let hotkeyActivationIgnored = Self(rawValue: "hotkey.activation.ignored")
    public static let audioCaptureStartRequested = Self(rawValue: "audio.capture.start.requested")
    public static let audioCaptureStarted = Self(rawValue: "audio.capture.started")
    public static let audioCaptureStopped = Self(rawValue: "audio.capture.stopped")
    public static let audioCaptureCancelled = Self(rawValue: "audio.capture.cancelled")
    public static let audioInputChanged = Self(rawValue: "audio.input.changed")
    public static let modelDownloadStarted = Self(rawValue: "model.download.started")
    public static let modelDownloadProgress = Self(rawValue: "model.download.progress")
    public static let modelDownloadCancelled = Self(rawValue: "model.download.cancelled")
    public static let modelDownloadCompleted = Self(rawValue: "model.download.completed")
    public static let modelVerificationStarted = Self(rawValue: "model.verification.started")
    public static let modelVerificationCompleted = Self(rawValue: "model.verification.completed")
    public static let modelInstallCompleted = Self(rawValue: "model.install.completed")
    public static let modelLoadStarted = Self(rawValue: "model.load.started")
    public static let modelLoadCompleted = Self(rawValue: "model.load.completed")
    public static let modelUnloaded = Self(rawValue: "model.unloaded")
    /// ADR-022 item 8: the silent warm-up inference that follows every
    /// successful load. `.success` carries `durationMilliseconds`; a swallowed
    /// failure is `.warning` with `reason: "warmupFailed"`. Never text.
    public static let modelWarmUpCompleted = Self(rawValue: "model.warmup.completed")
    public static let dictationJobCreated = Self(rawValue: "dictation.job.created")
    public static let dictationStateChanged = Self(rawValue: "dictation.state.changed")
    public static let dictationJobCancelled = Self(rawValue: "dictation.job.cancelled")
    public static let dictationJobCompleted = Self(rawValue: "dictation.job.completed")
    /// One per job that reaches `.completed`, from `DictationController.apply`
    /// (2026-09-16). `durationMilliseconds` is stop-of-recording to the
    /// terminal state (nil for an Insert Again retry, whose wait is the
    /// user's); the attributes carry the per-phase scalars
    /// (`engineStartMilliseconds`, `captureStartMilliseconds`,
    /// `leadingPeakDBFS`, `recordingSeconds`, `sttMilliseconds`,
    /// `realTimeFactor`, `aiMilliseconds`, `insertionMilliseconds`,
    /// `streaming`) plus `modelID`, `mode`, and `strategy`. Never text.
    public static let dictationCompleted = Self(rawValue: "dictation.completed")
    /// One per transition into `.failed` (ADR-022 item 9), with `site` and
    /// `reason`; since 2026-09-16 also the timing scalars measured up to
    /// the failure, so a slow phase that ended in a failure is visible too.
    public static let dictationFailed = Self(rawValue: "dictation.failed")
    public static let sttStarted = Self(rawValue: "stt.started")
    public static let sttCompleted = Self(rawValue: "stt.completed")
    public static let sttCancelled = Self(rawValue: "stt.cancelled")
    /// Trailing segments dropped by `SpeechGate.strippingTrailingHallucinations`
    /// (batch) or the streaming session's per-segment gate. Carries
    /// `reason: "trailingHallucinationDropped"` and `segmentCount`; never text.
    public static let sttSegmentsDropped = Self(rawValue: "stt.segments.dropped")
    /// The dictionary prompt exceeded the runtime's cap and was cut (ADR-018).
    /// Attributes: `reason`, `tokenCount` (before the cut) — never the terms.
    public static let sttPromptTruncated = Self(rawValue: "stt.prompt.truncated")
    public static let aiRequestStarted = Self(rawValue: "ai.request.started")
    public static let aiRequestCompleted = Self(rawValue: "ai.request.completed")
    public static let aiRequestCancelled = Self(rawValue: "ai.request.cancelled")
    public static let aiFallbackUsed = Self(rawValue: "ai.fallback.used")
    public static let insertionTargetResolved = Self(rawValue: "insertion.target.resolved")
    public static let insertionStarted = Self(rawValue: "insertion.started")
    public static let insertionAttempted = Self(rawValue: "insertion.attempted")
    public static let insertionCompleted = Self(rawValue: "insertion.completed")
    public static let insertionClipboardFallback = Self(rawValue: "insertion.clipboardFallback")
    /// An AX mutation started and its outcome could not be verified, so
    /// neither a retry nor the clipboard was safe (would duplicate text).
    public static let insertionUncertain = Self(rawValue: "insertion.uncertain")
    /// Any other error the insertion service throws to the controller (a
    /// clipboard write that failed, a typed-tier poster failure). Exactly one
    /// per throw, with `site` naming the gate and `reason` the class
    /// (ADR-022 item 9).
    public static let insertionFailed = Self(rawValue: "insertion.failed")
    public static let historyWriteCompleted = Self(rawValue: "history.write.completed")
    public static let historyDeleteCompleted = Self(rawValue: "history.delete.completed")
    public static let historyClearCompleted = Self(rawValue: "history.clear.completed")
    public static let hudStateChanged = Self(rawValue: "hud.state.changed")
    public static let hudDismissed = Self(rawValue: "hud.dismissed")
    public static let networkPolicyBlocked = Self(rawValue: "network.policy.blocked")
    /// One per level change (never one per poll). `reason` carries the new
    /// level ("normal"/"warning"/"critical"); `memoryBucket` the footprint
    /// band at that moment.
    public static let memoryPressureLevelChanged = Self(rawValue: "memory.pressure.changed")
    /// ADR-022 item 4: the settings gate refused an intent. `site` is the
    /// intent's name, `reason` the typed refusal — never the value.
    public static let settingsIntentRefused = Self(rawValue: "settings.intent.refused")
    /// ADR-022 item 5: `SpeechModelLibrary` refused to begin a model
    /// activity because another was running. `reason` is the requested
    /// activity's name, `site` the running one's — case names only, never
    /// a model ID (`ModelActivity.name`).
    public static let modelActivityRefused = Self(rawValue: "model.activity.refused")
    /// ADR-025 amendment (2026-09-16): `SpeechModelLibrary` started the
    /// install of the default system-managed model's assets on its own,
    /// because the transcription language changed to one the platform
    /// holds nothing for. `modelID` is the entry, `site` the door
    /// (`languageChange` / `poll`), `reason` the language code — scalars.
    public static let modelAssetsAutoInstall = Self(rawValue: "model.assets.autoInstall")
    /// ADR-022 slice 5: the developer override file
    /// (`config.override.json`) was present and applied at launch.
    /// `fileCount` is the number of keys it overrode; never a value.
    public static let configOverrideLoaded = Self(rawValue: "config.override.loaded")
    /// ADR-022 slice 5: the override file was present but ignored whole.
    /// `reason` is `unreadable` / `notAnObject` / `malformed` /
    /// `outOfRange`; `site` names the offending key for `outOfRange`.
    public static let configOverrideRejected = Self(rawValue: "config.override.rejected")
    /// 2026-09-27 bundle identifier change: the one-time copy of the
    /// `com.kccarlos.kvoice` defaults domain into the current one.
    /// `result` is `success` (copied), `ignored` (nothing to copy), or
    /// `failure` (a value did not read back; retried next launch);
    /// `fileCount` is the number of keys copied or unverified — never a key
    /// name or a value.
    public static let settingsLegacyDomainMigration = Self(rawValue: "settings.legacyDomain.migration")
    /// ADR-026: once per launch, which distribution this bundle declares.
    /// `reason` is the `DistributionEdition` raw value; `site` is
    /// `sandboxed` or `unsandboxed` as the process actually runs (the
    /// sandbox's `APP_SANDBOX_CONTAINER_ID` environment variable), so an
    /// edition/entitlement mismatch is visible in the log. `result` is
    /// `warning` on a mismatch.
    public static let appEdition = Self(rawValue: "app.edition")
    /// ADR-022 item 7: a shortcut press started a new recording while an
    /// older job was still finishing. `finishingCount` is how many were.
    public static let dictationOverlapStarted = Self(rawValue: "dictation.overlap.started")
    /// ADR-022 item 7: a press that would have overlapped got the busy pulse
    /// instead. `reason` is `queueFull` (two jobs already finishing) or
    /// `limitedBy:<OverlapPauseReason>` (the environment turned the
    /// developer flag off); `finishingCount` as above. Never a transcript.
    public static let dictationOverlapRefused = Self(rawValue: "dictation.overlap.refused")

    public var description: String { rawValue }
}

public enum DiagnosticResult: String, Codable, Sendable, Equatable {
    case success
    case warning
    case failure
    case ignored
}

public enum TargetClass: String, Codable, Sendable, Equatable {
    case textEdit
    case other
    case none
    case secure
}

public enum EndpointClass: String, Codable, Sendable, Equatable {
    case loopback
    case remoteHTTPS
    case invalid
    /// ADR-024: Apple's on-device model; no endpoint was contacted.
    case onDevice
    /// ADR-027: Apple's server model on Private Cloud Compute, reached by
    /// the Foundation Models framework (network I/O to Apple, no URL of
    /// ours).
    case privateCloudCompute
}

public enum ThermalState: String, Codable, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

/// Public diagnostic identifiers are intentionally restricted to bounded ASCII
/// tokens. This keeps build/model/error labels useful while making paths, URLs,
/// transcript sentences, and other free-form content unrepresentable in the
/// stored attribute values.
public struct DiagnosticToken: RawRepresentable, Codable, Sendable, Equatable, Hashable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 128,
              rawValue.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57) ||
                  (scalar.value >= 65 && scalar.value <= 90) ||
                  (scalar.value >= 97 && scalar.value <= 122) ||
                  scalar == "." || scalar == "_" || scalar == ":" || scalar == "-"
              }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let token = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Diagnostic token contains unsupported content"
            )
        }
        self = token
    }
}

/// The only values that may be attached to a diagnostic record.  This is
/// deliberately a fixed, typed catalog rather than `[String: Any]` (or even a
/// dictionary with arbitrary string values): callers cannot add a transcript,
/// URL, focused-field value, or runtime error as an attribute by accident.
public struct DiagnosticAttributes: Codable, Sendable, Equatable {
    public var appBuild: DiagnosticToken?
    public var osBuild: DiagnosticToken?
    public var machineClass: DiagnosticToken?
    public var modelID: DiagnosticToken?
    public var modelRevision: DiagnosticToken?
    public var mode: DictationMode?
    public var recordingMode: RecordingInteraction?
    public var audioDurationBucket: DiagnosticToken?
    public var targetClass: TargetClass?
    public var httpStatus: Int?
    public var endpointClass: EndpointClass?
    public var bytes: Int64?
    public var thermalState: ThermalState?
    public var activeState: DictationStateKind?
    public var fromState: DictationStateKind?
    public var toState: DictationStateKind?
    public var transitionCause: DiagnosticToken?
    public var edge: DiagnosticToken?
    public var reason: DiagnosticToken?
    /// ADR-022 item 9: the code site that turned a throw into a HUD-visible
    /// failure ("insert", "verifyCaret", "runtimeMake", …). Paired with
    /// `reason`, it locates a failure from the log alone; it is a bounded
    /// token, never a path or a message.
    public var site: DiagnosticToken?
    public var actionKind: DiagnosticToken?
    public var inputFormatSummary: DiagnosticToken?
    public var sampleCount: Int?
    public var fileCount: Int?
    /// A count of transcript segments (dropped, kept); never their content.
    public var segmentCount: Int?
    /// A count of prompt tokens; never the prompt.
    public var tokenCount: Int?
    public var expectedBytes: Int64?
    public var receivedBytes: Int64?
    public var deletedRowCount: Int?
    public var partialRetained: Bool?
    public var processCold: Bool?
    public var memoryBucket: DiagnosticToken?
    public var fallbackKind: DiagnosticToken?
    public var strategy: InsertionMethod?
    public var behavior: DiagnosticToken?
    public var modelIDHash: DiagnosticToken?
    // MARK: Per-job timing (2026-09-16)
    // The `dictation.completed` / `dictation.failed` line carries the phase
    // durations the controller measured on its injected clock, so "feels
    // slower" can be answered from the log. Numbers only; the recording's
    // length is rounded to 0.1 s, which is far too coarse to fingerprint.
    /// Start command to `AudioCaptureService.start` returning (the input
    /// engine is running). Starting the engine on AirPods forces the
    /// Bluetooth A2DP→HFP switch, which is where the first words go.
    public var engineStartMilliseconds: Int?
    /// Start command to the first captured buffer with signal (a `.level`
    /// above the meter's silence floor). The gap after
    /// `engineStartMilliseconds` is the route delivering zeros.
    public var captureStartMilliseconds: Int?
    /// Peak of the first 0.5 s of the recording in dBFS, rounded to 0.1:
    /// near the floor means the opening was captured as silence.
    public var leadingPeakDBFS: Double?
    /// Length of the captured audio, rounded to 0.1 s.
    public var recordingSeconds: Double?
    /// `.transcribing` to the raw transcript, on the controller's clock.
    public var sttMilliseconds: Int?
    /// `sttMilliseconds / recordingSeconds`, rounded to two decimals.
    public var realTimeFactor: Double?
    /// `.processingAI` to `.inserting`; nil when the job never ran AI.
    public var aiMilliseconds: Int?
    /// `.inserting` to the terminal state.
    public var insertionMilliseconds: Int?
    /// True when a streaming session ran during the recording (ADR-017).
    public var streaming: Bool?
    /// ADR-022 item 7: jobs in post-processing when an overlapping start was
    /// admitted or refused (0–2).
    public var finishingCount: Int?
    /// Other running instances of this bundle found at launch
    /// (`app.instanceHandoff.completed`).
    public var instanceCount: Int?

    public init(
        appBuild: String? = nil,
        osBuild: String? = nil,
        machineClass: String? = nil,
        modelID: ModelID? = nil,
        modelRevision: String? = nil,
        mode: DictationMode? = nil,
        recordingMode: RecordingInteraction? = nil,
        audioDurationBucket: String? = nil,
        targetClass: TargetClass? = nil,
        httpStatus: Int? = nil,
        endpointClass: EndpointClass? = nil,
        bytes: Int64? = nil,
        thermalState: ThermalState? = nil,
        activeState: DictationStateKind? = nil,
        fromState: DictationStateKind? = nil,
        toState: DictationStateKind? = nil,
        transitionCause: String? = nil,
        edge: String? = nil,
        reason: String? = nil,
        site: String? = nil,
        actionKind: String? = nil,
        inputFormatSummary: String? = nil,
        sampleCount: Int? = nil,
        fileCount: Int? = nil,
        segmentCount: Int? = nil,
        tokenCount: Int? = nil,
        expectedBytes: Int64? = nil,
        receivedBytes: Int64? = nil,
        deletedRowCount: Int? = nil,
        partialRetained: Bool? = nil,
        processCold: Bool? = nil,
        memoryBucket: String? = nil,
        fallbackKind: String? = nil,
        strategy: InsertionMethod? = nil,
        behavior: String? = nil,
        modelIDHash: String? = nil,
        engineStartMilliseconds: Int? = nil,
        captureStartMilliseconds: Int? = nil,
        leadingPeakDBFS: Double? = nil,
        recordingSeconds: Double? = nil,
        sttMilliseconds: Int? = nil,
        realTimeFactor: Double? = nil,
        aiMilliseconds: Int? = nil,
        insertionMilliseconds: Int? = nil,
        streaming: Bool? = nil,
        finishingCount: Int? = nil,
        instanceCount: Int? = nil
    ) {
        self.appBuild = appBuild.flatMap(DiagnosticToken.init(rawValue:))
        self.osBuild = osBuild.flatMap(DiagnosticToken.init(rawValue:))
        self.machineClass = machineClass.flatMap(DiagnosticToken.init(rawValue:))
        self.modelID = modelID.flatMap(DiagnosticToken.init(rawValue:))
        self.modelRevision = modelRevision.flatMap(DiagnosticToken.init(rawValue:))
        self.mode = mode
        self.recordingMode = recordingMode
        self.audioDurationBucket = audioDurationBucket.flatMap(DiagnosticToken.init(rawValue:))
        self.targetClass = targetClass
        self.httpStatus = httpStatus
        self.endpointClass = endpointClass
        self.bytes = bytes
        self.thermalState = thermalState
        self.activeState = activeState
        self.fromState = fromState
        self.toState = toState
        self.transitionCause = transitionCause.flatMap(DiagnosticToken.init(rawValue:))
        self.edge = edge.flatMap(DiagnosticToken.init(rawValue:))
        self.reason = reason.flatMap(DiagnosticToken.init(rawValue:))
        self.site = site.flatMap(DiagnosticToken.init(rawValue:))
        self.actionKind = actionKind.flatMap(DiagnosticToken.init(rawValue:))
        self.inputFormatSummary = inputFormatSummary.flatMap(DiagnosticToken.init(rawValue:))
        self.sampleCount = sampleCount
        self.fileCount = fileCount
        self.segmentCount = segmentCount
        self.tokenCount = tokenCount
        self.expectedBytes = expectedBytes
        self.receivedBytes = receivedBytes
        self.deletedRowCount = deletedRowCount
        self.partialRetained = partialRetained
        self.processCold = processCold
        self.memoryBucket = memoryBucket.flatMap(DiagnosticToken.init(rawValue:))
        self.fallbackKind = fallbackKind.flatMap(DiagnosticToken.init(rawValue:))
        self.strategy = strategy
        self.behavior = behavior.flatMap(DiagnosticToken.init(rawValue:))
        self.modelIDHash = modelIDHash.flatMap(DiagnosticToken.init(rawValue:))
        self.engineStartMilliseconds = engineStartMilliseconds
        self.captureStartMilliseconds = captureStartMilliseconds
        self.leadingPeakDBFS = leadingPeakDBFS
        self.recordingSeconds = recordingSeconds
        self.sttMilliseconds = sttMilliseconds
        self.realTimeFactor = realTimeFactor
        self.aiMilliseconds = aiMilliseconds
        self.insertionMilliseconds = insertionMilliseconds
        self.streaming = streaming
        self.finishingCount = finishingCount
        self.instanceCount = instanceCount
    }

    public var isEmpty: Bool {
        self == Self()
    }

    /// A bounded representation suitable for OSLog.  No user-controlled field
    /// or URL is ever interpolated; values come only from the typed catalog.
    public var publicFields: [(String, String)] {
        var fields: [(String, String)] = []
        append(&fields, "appBuild", appBuild?.rawValue)
        append(&fields, "osBuild", osBuild?.rawValue)
        append(&fields, "machineClass", machineClass?.rawValue)
        append(&fields, "modelID", modelID?.rawValue)
        append(&fields, "modelRevision", modelRevision?.rawValue)
        append(&fields, "mode", mode?.rawValue)
        append(&fields, "recordingMode", recordingMode?.rawValue)
        append(&fields, "audioDurationBucket", audioDurationBucket?.rawValue)
        append(&fields, "targetClass", targetClass?.rawValue)
        append(&fields, "httpStatus", httpStatus.map(String.init))
        append(&fields, "endpointClass", endpointClass?.rawValue)
        append(&fields, "bytes", bytes.map(String.init))
        append(&fields, "thermalState", thermalState?.rawValue)
        append(&fields, "activeState", activeState?.rawValue)
        append(&fields, "fromState", fromState?.rawValue)
        append(&fields, "toState", toState?.rawValue)
        append(&fields, "transitionCause", transitionCause?.rawValue)
        append(&fields, "edge", edge?.rawValue)
        append(&fields, "reason", reason?.rawValue)
        append(&fields, "site", site?.rawValue)
        append(&fields, "actionKind", actionKind?.rawValue)
        append(&fields, "inputFormatSummary", inputFormatSummary?.rawValue)
        append(&fields, "sampleCount", sampleCount.map(String.init))
        append(&fields, "fileCount", fileCount.map(String.init))
        append(&fields, "segmentCount", segmentCount.map(String.init))
        append(&fields, "tokenCount", tokenCount.map(String.init))
        append(&fields, "expectedBytes", expectedBytes.map(String.init))
        append(&fields, "receivedBytes", receivedBytes.map(String.init))
        append(&fields, "deletedRowCount", deletedRowCount.map(String.init))
        append(&fields, "partialRetained", partialRetained.map(String.init))
        append(&fields, "processCold", processCold.map(String.init))
        append(&fields, "memoryBucket", memoryBucket?.rawValue)
        append(&fields, "fallbackKind", fallbackKind?.rawValue)
        append(&fields, "strategy", strategy?.rawValue)
        append(&fields, "behavior", behavior?.rawValue)
        append(&fields, "modelIDHash", modelIDHash?.rawValue)
        append(&fields, "engineStartMilliseconds", engineStartMilliseconds.map(String.init))
        append(&fields, "captureStartMilliseconds", captureStartMilliseconds.map(String.init))
        append(&fields, "leadingPeakDBFS", leadingPeakDBFS.map { String($0) })
        append(&fields, "recordingSeconds", recordingSeconds.map { String($0) })
        append(&fields, "sttMilliseconds", sttMilliseconds.map(String.init))
        append(&fields, "realTimeFactor", realTimeFactor.map { String($0) })
        append(&fields, "aiMilliseconds", aiMilliseconds.map(String.init))
        append(&fields, "insertionMilliseconds", insertionMilliseconds.map(String.init))
        append(&fields, "streaming", streaming.map(String.init))
        append(&fields, "finishingCount", finishingCount.map(String.init))
        append(&fields, "instanceCount", instanceCount.map(String.init))
        return fields
    }

    private func append(_ fields: inout [(String, String)], _ key: String, _ value: String?) {
        guard let value else { return }
        fields.append((key, value))
    }
}

public struct DiagnosticEvent: Sendable, Codable, Equatable {
    public let eventVersion: Int
    public let name: DiagnosticEventName
    public let timestamp: Date
    public let jobID: JobID?
    public let result: DiagnosticResult?
    public let durationMilliseconds: Double?
    public let errorCode: KVoiceErrorCode?
    public let attributes: DiagnosticAttributes

    public init(
        eventVersion: Int = 1,
        name: DiagnosticEventName,
        timestamp: Date = Date(),
        jobID: JobID? = nil,
        result: DiagnosticResult? = nil,
        durationMilliseconds: Double? = nil,
        errorCode: KVoiceErrorCode? = nil,
        attributes: DiagnosticAttributes = .init()
    ) {
        self.eventVersion = eventVersion
        self.name = name
        self.timestamp = timestamp
        self.jobID = jobID
        self.result = result
        self.durationMilliseconds = durationMilliseconds
        self.errorCode = errorCode
        self.attributes = attributes
    }
}

public protocol DiagnosticLogging: Sendable {
    func log(_ event: DiagnosticEvent) async
}
