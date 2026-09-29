import XCTest

/// The signing configuration Developer ID notarization depends on
/// (Docs/Release.md, "Developer ID and notarization"). The built bundle is
/// checked by `Scripts/check_release_signature.sh` in CI; this guards the
/// source of those properties, so a stray xcconfig or entitlements edit
/// fails the pre-commit suite instead of a notarization upload.
final class DistributionSigningConfigTests: XCTestCase {
    /// The repo root, reached from this file because SwiftPM tests have no
    /// app bundle.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KvoiceAppCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // KvoiceAppCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
    }

    /// `KEY = value` assignments of an xcconfig, comments and includes
    /// dropped.
    private func settings(_ name: String) throws -> [String: String] {
        let text = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Config/\(name).xcconfig"),
            encoding: .utf8
        )
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), !line.hasPrefix("#"),
                  let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    func testReleaseEnablesTheHardenedRuntime() throws {
        XCTAssertEqual(try settings("Release")["ENABLE_HARDENED_RUNTIME"], "YES")
    }

    func testReleaseSignsWithASecureTimestamp() throws {
        let flags = try XCTUnwrap(try settings("Release")["OTHER_CODE_SIGN_FLAGS"])
        XCTAssertTrue(
            flags.split(separator: " ").contains("--timestamp"),
            "notarization rejects a signature without a secure timestamp"
        )
    }

    func testReleaseDoesNotInjectGetTaskAllow() throws {
        XCTAssertEqual(
            try settings("Release")["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"], "NO",
            "Xcode injects com.apple.security.get-task-allow otherwise, and notarization rejects it"
        )
    }

    /// Debug keeps the injected debugging entitlement (a debugger attaches)
    /// and signs offline: no timestamp server round trip per build.
    func testDebugKeepsTheDevelopmentDefaults() throws {
        let debug = try settings("Debug")
        XCTAssertNil(debug["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"])
        XCTAssertNil(debug["OTHER_CODE_SIGN_FLAGS"])
    }

    /// Bench includes Release but is never distributed: it puts both back so
    /// Instruments can attach and it signs offline.
    func testBenchRestoresTheDevelopmentDefaults() throws {
        let bench = try settings("Bench")
        XCTAssertEqual(bench["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"], "YES")
        XCTAssertEqual(bench["OTHER_CODE_SIGN_FLAGS"], "")
    }

    /// Audio input is the only entitlement the unsandboxed app needs under
    /// the hardened runtime: network, Foundation Models, SpeechAnalyzer and
    /// SMAppService need none outside the App Sandbox, and ADR-009 keeps
    /// the app unsandboxed because Accessibility insertion into other apps
    /// cannot be sandboxed.
    func testEntitlementsAreExactlyAudioInput() throws {
        let data = try Data(contentsOf: Self.repositoryRoot.appendingPathComponent("Apps/KvoiceApp/Kvoice.entitlements"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(Set(plist.keys), ["com.apple.security.device.audio-input"])
        XCTAssertEqual(plist["com.apple.security.device.audio-input"] as? Bool, true)
    }

    // MARK: The Mac App Store edition (ADR-026)

    private func plist(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repositoryRoot.appendingPathComponent(relativePath))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    /// AppStore is Release plus the sandbox: the same optimisation, the
    /// hardened runtime and no get-task-allow, the edition value, and no
    /// secure timestamp (the store re-signs; a local sandbox build signs
    /// offline).
    func testAppStoreIsReleasePlusTheSandbox() throws {
        let text = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Config/AppStore.xcconfig"),
            encoding: .utf8
        )
        XCTAssertTrue(text.hasPrefix("#include \"Release.xcconfig\""))
        let appStore = try settings("AppStore")
        XCTAssertEqual(appStore["KVOICE_DISTRIBUTION_EDITION"], "appStore")
        XCTAssertEqual(appStore["ENABLE_APP_SANDBOX"], "YES")
        XCTAssertEqual(appStore["OTHER_CODE_SIGN_FLAGS"], "")
        XCTAssertNil(appStore["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"], "inherits NO from Release")
    }

    /// A manually signed App Store archive gets its profile through the
    /// xcconfig, which reaches the app target only; no other configuration
    /// names a profile (the SwiftPM resource bundles cannot take one).
    func testOnlyTheAppStoreConfigurationNamesAProvisioningProfile() throws {
        XCTAssertEqual(
            try settings("AppStore")["PROVISIONING_PROFILE_SPECIFIER"],
            "$(KVOICE_APP_STORE_PROFILE_SPECIFIER)"
        )
        for name in ["Base", "Debug", "Release", "TestHost", "Bench"] {
            XCTAssertNil(try settings(name)["PROVISIONING_PROFILE_SPECIFIER"], name)
        }
        let archive = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Scripts/archive_app_store.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(archive.contains("KVOICE_APP_STORE_PROFILE_SPECIFIER=\"$profile_name\""))
        XCTAssertFalse(archive.contains("PROVISIONING_PROFILE_SPECIFIER="), "never on the command line")
        XCTAssertTrue(archive.contains("Mac Installer Distribution"))
        XCTAssertTrue(archive.contains("--upload-package"))
    }

    /// No build script or configuration file carries an Apple team ID: the
    /// scripts read APPLE_TEAM_ID (the public repo's Actions variable), so a
    /// fork builds and signs with its own team.
    func testNoTeamIDIsCommittedInTheBuildScriptsOrConfiguration() throws {
        // A team ID is ten uppercase letters and digits, with at least one of
        // each; the placeholder and the variable names do not match.
        let teamShaped = try NSRegularExpression(
            pattern: #"\b(?=[A-Z0-9]*[0-9])(?=[A-Z0-9]*[A-Z])[A-Z0-9]{10}\b"#
        )
        var files: [URL] = []
        for directory in ["Scripts", "Config"] {
            let url = Self.repositoryRoot.appendingPathComponent(directory)
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path)
            where name.hasSuffix(".sh") || name.hasSuffix(".xcconfig") || name.hasSuffix(".plist") {
                files.append(url.appendingPathComponent(name))
            }
        }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let hits = teamShaped.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            XCTAssertEqual(hits, [], file.lastPathComponent)
        }
        for script in ["archive_app_store.sh", "build_app.sh"] {
            let text = try String(
                contentsOf: Self.repositoryRoot.appendingPathComponent("Scripts/\(script)"),
                encoding: .utf8
            )
            XCTAssertTrue(text.contains("APPLE_TEAM_ID"), script)
        }
    }

    /// Every other configuration is the Developer ID edition.
    func testBaseDeclaresTheDeveloperIDEdition() throws {
        XCTAssertEqual(try settings("Base")["KVOICE_DISTRIBUTION_EDITION"], "developerID")
        for name in ["Debug", "Release", "TestHost", "Bench"] {
            XCTAssertNil(try settings(name)["KVOICE_DISTRIBUTION_EDITION"], name)
            XCTAssertNil(try settings(name)["ENABLE_APP_SANDBOX"], name)
        }
    }

    /// The five entitlements ADR-026 justifies, each true, and nothing else:
    /// no temporary exceptions, no Apple Events, no restricted entitlement
    /// that would need a provisioning profile for a local build.
    func testAppStoreEntitlementsAreTheSandboxAndTheFiveJustifiedKeys() throws {
        let entitlements = try plist("Apps/KvoiceApp/Kvoice-AppStore.entitlements")
        XCTAssertEqual(Set(entitlements.keys), [
            "com.apple.security.app-sandbox",
            "com.apple.security.device.audio-input",
            "com.apple.security.network.client",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.files.bookmarks.app-scope"
        ])
        for (key, value) in entitlements {
            XCTAssertEqual(value as? Bool, true, key)
        }
    }

    // MARK: Private Cloud Compute (ADR-027)

    private static let privateCloudComputeKey = "com.apple.developer.private-cloud-compute"

    /// The archive-only file is the App Store set plus exactly the managed
    /// Private Cloud Compute entitlement.
    func testThePrivateCloudComputeEntitlementsAreTheAppStoreSetPlusOneKey() throws {
        let appStore = try plist("Apps/KvoiceApp/Kvoice-AppStore.entitlements")
        let pcc = try plist("Apps/KvoiceApp/Kvoice-AppStore-PCC.entitlements")
        XCTAssertEqual(Set(pcc.keys), Set(appStore.keys).union([Self.privateCloudComputeKey]))
        for (key, value) in pcc {
            XCTAssertEqual(value as? Bool, true, key)
        }
    }

    /// Neither file a local or Developer ID build signs with carries the
    /// managed key: a local build has no provisioning profile to grant it,
    /// and the Developer ID edition is not eligible.
    func testNoLocalOrDeveloperIDBuildCarriesThePrivateCloudComputeKey() throws {
        XCTAssertNil(try plist("Apps/KvoiceApp/Kvoice.entitlements")[Self.privateCloudComputeKey])
        XCTAssertNil(try plist("Apps/KvoiceApp/Kvoice-AppStore.entitlements")[Self.privateCloudComputeKey])
        let project = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Kvoice.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertFalse(project.contains("Kvoice-AppStore-PCC.entitlements"), "no configuration signs with it by default")
    }

    /// Only the archive script selects the file, behind its opt-in flag; the
    /// signature checks know the key on both sides.
    func testTheArchiveScriptOptsInAndTheChecksKnowTheKey() throws {
        func script(_ name: String) throws -> String {
            try String(contentsOf: Self.repositoryRoot.appendingPathComponent("Scripts/\(name)"), encoding: .utf8)
        }
        let archive = try script("archive_app_store.sh")
        XCTAssertTrue(archive.contains("KVOICE_PCC_ENTITLEMENT"))
        XCTAssertTrue(archive.contains("CODE_SIGN_ENTITLEMENTS=Apps/KvoiceApp/Kvoice-AppStore-PCC.entitlements"))
        let build = try script("build_app.sh")
        XCTAssertFalse(build.contains("Kvoice-AppStore-PCC.entitlements"), "a local build never signs with the managed key")
        let storeCheck = try script("check_app_store_signature.sh")
        XCTAssertTrue(storeCheck.contains("--pcc"))
        XCTAssertTrue(storeCheck.contains(Self.privateCloudComputeKey))
        XCTAssertTrue(storeCheck.contains("embedded.provisionprofile"))
        XCTAssertTrue(try script("check_release_signature.sh").contains(Self.privateCloudComputeKey))
    }

    /// The project wires the AppStore configuration to its xcconfig and its
    /// entitlements file, and only that configuration to that file.
    func testProjectWiresTheAppStoreConfiguration() throws {
        let project = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Kvoice.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertTrue(project.contains("baseConfigurationReference = A20000010000000000000060 /* AppStore.xcconfig */;"))
        XCTAssertEqual(
            project.components(separatedBy: "CODE_SIGN_ENTITLEMENTS = \"Apps/KvoiceApp/Kvoice-AppStore.entitlements\";").count - 1, 1,
            "exactly one configuration signs with the sandbox entitlements"
        )
        XCTAssertEqual(project.components(separatedBy: "name = AppStore;").count - 1, 2, "target and project configuration")
        XCTAssertTrue(project.contains("PrivacyInfo.xcprivacy in Resources"))
    }

    /// Info.plist carries the edition from the build setting, and the store
    /// metadata both editions ship with.
    func testInfoPlistCarriesTheEditionAndTheStoreMetadata() throws {
        let info = try plist("Apps/KvoiceApp/Info.plist")
        XCTAssertEqual(info["KvoiceDistributionEdition"] as? String, "$(KVOICE_DISTRIBUTION_EDITION)")
        // Without it Gatekeeper (spctl) rejects the notarized bundle as
        // "valid but does not seem to be an app", and App Store validation fails.
        XCTAssertEqual(info["CFBundlePackageType"] as? String, "APPL")
        // App Store Connect refuses a package whose app lacks these
        // ("Bad Bundle Executable", 90259), although macOS runs it.
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "$(EXECUTABLE_NAME)")
        XCTAssertEqual(info["CFBundleName"] as? String, "$(PRODUCT_NAME)")
        XCTAssertEqual(info["CFBundleInfoDictionaryVersion"] as? String, "6.0")
        XCTAssertEqual(info["LSApplicationCategoryType"] as? String, "public.app-category.productivity")
        XCTAssertEqual(info["ITSAppUsesNonExemptEncryption"] as? Bool, false)
    }

    /// The template the archive script fills: an App Store Connect export
    /// with automatic signing and the team as a placeholder.
    func testExportOptionsTemplate() throws {
        let options = try plist("Config/ExportOptions-AppStore.plist")
        XCTAssertEqual(options["method"] as? String, "app-store-connect")
        XCTAssertEqual(options["signingStyle"] as? String, "automatic")
        XCTAssertEqual(options["destination"] as? String, "export", "the script never uploads")
        XCTAssertEqual(options["teamID"] as? String, "__TEAM_ID__")
    }
}
