import Foundation
import KvoiceDomain

/// Reads the bundled developer defaults and the optional developer override
/// once, at launch (ADR-022 item 1). Never hot-reloaded: a value read at
/// composition is what every consumer was built with, so nothing has to
/// re-check a file mid-job.
///
/// - The **bundled** file (`kvoice.defaults.json` in the app bundle) is
///   the shipped table. It is expected to equal `DeveloperDefaults.compiled`
///   (tested); if it is missing or unreadable the compiled values stand,
///   because the build never depends on a JSON file.
/// - The **override** file (`~/Library/Application Support/kvoice/
///   config.override.json`) is a partial object: any subset of the keys.
///   Unknown keys are ignored. A file that is not valid JSON, not an object,
///   or carries a value outside `DeveloperDefaults.validationBounds` is
///   ignored *whole* with one scalar `config.override.rejected` line
///   (`reason`, and `site` = the key for `outOfRange`); a file that applies
///   logs one `config.override.loaded` line with the count of keys it set.
///   Values never reach the log.
public struct DeveloperDefaultsLoader: Sendable {
    public static let overrideFileName = "config.override.json"

    private let bundledURL: URL?
    private let overrideURL: URL?

    /// - Parameters:
    ///   - bundledURL: `kvoice.defaults.json` in the app bundle (nil in a
    ///     process without one; the compiled values stand).
    ///   - overrideURL: the developer override path; nil disables overrides.
    public init(bundledURL: URL?, overrideURL: URL?) {
        self.bundledURL = bundledURL
        self.overrideURL = overrideURL
    }

    /// The production paths: the main bundle's resource and the
    /// Application Support file.
    public static func standard(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> DeveloperDefaultsLoader {
        DeveloperDefaultsLoader(
            bundledURL: bundle.url(forResource: "kvoice.defaults", withExtension: "json"),
            overrideURL: defaultOverrideURL(fileManager: fileManager)
        )
    }

    public static func defaultOverrideURL(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("kvoice", isDirectory: true)
            .appendingPathComponent(overrideFileName, isDirectory: false)
    }

    /// Loads both files and logs the override's outcome (one line at most).
    public func load(diagnostics: (any DiagnosticLogging)?) async -> LoadedDeveloperDefaults {
        let loaded = loadWithoutLogging()
        if let diagnostics, let event = Self.diagnosticEvent(for: loaded.overrideOutcome) {
            await diagnostics.log(event)
        }
        return loaded
    }

    /// The pure read, for callers that log themselves (and for tests).
    public func load() -> LoadedDeveloperDefaults {
        loadWithoutLogging()
    }

    private func loadWithoutLogging() -> LoadedDeveloperDefaults {
        var values = DeveloperDefaults.compiled
        if let bundledURL,
           let data = try? Data(contentsOf: bundledURL),
           let bundled = try? JSONDecoder().decode(DeveloperDefaults.self, from: data),
           bundled.validationFailure == nil {
            values = bundled
        }

        guard let overrideURL, FileManager.default.fileExists(atPath: overrideURL.path) else {
            return LoadedDeveloperDefaults(values: values, overrideOutcome: .absent)
        }
        guard let data = try? Data(contentsOf: overrideURL) else {
            return LoadedDeveloperDefaults(values: values, overrideOutcome: .rejected(reason: .unreadable, key: nil))
        }
        // The outcome first: arguments evaluate left to right, so passing
        // `values` beside the `inout` call would copy it before the merge.
        let outcome = Self.apply(overrideData: data, to: &values)
        return LoadedDeveloperDefaults(values: values, overrideOutcome: outcome)
    }

    /// Merges one override object into `values`; separated so a test can
    /// feed bytes directly. `values` is untouched on rejection.
    static func apply(overrideData data: Data, to values: inout DeveloperDefaults) -> LoadedDeveloperDefaults.OverrideOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return .rejected(reason: .malformed, key: nil)
        }
        guard let object = json as? [String: Any] else {
            return .rejected(reason: .notAnObject, key: nil)
        }
        // Only the known keys count as overridden; unknown ones are ignored
        // (a key from a newer or older build must not refuse the file).
        let named = DeveloperDefaults.CodingKeys.allCases.filter { object[$0.rawValue] != nil }
        guard !named.isEmpty else { return .applied([]) }

        // Decode the override *on top of* the current values: re-encode the
        // current table, overlay the file's known keys, decode once. A type
        // mismatch (a string where a number belongs) is `malformed`.
        guard var merged = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(values)) as? [String: Any] else {
            return .rejected(reason: .malformed, key: nil)
        }
        for key in named {
            merged[key.rawValue] = object[key.rawValue]
        }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let candidate = try? JSONDecoder().decode(DeveloperDefaults.self, from: mergedData) else {
            return .rejected(reason: .malformed, key: nil)
        }
        if let failure = candidate.validationFailure {
            return .rejected(reason: .outOfRange, key: failure)
        }
        values = candidate
        return .applied(named)
    }

    /// The one line the outcome produces, or nil when the file is absent.
    public static func diagnosticEvent(for outcome: LoadedDeveloperDefaults.OverrideOutcome) -> DiagnosticEvent? {
        switch outcome {
        case .absent:
            return nil
        case .applied(let keys):
            return DiagnosticEvent(
                name: .configOverrideLoaded,
                result: .success,
                attributes: DiagnosticAttributes(fileCount: keys.count)
            )
        case .rejected(let reason, let key):
            return DiagnosticEvent(
                name: .configOverrideRejected,
                result: .warning,
                attributes: DiagnosticAttributes(reason: reason.rawValue, site: key?.rawValue)
            )
        }
    }
}
