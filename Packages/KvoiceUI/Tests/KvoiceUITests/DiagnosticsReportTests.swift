import XCTest
@testable import KvoiceDomain
@testable import KvoiceUI

/// FR-DIAG-005: Copy Diagnostics carries versions, status, and flags only.
/// The canaries below are the things that must never appear.
@MainActor
final class DiagnosticsReportTests: XCTestCase {
    private let apiKeyCanary = "sk-CANARY-SECRET-KEY-0123456789"
    private let transcriptCanary = "CANARY the quick brown fox dictated this"
    private let userinfoCanary = "canaryuser:canarypass"

    private var adversarialSnapshot: DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: "1.2.3",
            buildNumber: "456",
            macOSVersion: "26.6.2",
            activationPolicy: "accessory",
            // A failure message that echoes a transcript must not survive.
            modelState: .error(ModelFailure(code: "model.load.failed", message: transcriptCanary)),
            shortcut: ShortcutDefinition(key: "space", modifiers: ["control", "shift"]),
            shortcutRegistration: .failed(.appBusy),
            recordingInteraction: .pushToTalk,
            aiMode: .polish,
            aiEndpoint: URL(string: "https://\(userinfoCanary)@api.example.com:8443/v1/chat/completions?api_key=\(apiKeyCanary)#\(apiKeyCanary)"),
            historyEnabled: true,
            escapeMonitorStatus: "active",
            typedInsertionEnabled: false,
            launchAtLoginStatus: .requiresApproval
        )
    }

    func testReportContainsNoSecretsTranscriptsOrFullURLs() {
        let report = DiagnosticsReport.render(adversarialSnapshot, generatedAt: Date(timeIntervalSince1970: 0))

        XCTAssertFalse(report.contains(apiKeyCanary), report)
        XCTAssertFalse(report.contains("CANARY"), report)
        XCTAssertFalse(report.contains(userinfoCanary), report)
        XCTAssertFalse(report.contains("canarypass"), report)
        XCTAssertFalse(report.contains("/v1/chat"), report)
        XCTAssertFalse(report.contains("api_key"), report)
        XCTAssertFalse(report.contains("@api.example.com"), report)

        XCTAssertTrue(report.contains("AI endpoint: https://api.example.com:8443"), report)
        XCTAssertTrue(report.contains("Model: error code=model.load.failed"), report)
        XCTAssertTrue(report.contains("App version: 1.2.3 (456)"), report)
        XCTAssertTrue(report.contains("macOS: 26.6.2"), report)
        XCTAssertTrue(report.contains("Activation policy: accessory"), report)
        XCTAssertTrue(report.contains("Shortcut: Control-Shift-Space"), report)
        XCTAssertTrue(report.contains("Shortcut registration: failed code=APP-BUSY"), report)
        XCTAssertTrue(report.contains("Recording mode: pushToTalk"), report)
        XCTAssertTrue(report.contains("AI mode: polish"), report)
        XCTAssertTrue(report.contains("AI provider: openAICompatible"), report)
        XCTAssertTrue(report.contains("Apple Intelligence: not observed"), report)
        XCTAssertTrue(report.contains("History enabled: true"), report)
        XCTAssertTrue(report.contains("Escape monitor: active"), report)
        XCTAssertTrue(report.contains("Typed insertion: false"), report)
        XCTAssertTrue(report.contains("Launch at Login: requiresApproval"), report)
        XCTAssertTrue(report.contains("Runtime: WhisperKit 1.1.0"), report)
    }

    /// ADR-024: the on-device transport shows as such, never as "not
    /// configured", and the availability travels as its case name only.
    func testOnDeviceProviderRendersItsTransportAndAvailability() {
        var snapshot = adversarialSnapshot
        snapshot.aiProvider = .appleIntelligence
        snapshot.aiEndpoint = nil
        snapshot.appleIntelligenceAvailability = .unavailable(.modelNotReady)
        let report = DiagnosticsReport.render(snapshot, generatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(report.contains("AI provider: appleIntelligence"), report)
        XCTAssertTrue(report.contains("AI endpoint: on-device"), report)
        XCTAssertTrue(report.contains("Apple Intelligence: unavailable (modelNotReady)"), report)
        snapshot.appleIntelligenceAvailability = .available
        XCTAssertTrue(DiagnosticsReport.render(snapshot).contains("Apple Intelligence: available"))
    }

    func testEndpointRedactionKeepsSchemeHostPortOnly() {
        XCTAssertEqual(DiagnosticsReport.redactedEndpoint(nil), "not configured")
        XCTAssertEqual(
            DiagnosticsReport.redactedEndpoint(URL(string: "http://localhost:11434/v1")),
            "http://localhost:11434"
        )
        XCTAssertEqual(
            DiagnosticsReport.redactedEndpoint(URL(string: "https://u:p@example.com/x?k=v")),
            "https://example.com"
        )
    }

    func testReadyStateDescribesIdentityNotPaths() {
        let summary = InstalledModelSummary(
            modelID: "whisper-large-v3-turbo",
            revision: "abc123",
            ownership: .externalReadOnly
        )
        XCTAssertEqual(
            DiagnosticsReport.describe(.ready(summary)),
            "ready whisper-large-v3-turbo@abc123 (externalReadOnly)"
        )
        XCTAssertEqual(DiagnosticsReport.describe(.downloading(completed: 10, total: 100)), "downloading 10/100 bytes")
    }

    func testCopyDiagnosticsWritesTheRedactedReportOnly() {
        var copied: [String] = []
        let model = PrivacyAboutViewModel(
            appVersion: "1.0",
            buildNumber: "1",
            diagnosticsProvider: { [snapshot = adversarialSnapshot] in snapshot },
            copyToPasteboard: { copied.append($0) }
        )

        let report = model.copyDiagnostics(now: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(copied.first, report)
        XCTAssertFalse(copied.first?.contains(apiKeyCanary) ?? true)
        XCTAssertFalse(copied.first?.contains("CANARY") ?? true)
        XCTAssertNotNil(model.lastCopiedAt)
    }

    func testCopyDiagnosticsWithoutAProviderCopiesNothing() {
        var copied: [String] = []
        let model = PrivacyAboutViewModel(copyToPasteboard: { copied.append($0) })
        XCTAssertNil(model.copyDiagnostics())
        XCTAssertTrue(copied.isEmpty)
        XCTAssertNil(model.lastCopiedAt)
    }

    func testHistoryMetricsDescription() async {
        let model = PrivacyAboutViewModel(historyMetrics: { HistoryMetrics(entryCount: 1, databaseBytes: 2_048) })
        XCTAssertNil(model.historyMetricsDescription)
        await model.refreshHistoryMetrics()
        XCTAssertTrue(model.historyMetricsDescription?.hasPrefix("1 entry · ") ?? false)
    }

    func testPrivacyAndModelViewsCanBeConstructed() {
        XCTAssertNotNil(PrivacyAboutView(viewModel: PrivacyAboutViewModel(copyToPasteboard: { _ in })))
        XCTAssertNotNil(ModelSettingsView())
    }
}
