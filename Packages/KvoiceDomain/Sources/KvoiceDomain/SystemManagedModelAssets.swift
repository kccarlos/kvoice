import Foundation

// MARK: - System-managed model assets (ADR-025)

/// The lifecycle of a speech model whose weights the *operating system*
/// owns — Apple Speech through `AssetInventory` (ADR-025). There is no
/// manifest, no digest, no download client and nothing on kvoice's disk:
/// the platform fetches, verifies and stores the assets and shares them
/// between apps, and kvoice only holds a per-locale *reservation*.
///
/// `SpeechModelLibrary` drives one `SystemManagedModelManager` per
/// system-managed catalog entry over this seam, the way it drives a
/// `ModelPackageManager` over the download client for a kvoice-manifest
/// entry. The adapter package (`KvoiceAppleSpeech`) implements it; the
/// library and its tests use a fake. No framework type appears here.
///
/// Every method takes the transcription-language *code* the user chose
/// (`AppSettings.transcriptionLanguage`, a Whisper code; `nil` = automatic,
/// which for a system runtime means the Mac's own language) because the
/// platform's assets are per locale: "installed" is only meaningful for
/// the language about to be dictated. The adapter maps the code to the
/// platform locale.
public protocol SystemManagedModelAssets: Sendable {
    /// Whether the runtime exists on this Mac (framework present, hardware
    /// eligible) and, if so, the assets' state for the language. Cheap; the
    /// library reads it on every refresh and after every operation.
    func assetState(languageCode: String?) async -> SystemManagedAssetState

    /// Reserves the language's locale for this app and downloads whatever
    /// the platform does not already hold, reporting progress in 0…1.
    /// Returns when the platform's first attempt succeeded or failed;
    /// throws `SystemManagedAssetError` only.
    func installAssets(languageCode: String?, progress: @escaping @Sendable (Double) async -> Void) async throws

    /// Releases this app's reservation for the language's locale; the
    /// platform removes the assets later, on its own schedule. Idempotent.
    func releaseAssets(languageCode: String?) async throws

    /// The transcription-language codes (Whisper codes) the runtime reports
    /// it can transcribe on this Mac, sorted; empty when the runtime is
    /// unavailable. Observed, never hard-coded — the catalog's shipped list
    /// stands in until this has been read.
    func supportedLanguageCodes() async -> [String]
}

/// What the platform says about a system-managed model's assets for one
/// language (ADR-025). Maps onto `ModelLifecycleState` in the library:
/// `.unavailable` → `.unavailable(reason)`, `.notInstalled` → `.absent`,
/// `.downloading` → `.downloading`, `.installed` → `.ready`.
public enum SystemManagedAssetState: Sendable, Equatable {
    /// The runtime cannot serve this Mac or this language at all; the card
    /// shows `reason` with no action (nothing to retry, nothing to delete).
    case unavailable(SystemManagedUnavailableReason)
    /// Supported, assets not on the device (or not reserved by this app).
    case notInstalled
    /// The platform is fetching the assets (this app's request or another
    /// app's); `fraction` is the last progress seen, 0…1.
    case downloading(fraction: Double)
    /// Reserved and on the device.
    case installed
}

/// Why a system-managed model cannot be installed on this Mac. Each
/// `message` is the English sentence the card shows (a `DomainCopy` key;
/// `DomainCopyTests` checks the translation exists).
public enum SystemManagedUnavailableReason: String, Sendable, Equatable, CaseIterable {
    /// The framework is absent: this build runs on a macOS older than 26.
    case requiresNewerMacOS
    /// The framework reports the module unavailable on this hardware
    /// (`SpeechTranscriber.isAvailable == false`).
    case deviceNotEligible
    /// The chosen transcription language has no supported locale on this
    /// Mac (`AssetInventory.Status.unsupported`).
    case languageUnsupported

    public var message: String {
        switch self {
        case .requiresNewerMacOS:
            return "Requires macOS 26 or later."
        case .deviceNotEligible:
            return "Apple Speech isn't available on this Mac."
        case .languageUnsupported:
            return "Apple Speech doesn't support the selected transcription language on this Mac."
        }
    }

