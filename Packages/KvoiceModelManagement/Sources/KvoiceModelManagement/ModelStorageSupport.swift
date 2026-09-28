import Foundation
import KvoiceDomain

// MARK: - Free-space gate (FR-MODEL-006, NFR-DISK-002)

/// Reports how many bytes the volume holding a directory can still accept.
///
/// Injected so tests can simulate an insufficient-space condition without a
/// full disk. The production implementation asks the file system for the
/// "important usage" capacity, which is what Finder reports as free.
public protocol ModelVolumeCapacityProviding: Sendable {
    /// `nil` means the capacity could not be determined; the caller decides
    /// whether to fail open or closed.
    func availableCapacity(forVolumeContaining url: URL) -> Int64?
}

public struct FileManagerVolumeCapacityProvider: ModelVolumeCapacityProviding {
    public init() {}

    public func availableCapacity(forVolumeContaining url: URL) -> Int64? {
        // The directory may not exist yet on a first install; walk up to the
        // nearest existing ancestor so the query lands on a real volume.
        var cursor = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: cursor.path) {
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { return nil }
            cursor = parent
        }
        let values = try? cursor.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// A fixed answer, for tests and previews.
public struct FixedVolumeCapacityProvider: ModelVolumeCapacityProviding {
    public let availableBytes: Int64?

    public init(availableBytes: Int64?) {
        self.availableBytes = availableBytes
    }

    public func availableCapacity(forVolumeContaining url: URL) -> Int64? {
        availableBytes
    }
}

/// What a managed installation needs versus what the storage volume offers.
///
/// `requiredBytes` is `remainingDownloadBytes + workingSpaceBytes` (spec C.3
/// step 3). `availableBytes` is `nil` when the volume could not be queried.
public struct ModelInstallationSpaceEstimate: Sendable, Equatable {
    public let remainingDownloadBytes: Int64
    public let workingSpaceBytes: Int64
    public let requiredBytes: Int64
    public let availableBytes: Int64?

    public init(
        remainingDownloadBytes: Int64,
        workingSpaceBytes: Int64,
        availableBytes: Int64?
    ) {
        self.remainingDownloadBytes = max(0, remainingDownloadBytes)
        self.workingSpaceBytes = max(0, workingSpaceBytes)
        let (sum, overflow) = self.remainingDownloadBytes.addingReportingOverflow(self.workingSpaceBytes)
        self.requiredBytes = overflow ? Int64.max : sum
        self.availableBytes = availableBytes
    }

    /// `true` when the volume is known to lack space. An unknown capacity is
    /// not treated as insufficient; the download proceeds and any ENOSPC
    /// surfaces as an ordinary download failure.
    public var isInsufficient: Bool {
        guard let availableBytes else { return false }
        return availableBytes < requiredBytes
    }

    public var formattedRequired: String { Self.format(requiredBytes) }

    public var formattedAvailable: String? { availableBytes.map(Self.format) }

    public static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    static func insufficientSpaceMessage(requiredBytes: Int64, availableBytes: Int64) -> String {
        "Not enough free disk space to install the model. About "
            + format(requiredBytes)
            + " is required (download plus working space) but only "
            + format(availableBytes)
            + " is available on the model volume."
    }
}

// MARK: - Persisted download state (FR-MODEL-016, C.3 steps 7-8)

/// Written into a staging directory as `download-state.json` so an interrupted
/// download survives quit, crash, or cancel and can be resumed on a later
/// launch. It carries only byte counts, indexes, and opaque URLSession resume
/// data — never a URL with credentials.
struct ModelDownloadStateRecord: Codable, Sendable, Equatable {
    static let fileName = "download-state.json"
    static let currentSchemaVersion = 1

    var schemaVersion: Int = ModelDownloadStateRecord.currentSchemaVersion
    var installationID: UUID
    var manifestSHA256: String
    var nextFileIndex: Int
    var completedBytes: Int64
    var resumeData: Data?
    var updatedAt: Date
}

// MARK: - Clock

/// Injected so stale-staging tests can pin "now".
public typealias ModelClock = @Sendable () -> Date
