import Foundation
import KvoiceDomain

/// Appends diagnostic events to a JSON-lines file.
///
/// This exists because OSLog is not always readable: on the development machine
/// the local log store is corrupt (`log show` fails with "The log archive is
/// corrupt or incomplete"), which made insertion outcomes impossible to inspect
/// even after they were being emitted. A plain file needs no log store and can
/// be read with `tail`.
///
/// Only the scalar `DiagnosticEvent` envelope is written; transcripts, audio,
/// and secrets cannot reach this API by construction.
public actor FileDiagnosticLogger: DiagnosticLogging {
    /// Truncates rather than growing without bound. Diagnostics are for the
    /// recent past, so keeping the newest events is enough.
    public static let defaultMaximumBytes = 512 * 1024

    private let fileURL: URL
    private let maximumBytes: Int
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    public init(
        fileURL: URL? = nil,
        maximumBytes: Int = FileDiagnosticLogger.defaultMaximumBytes,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.maximumBytes = maximumBytes
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return applicationSupport
            .appendingPathComponent("kvoice", isDirectory: true)
            .appendingPathComponent("diagnostics.jsonl", isDirectory: false)
    }

    /// The path currently being written, for support instructions.
    public var path: String {
        fileURL.path
    }

    public func log(_ event: DiagnosticEvent) async {
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A) // newline

        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if !fileManager.fileExists(atPath: fileURL.path) {
                try line.write(to: fileURL, options: .atomic)
                return
            }

            try rotateIfNeeded()

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Diagnostics must never break the feature they observe.
        }
    }

    private func rotateIfNeeded() throws {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? Int, size > maximumBytes else { return }

        // Keep the newest half so a long session still has recent context.
        let existing = try Data(contentsOf: fileURL)
        let keep = existing.suffix(maximumBytes / 2)
        // Start at a line boundary so the file stays valid JSON lines.
        let trimmed: Data
        if let newlineIndex = keep.firstIndex(of: 0x0A) {
            trimmed = Data(keep[keep.index(after: newlineIndex)...])
        } else {
            trimmed = Data()
        }
        try trimmed.write(to: fileURL, options: .atomic)
    }
}

/// Fans one event out to several sinks, so file diagnostics can be added
/// without giving up OSLog where it works.
public struct CompositeDiagnosticLogger: DiagnosticLogging {
    private let sinks: [any DiagnosticLogging]

    public init(_ sinks: [any DiagnosticLogging]) {
        self.sinks = sinks
    }

    public func log(_ event: DiagnosticEvent) async {
        for sink in sinks {
            await sink.log(event)
        }
    }
}
