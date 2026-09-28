import Foundation
import XCTest
@testable import KvoiceDomain
@testable import KvoicePersistence

final class SecretsFileStoreTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvoice-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    func testRoundTripUsesStableShapeAndOwnerOnlyPermissions() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SecretsFileStore(directoryURL: directory)
        let settings = SecretSettings(apiKey: "fixture-secret")

        try await store.save(settings)
        let loaded = try await store.load()
        let data = try Data(contentsOf: directory.appendingPathComponent("secrets.json"))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("secrets.json").path
        )
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"openAICompatibleAPIKey":"fixture-secret","schemaVersion":1}"#
        )
    }

    func testMissingFileReturnsEmptySecretsWithoutCreatingIt() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("secrets.json")
        let store = SecretsFileStore(fileURL: fileURL)

        let loaded = try await store.load()

        XCTAssertEqual(loaded, SecretSettings())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testGroupReadableFileFailsClosedWithoutReturningKey() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("secrets.json")
        try Data(#"{"openAICompatibleAPIKey":"fixture-secret","schemaVersion":1}"#.utf8)
            .write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fileURL.path
        )
        let store = SecretsFileStore(fileURL: fileURL)

        do {
            _ = try await store.load()
            XCTFail("expected insecure permissions to fail closed")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .secretsFileInsecure)
            XCTAssertFalse(String(describing: error).contains("fixture-secret"))
        }
    }

    func testUnknownOrFutureSecretSchemaFailsWithoutLeakingCredential() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("secrets.json")
        try Data(#"{"openAICompatibleAPIKey":"fixture-secret","schemaVersion":99}"#.utf8)
            .write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        let store = SecretsFileStore(fileURL: fileURL)

        do {
            _ = try await store.load()
            XCTFail("expected future schema to fail")
        } catch let error as KVoiceError {
            XCTAssertEqual(error.code, .settingsCorrupt)
            XCTAssertFalse(String(describing: error).contains("fixture-secret"))
        }
    }

    func testReplacementLeavesOneCompleteSnapshot() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SecretsFileStore(directoryURL: directory)
        try await store.save(SecretSettings(apiKey: "old-secret"))
        try await store.save(SecretSettings(apiKey: "new-secret"))

        let loaded = try await store.load()
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(loaded.apiKey, "new-secret")
        XCTAssertEqual(entries.map(\.lastPathComponent), ["secrets.json"])
    }
}
