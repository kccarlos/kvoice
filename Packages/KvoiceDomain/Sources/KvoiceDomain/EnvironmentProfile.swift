import Foundation

/// ADR-022 item 1, the fourth configuration source: the **environment
/// profile** — facts the shell *observes* about this machine and this
/// process right now. Never persisted, never exported, never overridden:
/// the type is deliberately not `Codable` (a test checks), so no store can
/// take it and no JSON can pretend to be it. The shell rebuilds it from the
/// sources it already reads (the one-second slow poll, the Runtime card's
/// engine statistics, the memory-pressure observer, `ProcessInfo`) and
/// hands it to `SettingsAvailability` (the rules) and `SettingsResolver`
/// (the clamps). Replaces the slice-3 stub `AvailabilityEnvironment`.
///
/// Every field is optional or defaulted because a fact may be unknown at a
/// given moment (no display yet, nothing resident, the GPU key absent); a
/// rule that reads an unknown fact does nothing rather than guess.
public struct EnvironmentProfile: Sendable, Equatable {
    // MARK: Capabilities

    /// ADR-026: which distribution this process is, read once at launch
    /// from the bundle. The App Store edition's availability rows (the
    /// Selection Action, the middle mouse trigger, the typed-insertion
    /// switch) key off it. Defaults to the Developer ID edition, whose rules
    /// are unchanged.
    public var edition: DistributionEdition

    /// The recording-start screen has a camera housing. `nil` while the
    /// shell has not looked.
    public var hasNotch: Bool?
    /// The IOKit accelerator exposes "Device Utilization %"; `false` hides
    /// the GPU line. `nil` before the first sample.
    public var gpuCounterReadable: Bool?
    /// `AXIsProcessTrusted()` at the last slow poll.
    public var accessibilityTrusted: Bool?
    /// The last resolved insertion target lived in Chromium web content
    /// (`AXDOMIdentifier` present). Seam only: nothing fills it until slice
    /// 6/7 publish per-job target facts; `nil` until then.
    public var chromiumWebContentTarget: Bool?
    /// ADR-024: whether Apple's on-device model can take a request right now,
    /// as the `KvoiceAppleIntelligence` adapter last reported it (the slow
    /// poll and app activation refresh it). `nil` before the first read.
    public var appleIntelligenceAvailability: AIProviderAvailability?
    /// ADR-027: whether Private Cloud Compute can take a request, as the
    /// adapter last reported it — the edition / signature refusal (known
    /// without touching the framework) or the framework's own availability
    /// (read only while AI is on and a Private Cloud Compute configuration
    /// is saved). `nil` before the first read.
    public var privateCloudComputeAvailability: AIProviderAvailability?
    /// ADR-027: the user's standing against the daily request limit, read
    /// under the same condition; `nil` when unknown.
    public var privateCloudComputeQuota: AIProviderQuota?

    // MARK: Limits

    /// The resident engine's prompt cap (`.tokens`, `.unsupported`), or
    /// `nil` while nothing is resident.
    public var enginePromptTokenLimit: PromptTokenLimit?
    /// The default catalog entry's `promptTokenLimit` (absent = no prompt).
    public var catalogPromptTokenLimit: Int?
    /// The kernel's system memory-pressure level (never this process's
    /// footprint — see `MemoryPressureObserving`).
    public var memoryPressureLevel: MemoryPressureLevel

    // MARK: Measurements

    /// The engine's last batch real-time factor (below 1 is faster than
    /// real time).
    public var lastRealTimeFactor: Double?
    /// Wall time of the last successful runtime load.
    public var lastLoadDuration: Duration?
    /// `phys_footprint` of this process at the last sample.
    public var residentFootprintBytes: UInt64?
    /// Core ML's plan for the resident package under the current units.
    public var placement: ModelPlacementReport?

    // MARK: Identity

    /// The catalog ID of the resident model, `nil` while nothing is loaded.
    public var residentModelID: ModelID?
    /// The resident model's runtime (WhisperKit / FluidAudio Parakeet…).
    public var runtime: SpeechModelRuntime?
    /// The compute units the resident (or next) runtime is loaded with.
    public var computeUnits: SpeechComputeUnits
    /// A coarse hardware class token (`hw.machine` style), never a serial.
    public var machineClass: String?
    /// `CFBundleShortVersionString (CFBundleVersion)`.
    public var appVersion: String?

    public init(
        edition: DistributionEdition = .developerID,
        hasNotch: Bool? = nil,
        gpuCounterReadable: Bool? = nil,
        accessibilityTrusted: Bool? = nil,
        chromiumWebContentTarget: Bool? = nil,
        appleIntelligenceAvailability: AIProviderAvailability? = nil,
        privateCloudComputeAvailability: AIProviderAvailability? = nil,
        privateCloudComputeQuota: AIProviderQuota? = nil,
        enginePromptTokenLimit: PromptTokenLimit? = nil,
        catalogPromptTokenLimit: Int? = nil,
        memoryPressureLevel: MemoryPressureLevel = .normal,
        lastRealTimeFactor: Double? = nil,
        lastLoadDuration: Duration? = nil,
        residentFootprintBytes: UInt64? = nil,
        placement: ModelPlacementReport? = nil,
        residentModelID: ModelID? = nil,
        runtime: SpeechModelRuntime? = nil,
        computeUnits: SpeechComputeUnits = .default,
        machineClass: String? = nil,
        appVersion: String? = nil
    ) {
        self.edition = edition
        self.hasNotch = hasNotch
        self.gpuCounterReadable = gpuCounterReadable
        self.accessibilityTrusted = accessibilityTrusted
        self.chromiumWebContentTarget = chromiumWebContentTarget
        self.appleIntelligenceAvailability = appleIntelligenceAvailability
        self.privateCloudComputeAvailability = privateCloudComputeAvailability
        self.privateCloudComputeQuota = privateCloudComputeQuota
        self.enginePromptTokenLimit = enginePromptTokenLimit
        self.catalogPromptTokenLimit = catalogPromptTokenLimit
        self.memoryPressureLevel = memoryPressureLevel
        self.lastRealTimeFactor = lastRealTimeFactor
        self.lastLoadDuration = lastLoadDuration
        self.residentFootprintBytes = residentFootprintBytes
        self.placement = placement
        self.residentModelID = residentModelID
        self.runtime = runtime
        self.computeUnits = computeUnits
        self.machineClass = machineClass
        self.appVersion = appVersion
    }

    /// Nothing observed yet (launch, previews, tests that do not care).
    public static let unknown = EnvironmentProfile()

    // MARK: Derived facts the rules read

    /// `true` for `.tokens` and `.phrases` (ADR-025: Apple Speech takes the
    /// list as contextual phrases), `false` for `.unsupported`, `nil` while
    /// nothing is resident (the Dictionary rule then leaves the editor
    /// enabled and the estimate stands).
    public var residentModelAcceptsPrompt: Bool? {
        enginePromptTokenLimit.map { $0 != .unsupported }
    }

    /// Something is loaded that a compute-unit change could reload.
    public var residentModelLoaded: Bool {
        residentModelID != nil
    }

    /// The resident engine's cap as a number, when it has one.
    public var enginePromptTokenCap: Int? {
        if case .tokens(let cap) = enginePromptTokenLimit { return cap }
        return nil
    }
}
