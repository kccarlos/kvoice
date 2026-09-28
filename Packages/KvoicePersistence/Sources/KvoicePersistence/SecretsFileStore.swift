import Foundation
import KvoiceDomain

/// Owner-only, app-support storage for the optional AI API key.
///
/// The store never logs or includes the key in an error. Every mutation writes
/// a complete temporary snapshot in the same directory and atomically replaces
/// the destination, so readers see either the old JSON or the new JSON.
public actor SecretsFileStore: SecretsRepository {
    public static let fileName = "secrets.json"

    public let fileURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        decoder = JSONDecoder()
    }

    public init(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) {
        self.init(
            fileURL: directoryURL.appendingPathComponent(Self.fileName, isDirectory: false),
            fileManager: fileManager
        )
    }

    public init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.init(
            directoryURL: applicationSupport.appendingPathComponent("kvoice", isDirectory: true),
            fileManager: fileManager
        )
    }

    public func load() throws -> SecretSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return SecretSettings()
        }
        try verifyOwnerOnlyFile()

        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            return try decoder.decode(SecretSettings.self, from: data)
        } catch let error as KVoiceError {
            throw error
        } catch {
            throw KVoiceError(code: .settingsCorrupt, retryable: false)
        }
    }

    public func save(_ settings: SecretSettings) throws {
        guard settings.schemaVersion == SecretSettings.currentSchemaVersion else {
            throw KVoiceError(code: .settingsCorrupt, retryable: false)
        }

        let data: Data
        do {
            data = try encoder.encode(settings)
            let decoded = try decoder.decode(SecretSettings.self, from: data)
            guard decoded == settings else {
                throw KVoiceError(code: .settingsCorrupt, retryable: false)
            }
        } catch let error as KVoiceError {
            throw error
        } catch {
            throw KVoiceError(code: .settingsCorrupt, retryable: false)
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Do not follow a pre-existing symlink at the final path. A user
            // or another process must not redirect credentials elsewhere.
            if fileManager.fileExists(atPath: fileURL.path) {
                try verifyRegularFile()
            }

            let temporaryURL = directory.appendingPathComponent(
                ".\(Self.fileName).\(UUID().uuidString).tmp",
                isDirectory: false
            )
            defer { try? fileManager.removeItem(at: temporaryURL) }

            guard fileManager.createFile(
                atPath: temporaryURL.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw KVoiceError(code: .settingsCorrupt, retryable: false)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )

            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
            // Keep the postcondition explicit even on file systems that copy
            // metadata during replacement.
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch let error as KVoiceError {
            throw error
        } catch {
            throw KVoiceError(code: .settingsCorrupt, retryable: false)
        }
    }

    private func verifyOwnerOnlyFile() throws {
        try verifyRegularFile()

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        } catch {
            throw KVoiceError(code: .secretsFileInsecure, retryable: false)
        }

        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == 0o600 else {
            throw KVoiceError(code: .secretsFileInsecure, retryable: false)
        }
    }

    private func verifyRegularFile() throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        } catch {
            throw KVoiceError(code: .secretsFileInsecure, retryable: false)
        }

        if let type = attributes[.type] as? FileAttributeType,
           type != .typeRegular {
            throw KVoiceError(code: .secretsFileInsecure, retryable: false)
        }
    }
}
