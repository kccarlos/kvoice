import Foundation
import KvoiceDomain

/// Opt-in stored recordings for history rows (decision #1; an accepted
/// deviation from FR-HIST-003 / FR-AUD-003).
///
/// Files live under `History/Audio/<entryID>.wav` next to the database, as
/// 16-bit PCM WAV at the recording's own rate (16 kHz mono at the
/// transcription boundary), mode `0600`, written to a temporary name and
/// renamed so a crash never leaves a half-written file behind.  Rows store
/// the path *relative to the History folder* (`Audio/<id>.wav`).
///
/// Nothing here is called unless `AudioStorageSettings.keepRecordings` is on;
/// the controller decides, this actor only writes what it is handed.  Samples
/// are never logged.
public actor HistoryAudioFileStore: HistoryAudioStoring {
    public static let audioDirectoryName = "Audio"
    public static let fileExtension = "wav"

    /// The History folder the relative paths are resolved against.
    public nonisolated let historyDirectoryURL: URL
    public nonisolated var audioDirectoryURL: URL {
        historyDirectoryURL.appendingPathComponent(Self.audioDirectoryName, isDirectory: true)
    }

    private let fileManager: HistoryAudioFileManager

    /// `historyDirectoryURL` defaults to the folder that holds
    /// `history.sqlite3`.
    public init(historyDirectoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.historyDirectoryURL = historyDirectoryURL
            ?? HistorySQLiteStore.defaultFileURL(fileManager: fileManager).deletingLastPathComponent()
        self.fileManager = HistoryAudioFileManager(fileManager)
    }

    public static func relativePath(for entryID: HistoryEntryID) -> String {
        "\(audioDirectoryName)/\(entryID.uuidString).\(fileExtension)"
    }

    public func store(_ recording: AudioRecording, for entryID: HistoryEntryID) throws -> String {
        let relativePath = Self.relativePath(for: entryID)
        let destination = fileURL(forRelativePath: relativePath)
        let directory = destination.deletingLastPathComponent()
        try fileManager.value.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let data = Self.wavData(for: recording)
        let temporary = directory.appendingPathComponent(".\(entryID.uuidString).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [.atomic])
            try fileManager.value.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if fileManager.value.fileExists(atPath: destination.path) {
                _ = try fileManager.value.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.value.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.value.removeItem(at: temporary)
            throw KVoiceError(code: .historyWriteFailed)
        }
        // `replaceItemAt` can carry the destination's old mode; assert ours.
        try? fileManager.value.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return relativePath
    }

    public nonisolated func fileURL(forRelativePath path: String) -> URL {
        historyDirectoryURL.appendingPathComponent(path, isDirectory: false)
    }

    public func exists(relativePath path: String) -> Bool {
        fileManager.value.fileExists(atPath: fileURL(forRelativePath: path).path)
    }

    public func delete(relativePath path: String) throws {
        let url = fileURL(forRelativePath: path)
        // Only ever remove what lives inside our own folder, whatever the row says.
        guard url.standardizedFileURL.path.hasPrefix(audioDirectoryURL.standardizedFileURL.path + "/") else { return }
        guard fileManager.value.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.value.removeItem(at: url)
        } catch {
            throw KVoiceError(code: .historyWriteFailed)
        }
    }

    public func deleteAll() throws {
        guard fileManager.value.fileExists(atPath: audioDirectoryURL.path) else { return }
        do {
            try fileManager.value.removeItem(at: audioDirectoryURL)
        } catch {
            throw KVoiceError(code: .historyWriteFailed)
        }
    }

    public func totalSizeBytes() throws -> Int64 {
        guard let names = try? fileManager.value.contentsOfDirectory(atPath: audioDirectoryURL.path) else { return 0 }
        var total: Int64 = 0
        for name in names where name.hasSuffix(".\(Self.fileExtension)") {
            let path = audioDirectoryURL.appendingPathComponent(name).path
            if let size = (try? fileManager.value.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    // MARK: WAV encoding

    /// RIFF/WAVE, PCM 16-bit little-endian, `channelCount` channels
    /// interleaved as the recording presents them (mono at the boundary).
    static func wavData(for recording: AudioRecording) -> Data {
        let channels = UInt16(max(1, recording.channelCount))
        let sampleRate = UInt32(recording.sampleRate.rounded())
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(recording.samples.count * Int(bitsPerSample / 8))

        var data = Data(capacity: 44 + Int(dataSize))
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1)) // PCM
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(dataSize)

        var pcm = [Int16](repeating: 0, count: recording.samples.count)
        for (index, sample) in recording.samples.enumerated() {
            let clamped = max(-1, min(1, sample))
            pcm[index] = Int16((clamped * Float(Int16.max)).rounded()).littleEndian
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

/// `FileManager` predates strict sendability; the actor serializes every use.
private final class HistoryAudioFileManager: @unchecked Sendable {
    let value: FileManager

    init(_ value: FileManager) {
        self.value = value
    }
}