    /// The bounded token for `ModelFailure.code` and diagnostics.
    public var code: String {
        switch self {
        case .requiresNewerMacOS: return "MODEL-REQUIRES-NEWER-MACOS"
        case .deviceNotEligible: return "MODEL-DEVICE-NOT-ELIGIBLE"
        case .languageUnsupported: return "MODEL-LANGUAGE-UNSUPPORTED"
        }
    }
}

/// What can go wrong installing or releasing system-managed assets. Every
/// case is a scalar (rule 3); the platform's own message is reduced to a
/// case before it leaves the adapter.
public enum SystemManagedAssetError: Error, Sendable, Equatable {
    /// The runtime is not usable on this Mac; the reason is the state's.
    case unavailable(SystemManagedUnavailableReason)
    /// Reserving the language would exceed the platform's per-app
    /// reservation cap (`AssetInventory.maximumReservedLocales` — 5 on a
    /// test Mac, "may vary between devices according to storage space";
    /// `SFSpeechError.Code.tooManyAssetLocalesAllocated`). The user frees
    /// one by deleting another language's assets. The cap is not in the
    /// sentence so the sentence stays one `DomainCopy` key.
    case tooManyReservedLocales
    /// The platform's download failed (connectivity, storage, an unknown
    /// error). The platform retries on its own later; `Retry` asks again.
    case downloadFailed
    /// The platform reported it has no model for this configuration
    /// (`SFSpeechError.Code.noModel` / `.assetLocaleNotAllocated`).
    case assetsMissing

    /// The sentence the card shows under "Error —"; a `DomainCopy` key.
    public var message: String {
        switch self {
        case .unavailable(let reason):
            return reason.message
        case .tooManyReservedLocales:
            return "macOS limits how many languages KVoice can keep Apple Speech assets for. Delete another language's assets first."
        case .downloadFailed:
            return "The Apple Speech assets could not be downloaded. Check the connection and try again."
        case .assetsMissing:
            return "The Apple Speech assets for this language are not on this Mac yet."
        }
    }

    /// The bounded token for `ModelFailure.code` and diagnostics.
    public var code: String {
        switch self {
        case .unavailable(let reason): return reason.code
        case .tooManyReservedLocales: return "MODEL-ASSET-RESERVATION-LIMIT"
        case .downloadFailed: return "MODEL-ASSET-DOWNLOAD-FAILED"
        case .assetsMissing: return "MODEL-ASSETS-MISSING"
        }
    }

    /// Every sentence this error can show, for `DomainUserFacingCopy` (the
    /// enum has an associated value, so it is not `CaseIterable`).
    public static let messageInventory: [String] = [
        SystemManagedAssetError.tooManyReservedLocales,
        .downloadFailed,
        .assetsMissing
    ].map(\.message)

    /// The failure the card shows for this error.
    public var modelFailure: ModelFailure {
        ModelFailure(code: code, message: message)
    }
}

public extension SystemManagedUnavailableReason {
    /// The failure the card shows for this reason.
    var modelFailure: ModelFailure {
        ModelFailure(code: code, message: message)
    }
}

public extension InstalledModelPackage {
    /// The revision every system-managed package reports: the OS owns the
    /// version and kvoice never pins one.
    static let systemManagedRevision = "system"

    /// The package the library hands `TranscriptionEngine.load` for a
    /// system-managed entry (ADR-025): the identity, and nothing on disk.
    /// The URLs point at nothing on purpose — an engine that tried to open
    /// them would be the wrong engine for the entry.
    static func systemManaged(modelID: ModelID, family: String) -> InstalledModelPackage {
        let nowhere = URL(fileURLWithPath: "/dev/null")
        return InstalledModelPackage(
            manifest: ModelManifest(
                schemaVersion: 0,
                modelID: modelID,
                family: family,
                format: "system",
                workingSpaceBytes: 0,
                source: ModelManifestSource(repository: "system", revision: systemManagedRevision, subdirectory: ""),
                runtimeCompatibility: ModelRuntimeCompatibility(swiftPackage: "system", exactVersion: "system"),
                tokenizer: ModelTokenizer(relativeRoot: "", offlineRequired: false),
                files: []
            ),
            packageURL: nowhere,
            modelFolderURL: nowhere,
            tokenizerFolderURL: nowhere,
            ownership: .systemManaged
        )
    }
}
