import Foundation
import KvoiceDomain
import XCTest
@testable import KvoiceAppleIntelligence

/// ADR-024's allowed surface, enforced by scanning the source tree: the
/// Foundation Models framework is imported in exactly one file, that package
/// never opens a connection of its own, its sibling `_FoundationModels_*`
/// frameworks are untouched, and the app links the framework weakly so the
/// macOS 15 deployment target survives.
///
/// ADR-027 amended one rule deliberately: `PrivateCloudComputeLanguageModel`
/// was a forbidden spelling (ADR-024: "it is a network path"); it is now
/// allowed in `FoundationModelsRuntime.swift` **only**, behind
/// `#available(macOS 27, *)`, and the network it implies is the framework's
/// own — `URLSession`, `URLRequest`, `NWConnection` and `import Network`
/// stay forbidden.
final class AppleIntelligenceBoundaryTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KvoiceAppleIntelligenceTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // KvoiceAppleIntelligence
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
        swiftFiles(under: repositoryRoot.appendingPathComponent(
            "Packages/KvoiceAppleIntelligence/Sources/KvoiceAppleIntelligence"
        ))
    }

    func testFoundationModelsIsImportedInExactlyOneFile() throws {
        let importing = (Self.swiftFiles(under: Self.repositoryRoot.appendingPathComponent("Packages"))
            + Self.swiftFiles(under: Self.repositoryRoot.appendingPathComponent("Apps")))
            .filter { url in
                // The scan itself spells the import; tests are not adapters.
                guard !url.path.contains("/Tests/"),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return text.contains("import FoundationModels")
            }
            .map { $0.lastPathComponent }
        XCTAssertEqual(importing, ["FoundationModelsRuntime.swift"])
    }

    func testThePackageNeverSpellsANetworkOrASiblingFramework() throws {
        for url in Self.packageSources {
            // Strip comments: the doc comments name what is forbidden on purpose.
            let text = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for forbidden in [
                "URLSession", "URLRequest", "NWConnection", "import Network",
                "_FoundationModels_AppKit", "_FoundationModels_SwiftUI",
                "_CoreSpotlight_FoundationModels", "_Vision_FoundationModels",
                "try!", "nonisolated(unsafe)"
            ] {
                XCTAssertFalse(text.contains(forbidden), "\(url.lastPathComponent) must not use \(forbidden)")
            }
        }
    }

    /// ADR-027: the Private Cloud Compute model is named in the adapter
    /// file only — nothing else in the app may reach Apple's servers by a
    /// side door.
    func testPrivateCloudComputeIsNamedInTheAdapterFileOnly() throws {
        let naming = (Self.swiftFiles(under: Self.repositoryRoot.appendingPathComponent("Packages"))
            + Self.swiftFiles(under: Self.repositoryRoot.appendingPathComponent("Apps")))
            .filter { url in
                guard !url.path.contains("/Tests/"),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                // Code only: doc comments elsewhere name the type on purpose.
                return text.split(separator: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .contains { $0.contains("PrivateCloudComputeLanguageModel") }
            }
            .map { $0.lastPathComponent }
        XCTAssertEqual(naming, ["FoundationModelsRuntime.swift"])
    }

    func testEveryFrameworkUseIsBehindAnAvailabilityCheck() throws {
        let adapter = Self.repositoryRoot.appendingPathComponent(
            "Packages/KvoiceAppleIntelligence/Sources/KvoiceAppleIntelligence/FoundationModelsRuntime.swift"
        )
        let text = try String(contentsOf: adapter, encoding: .utf8)
        let parts = text.components(separatedBy: "public struct PrivateCloudComputeRuntime")
        XCTAssertEqual(parts.count, 2, "the Private Cloud Compute runtime lives in this file, after the on-device one")
        // Each public entry point guards on its OS before naming a framework
        // symbol; a `SystemLanguageModel` (macOS 26) or a
        // `PrivateCloudComputeLanguageModel` (macOS 27) reached without a
        // guard would crash an older system rather than report "requires".
        let checks: [(section: String, guardText: String, count: Int)] = [
            (parts[0], "#available(macOS 26", 5),
            (parts.count > 1 ? parts[1] : "", "#available(macOS 27", 7),
        ]
        for check in checks {
            let publicFunctions = check.section.components(separatedBy: "\n    public func ").dropFirst()
            XCTAssertEqual(publicFunctions.count, check.count, "entry points guarded by \(check.guardText)")
            for body in publicFunctions {
                let firstLines = body.split(separator: "\n").prefix(2).joined(separator: "\n")
                XCTAssertTrue(
                    firstLines.contains(check.guardText),
                    "an entry point must open with the availability guard: \(body.prefix(60))"
                )
            }
        }
    }

    func testThePackageDependsOnKvoiceDomainOnlyAndLinksTheFrameworkWeakly() throws {
        let manifest = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let target = try XCTUnwrap(manifest.range(of: ".target(\n            name: \"KvoiceAppleIntelligence\","))
        let block = manifest[target.lowerBound...].prefix(1200)
        XCTAssertTrue(block.contains("dependencies: [\"KvoiceDomain\"]"))
        XCTAssertTrue(block.contains("-weak_framework"))
        XCTAssertTrue(block.contains("FoundationModels"))
        XCTAssertFalse(block.contains("KvoiceAI\""), "the adapter shares the composer through KvoiceDomain, not the endpoint client")
    }

    func testThirdPartyNoticesAreUnchangedByASystemFramework() throws {
        let notices = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("THIRD_PARTY_NOTICES.md"),
            encoding: .utf8
        )
        XCTAssertFalse(notices.contains("FoundationModels"), "a system framework needs no third-party notice")
    }
}
