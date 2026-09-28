import Foundation

/// Stored audio for history rows (opt-in; `AudioStorageSettings`).
///
/// Files are keyed by history entry ID and addressed by a relative path the
/// row carries (`HistoryEntry.audioPath`), so moving the History folder does
/// not orphan them.  Implementations write mode-0600 files and never hand
/// samples to diagnostics.
public protocol HistoryAudioStoring: Actor {
    /// Writes `recording` for `entryID` and returns the relative path to store
    /// in the row.  Overwrites a previous file for the same entry.
    func store(_ recording: AudioRecording, for entryID: HistoryEntryID) throws -> String
    /// Absolute location of a stored file.  Purely path arithmetic; the file
    /// may not exist.
    nonisolated func fileURL(forRelativePath path: String) -> URL
    /// Whether the file behind a relative path exists.
    func exists(relativePath path: String) -> Bool
    /// Removes one file.  A missing file is not an error.
    func delete(relativePath path: String) throws
    /// Removes every stored file (Clear All).
    func deleteAll() throws
    /// Bytes on disk across every stored file.
    func totalSizeBytes() throws -> Int64
}
