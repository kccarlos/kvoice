import Foundation
import KvoiceDomain

/// What "Transcribe File…" and Retranscribe get back from the engine hook:
/// the text plus the scalars the history row records.
public struct FileTranscription: Sendable, Equatable {
    public let text: String
    public let modelID: ModelID
    public let sttDurationMilliseconds: Int?
    public let recordingDurationMilliseconds: Int?

    public init(
        text: String,
        modelID: ModelID,
        sttDurationMilliseconds: Int? = nil,
        recordingDurationMilliseconds: Int? = nil
    ) {
        self.text = text
        self.modelID = modelID
        self.sttDurationMilliseconds = sttDurationMilliseconds
        self.recordingDurationMilliseconds = recordingDurationMilliseconds
    }
}

/// Bridges a media file to the current `TranscriptionEngine`: decode to
/// 16 kHz mono, run the engine, return the row scalars.
///
/// The shell wires the result into `HistoryViewModel.fileTranscriber` (and
/// `retranscriber` via `.text`) with the engine it already owns; the view
/// model never sees the engine.
public enum HistoryFileTranscription {
    /// `initialPrompt` is read per call so a file transcribed after the
    /// dictionary changed sees the current list (ADR-018: every path sends
    /// the dictionary). Default: no prompt.
    public static func transcriber(
        engine: any TranscriptionEngine,
        initialPrompt: @escaping @Sendable () async -> String? = { nil }
    ) -> @Sendable (URL) async throws -> FileTranscription {
        { url in
            let recording = try await MediaFileDecoder.decode(url)
            return try await transcribe(recording, with: engine, initialPrompt: await initialPrompt())
        }
    }

    public static func transcribe(
        _ recording: AudioRecording,
        with engine: any TranscriptionEngine,
        initialPrompt: String? = nil
    ) async throws -> FileTranscription {
        let request = TranscriptionRequest(
            jobID: JobID(),
            audio: recording,
            task: .transcribe,
            initialPrompt: initialPrompt
        )
        let result = try await engine.transcribe(request) { _ in }
        let elapsed = result.timings.inferenceEnd - result.timings.requestStart
        return FileTranscription(
            text: result.text,
            modelID: result.modelID,
            sttDurationMilliseconds: milliseconds(elapsed),
            recordingDurationMilliseconds: milliseconds(recording.duration)
        )
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
