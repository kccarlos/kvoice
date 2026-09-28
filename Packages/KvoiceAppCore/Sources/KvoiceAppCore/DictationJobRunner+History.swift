import Foundation
import KvoiceDomain

/// The history rows one job writes: the ordinary row after insertion, the
/// aborted row at termination (FR-LIFE-009). Same type as
/// `DictationJobRunner.swift`.
extension DictationJobRunner {
    /// FR-LIFE-009: a raw transcript that exists at termination is recorded as
    /// an aborted row when history is enabled; otherwise it is discarded.
    func appendAbortedRowIfNeeded(_ coordinator: isolated Coordinator) async {
        guard let job,
              job.delivery == .insertIntoTarget,
              let rawText = job.rawTranscript,
              historyWriteAllowed(for: job, coordinator),
              let historyRepository = services.historyRepository
        else { return }
        switch state.kind {
        case .transcribing, .processingAI, .inserting:
            break
        default:
            return
        }
        let entry = makeHistoryEntry(
            job: job,
            rawText: rawText,
            finalText: job.finalText ?? rawText,
            outcome: .abortedAtTermination
        )
        try? await historyRepository.append(entry)
    }

    // MARK: - History

    private func historyWriteAllowed(for job: DictationJob, _ coordinator: isolated Coordinator) -> Bool {
        job.historyEnabled && (coordinator.liveHistoryEnabled ?? true)
    }

    private func makeHistoryEntry(
        id: HistoryEntryID = HistoryEntryID(),
        job: DictationJob,
        rawText: String,
        finalText: String,
        outcome: InsertionOutcome,
        recording: AudioRecording? = nil,
        audioPath: String? = nil
    ) -> HistoryEntry {
        let aiStatus: HistoryAIStatus
        switch (job.modeSnapshot, job.fallbackReason) {
        case (.off, _):
            aiStatus = .off
        case (_, nil):
            aiStatus = .succeeded
        case (_, .some(.aiCancelled)):
            aiStatus = .cancelledFallback
        case (_, .some):
            aiStatus = .failed
        }
        let sttMilliseconds = job.transcriptionDuration.map(Self.milliseconds)
        return HistoryEntry(
            id: id,
            // ADR-022 item 7: rows keep recording order whatever order the
            // jobs finish in, so the row is dated at the job's start edge —
            // the moment the user dictated it — not at the write.
            createdAt: job.startedAt,
            rawText: rawText,
            finalText: finalText,
            mode: job.modeSnapshot,
            insertionOutcome: outcome,
            errorCode: job.fallbackReason,
            modelID: job.modelIDSnapshot,
            translationTarget: job.modeSnapshot == .translate
                ? job.translationTargetSnapshot?.bcp47
                : nil,
            sttDurationMilliseconds: sttMilliseconds,
            aiStatus: aiStatus,
            // A role class only (J.5 `target_class`): never a bundle ID or
            // field content.
            targetClass: Self.targetClass(for: job.target, outcome: outcome),
            appVersion: Self.appVersion,
            // History and data: scalars for the dashboard and, when the user
            // opted in, the relative path of the stored WAV. Never samples.
            recordingDurationMilliseconds: recording.map { Self.milliseconds($0.duration) },
            aiDurationMilliseconds: aiStatus == .succeeded ? job.aiDuration.map(Self.milliseconds) : nil,
            audioPath: audioPath
        )
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }

    private static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (version, build) {
        case (let version?, let build?): return "\(version) (\(build))"
        case (let version?, nil): return version
        default: return "development"
        }
    }()

    private static func targetClass(for target: TargetApplicationSnapshot?, outcome: InsertionOutcome) -> String? {
        switch outcome {
        case .copiedToClipboard(.secureTarget):
            return TargetClass.secure.rawValue
        case .deliveredInApp:
            return nil
        default:
            guard let target else { return TargetClass.none.rawValue }
            return target.bundleIdentifier == "com.apple.TextEdit"
                ? TargetClass.textEdit.rawValue
                : TargetClass.other.rawValue
        }
    }

    func appendHistoryIfEnabled(
        outcome: InsertionOutcome,
        recording: AudioRecording?,
        _ coordinator: isolated Coordinator
    ) async {
        guard let historyRepository = services.historyRepository,
              let job,
              job.id == jobID,
              !job.historyRowWritten, // a retried insertion never writes a second row
              historyWriteAllowed(for: job, coordinator),
              let rawText = job.rawTranscript,
              let finalText = job.finalText
        else { return }

        // History and data: opt-in stored audio (decision #1). The file is
        // written before the row so a row never points at a missing file; a
        // failed write just means a row without audio. Off by default, and
        // the job's own settings snapshot decides, so flipping the setting
        // mid-job cannot store audio the user had not agreed to at start.
        let entryID = HistoryEntryID()
        var audioPath: String?
        if let recording,
           let historyAudioStore = coordinator.historyAudioStore,
           settingsSnapshot?.audioStorage.keepRecordings == true {
            audioPath = try? await historyAudioStore.store(recording, for: entryID)
        }

        let entry = makeHistoryEntry(
            id: entryID,
            job: job,
            rawText: rawText,
            finalText: finalText,
            outcome: outcome,
            recording: recording,
            audioPath: audioPath
        )
        do {
            try await historyRepository.append(entry)
            self.job?.markHistoryRowWritten()
            await diagnosticLogger.log(
                DiagnosticEvent(
                    name: .historyWriteCompleted,
                    jobID: jobID,
                    result: .success
                )
            )
            await coordinator.historyAppendObserver?(entry)
        } catch {
            // A row that failed must not leave its audio behind.
            if let audioPath, let historyAudioStore = coordinator.historyAudioStore {
                try? await historyAudioStore.delete(relativePath: audioPath)
            }
            // Insertion already succeeded. History is explicitly best effort
            // and cannot roll back or alter the user's text.
            await diagnosticLogger.log(
                DiagnosticEvent(
                    name: .historyWriteCompleted,
                    jobID: jobID,
                    result: .warning,
                    errorCode: .historyWriteFailed
                )
            )
        }
    }

}
