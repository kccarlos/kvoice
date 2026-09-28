import XCTest

/// ADR-026: the app's privacy manifest declares exactly the required-reason
/// API categories kvoice's own code uses, no tracking and no collected data.
/// The categories are derived by scanning the sources for the API names in
/// Apple's list (Describing use of required reason API), so adding a use of
/// one of them without updating the manifest fails here, and so does a
/// declaration nothing uses any more.
final class PrivacyManifestTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KvoiceAppCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // KvoiceAppCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
    }

    /// Apple's API names per category (the `NSPrivacyAccessedAPIType`
    /// documentation, 2026-09). `stat` is matched as a call in every spelling
    /// a Swift file would use (` stat(`, `(stat(`, `=stat(`, `Darwin.stat(`),
    /// so the word in prose does not count.
    private static let categoryTokens: [String: [String]] = [
        "NSPrivacyAccessedAPICategoryUserDefaults": ["UserDefaults"],
        "NSPrivacyAccessedAPICategoryDiskSpace": [
            "volumeAvailableCapacity", "volumeTotalCapacity", "systemFreeSize", "systemSize",
            "statfs(", "statvfs(", "fstatfs(", "fstatvfs("
        ],
        "NSPrivacyAccessedAPICategoryFileTimestamp": [
            ".creationDate", ".modificationDate", "fileModificationDate", "contentModificationDateKey",
            "creationDateKey", "getattrlist", "fgetattrlist", " stat(", "(stat(", "Darwin.stat(",
            "Glibc.stat(", "=stat(", "fstat(", "fstatat(", "lstat("
        ],
        "NSPrivacyAccessedAPICategorySystemBootTime": ["systemUptime", "mach_absolute_time"],
        "NSPrivacyAccessedAPICategoryActiveKeyboards": ["activeInputModes"]
    ]

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repositoryRoot.appendingPathComponent("Apps/KvoiceApp/PrivacyInfo.xcprivacy"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The shipped sources: every package's Sources and the app shell. Tests,
    /// tools and benchmarks never reach the bundle.
    private func shippedSources() throws -> [(name: String, text: String)] {
        let fileManager = FileManager.default
        var roots = [Self.repositoryRoot.appendingPathComponent("Apps/KvoiceApp")]
        let packages = Self.repositoryRoot.appendingPathComponent("Packages")
        for package in try fileManager.contentsOfDirectory(at: packages, includingPropertiesForKeys: nil) {
            let sources = package.appendingPathComponent("Sources")
            if fileManager.fileExists(atPath: sources.path) { roots.append(sources) }
        }
        var files: [(String, String)] = []
        for root in roots {
            let enumerator = try XCTUnwrap(fileManager.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                // KvoiceTestSupport ships in no bundle.
                if url.path.contains("/KvoiceTestSupport/") { continue }
                files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return files
    }

    func testDeclaresNoTrackingAndNoCollectedData() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [Any])?.count, 0)
        XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)
    }

    func testDeclaredCategoriesAreExactlyTheOnesTheSourcesUse() throws {
        let sources = try shippedSources()
        XCTAssertGreaterThan(sources.count, 100, "the scan found the sources")
        var used: Set<String> = []
        for (category, tokens) in Self.categoryTokens {
            // Code only: a doc comment naming an API is not a use.
            let hit = sources.contains { file in
                file.text.split(separator: "\n").contains { line in
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//") else { return false }
                    return tokens.contains { code.contains($0) }
                }
            }
            if hit { used.insert(category) }
        }
        let entries = try XCTUnwrap(try manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let declared = Set(entries.compactMap { $0["NSPrivacyAccessedAPIType"] as? String })
        XCTAssertEqual(declared, used)
    }

    func testReasonsAreTheOnesTheManifestJustifies() throws {
        let entries = try XCTUnwrap(try manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: Set<String>] = [:]
        for entry in entries {
            let type = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            reasons[type] = Set(try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String]))
        }
        // CA92.1: this app's own defaults. E174.1: the download preflight
        // refuses when the volume lacks room. 85F4.1: Speech Models shows
        // the free space.
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryDiskSpace"], ["E174.1", "85F4.1"])
    }
}
