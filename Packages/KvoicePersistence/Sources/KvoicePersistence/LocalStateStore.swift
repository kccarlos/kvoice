import Foundation
import KvoiceDomain

/// The machine-local blob beside `SettingsStore` (ADR-022 slice 5): the same
/// actor + UserDefaults + one-JSON-value pattern, under its own key, so the
/// two can never be exported together by accident — `SettingsBackupEnvelope`
/// wraps an `AppSettings`, and this store's value is a different type.
///
/// **Migration (once).** Until 2026-09-16 `onboardingVersionCompleted`,
/// `tutorialSeen`, `mainWindowSection`, and the export folder's bookmark and
/// display path lived on `AppSettings`. On the first `load()` that finds no
/// local-state value, the settings blob under `SettingsStore.appSettingsKey`
/// is read leniently for those keys (`LocalState.seeded`), the result is
/// saved here, and from then on this key is the truth. The old keys vanish
/// from the settings blob on its next `SettingsStore.save` because
/// `AppSettings` no longer encodes them; nothing here rewrites that blob.
/// A settings file that never carried them (fresh install, or a blob written
/// after the split) seeds nothing and `load()` returns `.fresh`.
public actor LocalStateStore: LocalStateRepository {
    public static let localStateKey = "io.github.kccarlos.kvoice.localState"

    private let defaults: UserDefaultsBox
    private let settingsKey: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - suiteName: the defaults suite (`nil` = standard; tests pass their
    ///     own so nothing touches the real domain).
    ///   - legacySettingsKey: where the pre-split `AppSettings` blob lives,
    ///     for the one-time seeding.
    public init(suiteName: String? = nil, legacySettingsKey: String = SettingsStore.appSettingsKey) {
        self.defaults = UserDefaultsBox(suiteName: suiteName)
        self.settingsKey = legacySettingsKey
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    /// Loads the local state. A missing value seeds from the legacy settings
    /// blob once (or is a fresh install); a malformed value is quarantined
    /// (removed) and resolves to `.fresh` so a bad file can never prevent
    /// launch.
    public func load() throws -> LocalState {
        if let data = defaults.value.data(forKey: Self.localStateKey) {
            do {
                return try decoder.decode(LocalState.self, from: data)
            } catch {
                defaults.value.removeObject(forKey: Self.localStateKey)
                return .fresh
            }
        }
        if let legacy = defaults.value.data(forKey: settingsKey),
           let seeded = LocalState.seeded(fromLegacySettingsData: legacy) {
            try? save(seeded)
            return seeded
        }
        return .fresh
    }

    /// Saves the whole value in one write, decoded back first so an
    /// unencodable field is caught here rather than on the next launch.
    public func save(_ state: LocalState) throws {
        do {
            let data = try encoder.encode(state)
            guard try decoder.decode(LocalState.self, from: data) == state else {
                throw KVoiceError(code: .settingsCorrupt)
            }
            defaults.value.set(data, forKey: Self.localStateKey)
        } catch let error as KVoiceError {
            throw error
        } catch {
            throw KVoiceError(code: .settingsCorrupt)
        }
    }

    /// Clears the stored value (tests).
    public func reset() {
        defaults.value.removeObject(forKey: Self.localStateKey)
    }
}
