import Foundation
import KvoiceDomain

/// `SystemManagedModelAssets` over the Speech framework (ADR-025): what
/// `SpeechModelLibrary`'s system-managed manager drives to show the Apple
/// Speech card's state and to run its Install / Delete. Every call maps the
/// transcription language to a platform locale with
/// `AppleSpeechLocaleMapping` — the same function the engine uses, so the
/// card and the request path always talk about the same locale.
public struct AppleSpeechModelAssets: SystemManagedModelAssets {
    private let runtime: any AppleSpeechRuntime
    private let currentLocale: Locale

    public init(runtime: any AppleSpeechRuntime, currentLocale: Locale = .current) {
        self.runtime = runtime
        self.currentLocale = currentLocale
    }

    public func assetState(languageCode: String?) async -> SystemManagedAssetState {
        switch await runtime.availability() {
        case .requiresNewerMacOS: return .unavailable(.requiresNewerMacOS)
        case .deviceNotEligible: return .unavailable(.deviceNotEligible)
        case .available: break
        }
        guard let locale = await locale(forLanguageCode: languageCode) else {
            return .unavailable(.languageUnsupported)
        }
        switch await runtime.assetStatus(localeIdentifier: locale) {
        case .unsupported: return .unavailable(.languageUnsupported)
        case .supported: return .notInstalled
        case .downloading: return .downloading(fraction: 0)
        case .installed: return .installed
        }
    }

    public func installAssets(languageCode: String?, progress: @escaping @Sendable (Double) async -> Void) async throws {
        let availability = await runtime.availability()
        switch availability {
        case .requiresNewerMacOS: throw SystemManagedAssetError.unavailable(.requiresNewerMacOS)
        case .deviceNotEligible: throw SystemManagedAssetError.unavailable(.deviceNotEligible)
        case .available: break
        }
        guard let locale = await locale(forLanguageCode: languageCode) else {
            throw SystemManagedAssetError.unavailable(.languageUnsupported)
        }
        do {
            try await runtime.installAssets(localeIdentifier: locale, progress: progress)
        } catch let error as AppleSpeechError {
            throw Self.mapped(error)
        }
    }

    public func releaseAssets(languageCode: String?) async throws {
        guard await runtime.availability() == .available,
              let locale = await locale(forLanguageCode: languageCode) else { return }
        await runtime.releaseAssets(localeIdentifier: locale)
    }

    public func supportedLanguageCodes() async -> [String] {
        guard await runtime.availability() == .available else { return [] }
        return AppleSpeechLocaleMapping.languageCodes(forSupportedLocales: await runtime.supportedLocaleIdentifiers())
    }

    private func locale(forLanguageCode code: String?) async -> String? {
        AppleSpeechLocaleMapping.localeIdentifier(
            forLanguageCode: code,
            supportedLocales: await runtime.supportedLocaleIdentifiers(),
            current: currentLocale
        )
    }

    static func mapped(_ error: AppleSpeechError) -> SystemManagedAssetError {
        switch error {
        case .unavailable(.requiresNewerMacOS): return .unavailable(.requiresNewerMacOS)
        case .unavailable: return .unavailable(.deviceNotEligible)
        case .unsupportedLanguage: return .unavailable(.languageUnsupported)
        case .tooManyReservedLocales: return .tooManyReservedLocales
        case .assetsNotInstalled: return .assetsMissing
        case .downloadFailed, .audioFormatRejected, .insufficientResources, .analysisFailed: return .downloadFailed
        }
    }
}
