import AppKit
import Foundation
import KvoiceDomain
import Observation

/// Entry count and on-disk size of the history store (spec D.6 § 5).
public struct HistoryMetrics: Sendable, Equatable {
    public let entryCount: Int
    public let databaseBytes: Int64

    public init(entryCount: Int, databaseBytes: Int64) {
        self.entryCount = entryCount
        self.databaseBytes = databaseBytes
    }
}

/// State for the Privacy & About tab (spec D.6 § 6).
///
/// Every fact shown comes in through the initializer or a closure the app
/// shell supplies; the view model reads no files and opens no windows on its
/// own. `copyDiagnostics()` is the one action that writes to the pasteboard,
/// and it writes only the redacted `DiagnosticsReport`.
@Observable
@MainActor
public final class PrivacyAboutViewModel {
    public static let runtimeDescription = "WhisperKit 1.1.0 (CoreML, on-device)"
    public static let bundleIdentifier = "io.github.kccarlos.kvoice"

    public let appVersion: String
    public let buildNumber: String
    public let dataFolderURL: URL?
    /// Host the managed model is downloaded from, for the network matrix.
    public let modelRepositoryHost: String?
    public private(set) var modelManifestDescription: String?
    public private(set) var licensesText: String?
    public private(set) var historyMetrics: HistoryMetrics?
    public private(set) var lastCopiedAt: Date?

    private let licensesProvider: @MainActor () -> String?
    private let diagnosticsProvider: @MainActor () -> DiagnosticsSnapshot?
    private let historyMetricsProvider: @MainActor () async -> HistoryMetrics?
    private let copyToPasteboard: @MainActor (String) -> Void
    private let openFolder: @MainActor (URL) -> Void

    public init(
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0",
        buildNumber: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
        dataFolderURL: URL? = nil,
        modelRepositoryHost: String? = nil,
        modelManifestDescription: String? = nil,
        licensesProvider: @escaping @MainActor () -> String? = { nil },
        diagnosticsProvider: @escaping @MainActor () -> DiagnosticsSnapshot? = { nil },
        historyMetrics: @escaping @MainActor () async -> HistoryMetrics? = { nil },
        copyToPasteboard: @escaping @MainActor (String) -> Void = PrivacyAboutViewModel.systemCopy,
        openFolder: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.dataFolderURL = dataFolderURL
        self.modelRepositoryHost = modelRepositoryHost
        self.modelManifestDescription = modelManifestDescription
        self.licensesProvider = licensesProvider
        self.diagnosticsProvider = diagnosticsProvider
        self.historyMetricsProvider = historyMetrics
        self.copyToPasteboard = copyToPasteboard
        self.openFolder = openFolder
    }

    public var versionDescription: String {
        "\(appVersion) (\(buildNumber))"
    }

    public func setModelManifestDescription(_ description: String?) {
        modelManifestDescription = description
    }

    /// Reads the notices once; the file cannot change while the app runs, so
    /// reopening the sheet must not re-read it.
    public func loadLicenses() {
        guard licensesText == nil else { return }
        licensesText = licensesProvider()
    }

    public func refreshHistoryMetrics() async {
        historyMetrics = await historyMetricsProvider()
    }

    public func openDataFolder() {
        guard let dataFolderURL else { return }
        openFolder(dataFolderURL)
    }

    /// Copies the redacted report. Returns the text so tests can inspect what
    /// would have reached the pasteboard.
    @discardableResult
    public func copyDiagnostics(now: Date = Date()) -> String? {
        guard let snapshot = diagnosticsProvider() else { return nil }
        let report = DiagnosticsReport.render(snapshot, generatedAt: now)
        copyToPasteboard(report)
        lastCopiedAt = now
        return report
    }

    public var historyMetricsDescription: String? {
        guard let historyMetrics else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: historyMetrics.databaseBytes, countStyle: .file)
        let entries = historyMetrics.entryCount == 1 ? String(localized: "1 entry", bundle: .module) : String(localized: "\(historyMetrics.entryCount) entries", bundle: .module)
        return "\(entries) · \(size)"
    }

    /// Default pasteboard writer. Public only so it can be a default argument.
    public static func systemCopy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
