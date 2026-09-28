import Foundation
import KvoiceDomain

/// The key-value surface the migration writes through. `UserDefaults`
/// conforms as it is; tests pass a double that can refuse a write, which is
/// how the "a failure leaves nothing half-done" path is exercised.
public protocol PreferencesKeyValueStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: PreferencesKeyValueStore {}

/// One-time copy of the preferences written under the pre-2026-09-27 bundle
/// identifier `com.kccarlos.kvoice` into the current one,
/// `io.github.kccarlos.kvoice` (product decision 2026-09-27: the project is
/// published as github.com/kccarlos/kvoice).
///
/// macOS keys a non-sandboxed app's standard defaults by bundle identifier,
/// so without this the first launch under the new identifier would come up
/// with default settings, no recording shortcut, and a fresh onboarding.
/// Everything else kvoice stores — history, dictionary, the secrets file,
/// downloaded models, diagnostics — lives in `~/Library/Application Support/kvoice/`,
/// a folder name that was never the bundle identifier, so nothing on disk
/// moves. The `~/Library/Caches/com.kccarlos.kvoice/` folder holds only the
/// Core ML compile cache, which the system rebuilds; it is not copied.
///
/// **What is copied.** Every key of the legacy persistent domain (read with
/// `persistentDomain(forName:)`, never `dictionaryRepresentation()`, which
/// would fold in the global domain): kvoice's own blobs, the
/// KeyboardShortcuts recordings, window frames, and the interface-language
/// override. Keys that start with `com.kccarlos.kvoice.` are renamed to the
/// `io.github.kccarlos.kvoice.` prefix the stores now read; others keep
/// their name.
///
/// **Safety.** A key the current app domain already holds is never
/// overwritten. Membership is checked against that one persistent domain,
/// not through `object(forKey:)`, which falls through the search list to
/// `NSGlobalDomain` — `AppleLanguages` always exists there, so the
/// interface-language override would never have been copied.
/// Every written value is read back; only when all of them match is the
/// completion key recorded, so a crash or a refused write means the next
/// launch tries again, and a rerun after success does nothing. The legacy
/// domain is only read, never modified or removed.
///
/// **Diagnostics** carry counts only — never a key name or a value (rule 3).
public struct LegacyDefaultsDomainMigration {
    public static let legacyDomainName = "com.kccarlos.kvoice"
    public static let legacyKeyPrefix = "com.kccarlos.kvoice."
    public static let currentKeyPrefix = "io.github.kccarlos.kvoice."
    /// The current bundle identifier, used when `Bundle.main` has none.
    public static let currentDomainName = "io.github.kccarlos.kvoice"
    /// Written to the current domain only after a verified copy (or when
    /// there was nothing to copy).
    public static let completionKey = "io.github.kccarlos.kvoice.legacyDefaultsMigration.completed"

    public enum Outcome: Equatable, Sendable {
        /// The completion key was already set; nothing was read.
        case alreadyCompleted
        /// No legacy domain (a fresh install); completion recorded.
        case nothingToMigrate
        /// The copy was verified and completion recorded.
        /// `keptExistingKeyCount` counts legacy keys the current app
        /// domain itself already held (a value inherited from the global
        /// domain does not count; that key is copied).
        case migrated(copiedKeyCount: Int, keptExistingKeyCount: Int)
        /// At least one value did not read back; completion was not recorded
        /// and the next launch retries. The legacy domain is untouched.
        case failed(unverifiedKeyCount: Int)
    }

    private let readLegacyDomain: () -> [String: Any]?
    private let readCurrentDomain: () -> [String: Any]?
    private let target: any PreferencesKeyValueStore

    /// - Parameters:
    ///   - readLegacyDomain: returns the legacy persistent domain, or `nil`
    ///     when it does not exist.
    ///   - readCurrentDomain: returns the current app's own persistent
    ///     domain only (no global or argument layers), or `nil` when empty.
    ///   - target: the current identifier's defaults.
    public init(
        readLegacyDomain: @escaping () -> [String: Any]?,
        readCurrentDomain: @escaping () -> [String: Any]?,
        target: any PreferencesKeyValueStore
    ) {
        self.readLegacyDomain = readLegacyDomain
        self.readCurrentDomain = readCurrentDomain
        self.target = target
    }

    /// The production wiring: the legacy domain read through
    /// `UserDefaults.standard` (works for a non-sandboxed app) and written
    /// into the standard defaults of the running bundle.
    public static func standard() -> LegacyDefaultsDomainMigration {
        let currentDomain = Bundle.main.bundleIdentifier ?? currentDomainName
        return LegacyDefaultsDomainMigration(
            readLegacyDomain: { UserDefaults.standard.persistentDomain(forName: legacyDomainName) },
            readCurrentDomain: { UserDefaults.standard.persistentDomain(forName: currentDomain) },
            target: UserDefaults.standard
        )
    }

    /// The name a legacy key is stored under in the current domain.
    public static func currentKey(forLegacyKey key: String) -> String {
        guard key.hasPrefix(legacyKeyPrefix) else { return key }
        return currentKeyPrefix + key.dropFirst(legacyKeyPrefix.count)
    }

    /// Runs the migration once. Synchronous and cheap after the first
    /// success (one key read); call it before any store reads defaults.
    @discardableResult
    public func run() -> Outcome {
        let current = readCurrentDomain() ?? [:]
        if current[Self.completionKey] as? Bool == true {
            return .alreadyCompleted
        }
        guard let legacy = readLegacyDomain(), !legacy.isEmpty else {
            target.set(true, forKey: Self.completionKey)
            return .nothingToMigrate
        }

        var written: [(key: String, value: Any)] = []
        var keptExisting = 0
        for (legacyKey, value) in legacy where legacyKey != Self.completionKey {
            let key = Self.currentKey(forLegacyKey: legacyKey)
            if current[key] != nil {
                keptExisting += 1
                continue
            }
            target.set(value, forKey: key)
            written.append((key, value))
        }

        let unverified = written.filter { entry in
            guard let stored = target.object(forKey: entry.key) as? NSObject,
                  let expected = entry.value as? NSObject else { return true }
            return !stored.isEqual(expected)
        }.count
        guard unverified == 0 else {
            return .failed(unverifiedKeyCount: unverified)
        }
        target.set(true, forKey: Self.completionKey)
        return .migrated(copiedKeyCount: written.count, keptExistingKeyCount: keptExisting)
    }

    /// One scalar line for the outcome, or nothing when the migration had
    /// already completed on an earlier launch.
    public static func diagnosticEvent(for outcome: Outcome) -> DiagnosticEvent? {
        switch outcome {
        case .alreadyCompleted:
            return nil
        case .nothingToMigrate:
            return DiagnosticEvent(
                name: .settingsLegacyDomainMigration,
                result: .ignored,
                attributes: DiagnosticAttributes(fileCount: 0)
            )
        case .migrated(let copied, _):
            return DiagnosticEvent(
                name: .settingsLegacyDomainMigration,
                result: .success,
                attributes: DiagnosticAttributes(fileCount: copied)
            )
        case .failed(let unverified):
            return DiagnosticEvent(
                name: .settingsLegacyDomainMigration,
                result: .failure,
                attributes: DiagnosticAttributes(fileCount: unverified)
            )
        }
    }
}
