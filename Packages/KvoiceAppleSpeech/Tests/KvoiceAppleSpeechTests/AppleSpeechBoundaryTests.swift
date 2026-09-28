import AVFoundation
import Foundation
import KvoiceDomain
import XCTest
@testable import KvoiceAppleSpeech

/// ADR-025's allowed surface, enforced by scanning the source tree: the
/// Speech framework is imported in exactly one file, that package never
/// reaches for the network or the old `SFSpeechRecognizer` API, every
/// framework entry point opens with the availability guard, and the app
/// links the framework weakly so the macOS 15 deployment target survives.
final class AppleSpeechBoundaryTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KvoiceAppleSpeechTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // KvoiceAppleSpeech
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    private static func swiftFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private static var packageSources: [URL] {
        swiftFiles(under: repositoryRoot.appendingPathComponent("Packages/KvoiceAppleSpeech/Sources/KvoiceAppleSpeech"))
    }

    private static let adapter = repositoryRoot.appendingPathComponent(
        "Packages/KvoiceAppleSpeech/Sources/KvoiceAppleSpeech/SpeechFrameworkRuntime.swift"
    )

    func testSpeechIsImportedInExactlyOneFile() throws {
        let importing = (Self.swiftFiles(under: Self.repositoryRoot.appendingPathComponent("Packages"))
            + Self.swiftFiles(under: Self.repositoryRoot.appendingPathComponent("Apps")))
            .filter { url in
                // The scan itself spells the import; tests are not adapters.
                guard !url.path.contains("/Tests/"),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return text.contains("import Speech\n")
            }
            .map { $0.lastPathComponent }
        XCTAssertEqual(importing, ["SpeechFrameworkRuntime.swift"])
    }

    func testThePackageNeverSpellsANetworkTheOldAPIOrAnUnsafeConstruct() throws {
        for url in Self.packageSources {
            // Strip comments: the doc comments name what is forbidden on purpose.
            let text = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for forbidden in [
                "URLSession", "URLRequest", "NWConnection", "import Network",
                "SFSpeechRecognizer", "SFSpeechRecognitionRequest", "requestAuthorization",
                "DictationTranscriber(", "SFSpeechLanguageModel",
                "try!", "nonisolated(unsafe)"
            ] {
                XCTAssertFalse(text.contains(forbidden), "\(url.lastPathComponent) must not use \(forbidden)")
            }
        }
    }

    func testEveryFrameworkEntryPointIsBehindAnAvailabilityCheck() throws {
        let text = try String(contentsOf: Self.adapter, encoding: .utf8)
        // Each public entry point of the runtime guards on macOS 26 before
        // naming a framework symbol; a `SpeechTranscriber` reached without a
        // guard would crash a macOS 15 user rather than report "requires
        // macOS 26". The one property (`maximumReservedLocales`) guards
        // inside its getter, so it is checked by its own line below.
        let publicFunctions = text.components(separatedBy: "\n    public func ").dropFirst()
        XCTAssertEqual(publicFunctions.count, 8, "the runtime's eight entry points")
        for body in publicFunctions {
            // The first statement after the signature's opening brace (a
            // signature may span several lines).
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            let opening = lines.firstIndex { $0.hasSuffix("{") } ?? 0
            let firstStatement = lines.dropFirst(opening + 1).first.map(String.init) ?? ""
            XCTAssertTrue(
                firstStatement.contains("#available(macOS 26"),
                "an entry point must open with the availability guard: \(body.prefix(60))"
            )
        }
        XCTAssertTrue(text.contains("public var maximumReservedLocales: Int {\n        get async {\n            guard #available(macOS 26, *)"))
        // The session and the converters are unreachable below macOS 26.
        XCTAssertTrue(text.contains("@available(macOS 26, *)\nprivate actor SpeechFrameworkSession"))
        XCTAssertTrue(text.contains("@available(macOS 27, *)\nprivate final class FrameworkInputConversion"))
    }

    func testTheAdapterNeverHandsTheAnalyzerAFloatBuffer() throws {
        // Observed on macOS 27.0: `AnalyzerInput(buffer:)` traps on a
        // Float32 buffer. Every `AnalyzerInput` the adapter builds must come
        // out of a converter, never straight from kvoice's samples.
        let text = try String(contentsOf: Self.adapter, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let direct = text.components(separatedBy: "AnalyzerInput(buffer:").count - 1
        XCTAssertEqual(direct, 1, "one AnalyzerInput(buffer:) — the converted buffer in the macOS 26 path")
        XCTAssertTrue(text.contains("AnalyzerInput(buffer: output)"))
        XCTAssertFalse(text.contains("AnalyzerInput(buffer: source)"))
    }

    func testOnlyIntegerPCMAnalyzerFormatsAreAcceptedAndReservationsMatchByLanguageAndRegion() throws {
        // The real guard behind the text scan above: a session refuses a
        // platform format `AnalyzerInput(buffer:)` would trap on.
        func format(_ common: AVAudioCommonFormat, interleaved: Bool = true) -> AVAudioFormat {
            try! XCTUnwrap(AVAudioFormat(commonFormat: common, sampleRate: 16_000, channels: 1, interleaved: interleaved))
        }
        XCTAssertTrue(SpeechFrameworkRuntime.isAcceptedAnalyzerFormat(format(.pcmFormatInt16)))
        XCTAssertTrue(SpeechFrameworkRuntime.isAcceptedAnalyzerFormat(format(.pcmFormatInt16, interleaved: false)))
        XCTAssertTrue(SpeechFrameworkRuntime.isAcceptedAnalyzerFormat(format(.pcmFormatInt32)))
        XCTAssertFalse(SpeechFrameworkRuntime.isAcceptedAnalyzerFormat(format(.pcmFormatFloat32)))
        XCTAssertFalse(SpeechFrameworkRuntime.isAcceptedAnalyzerFormat(format(.pcmFormatFloat32, interleaved: false)))
        XCTAssertFalse(SpeechFrameworkRuntime.isAcceptedAnalyzerFormat(format(.pcmFormatFloat64)))
        // The platform may return a variant of the reserved locale.
        XCTAssertTrue(SpeechFrameworkRuntime.isReserved(Locale(identifier: "en_US"), in: ["en-US", "zh_CN"]))
        XCTAssertTrue(SpeechFrameworkRuntime.isReserved(Locale(identifier: "zh-Hans_CN"), in: ["zh_CN"]))
        XCTAssertFalse(SpeechFrameworkRuntime.isReserved(Locale(identifier: "en_GB"), in: ["en_US"]))
        XCTAssertFalse(SpeechFrameworkRuntime.isReserved(Locale(identifier: "en_US"), in: []))
    }

    func testThePackageDependsOnKvoiceDomainOnlyAndLinksTheFrameworkWeakly() throws {
        let manifest = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let target = try XCTUnwrap(manifest.range(of: ".target(\n            name: \"KvoiceAppleSpeech\","))
        let rest = manifest[target.upperBound...]
        // This target's block ends where the next target begins.
        let block = rest[..<(rest.range(of: "Target(\n")?.lowerBound ?? rest.endIndex)]
        XCTAssertTrue(block.contains("dependencies: [\"KvoiceDomain\"]"))
        XCTAssertTrue(block.contains("-weak_framework"))
        XCTAssertTrue(block.contains("\"Speech\""))
        XCTAssertFalse(block.contains("KvoiceTranscription\""), "the adapter shares nothing with WhisperKit")
        XCTAssertFalse(block.contains("KvoiceModelManagement"), "the library drives the adapter, never the reverse")
    }

    func testThirdPartyNoticesAreUnchangedByASystemFramework() throws {
        let notices = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("THIRD_PARTY_NOTICES.md"),
            encoding: .utf8
        )
        XCTAssertFalse(notices.contains("SpeechAnalyzer"), "a system framework needs no third-party notice")
        XCTAssertFalse(notices.contains("Speech.framework"))
    }

    func testTheInfoPlistAsksForNoSpeechRecognitionGrant() throws {
        // `SpeechAnalyzer` runs on-device without the speech-recognition
        // authorization the old API needs (observed with the status
        // `.notDetermined`); adding the usage string would prompt for a
        // grant kvoice never uses.
        let plist = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Apps/KvoiceApp/Info.plist"),
            encoding: .utf8
        )
        XCTAssertFalse(plist.contains("NSSpeechRecognitionUsageDescription"))
    }
}
