import AppKit
import KvoiceAppCore
import KvoiceDomain
import KvoicePersistence
import KvoiceUI

/// History and data (the history workstream): opt-in stored audio, Auto
/// Daily Export, age-based cleanup, "Transcribe File…", and the Data &
/// Privacy controls that drive them.
///
/// The services live on `AppComposition` (`historyAudioStore`,
/// `autoDailyExporter`, `historyMaintenance`); this file only connects them
/// to the controller, the History view model, and the settings load. Every
/// seam it fills has a default no-op in its owner, so removing a line here
/// degrades a feature rather than breaking a build.
extension AppDelegate {
    /// Called once from `applicationDidFinishLaunching`, before settings load.
    func installHistoryHooks() {
        let composition = composition
        let exporter = composition.autoDailyExporter
        let engine = composition.transcriptionEngine

        // The controller writes the WAV (when the job's settings snapshot
        // says so) and tells the exporter about every committed row. The
        // observer is awaited inside the job's pipeline task, so the export
        // — which may touch a slow volume — runs detached from it.
        Task {
            await composition.dictationController.setHistoryAudioStore(composition.historyAudioStore)
            await composition.dictationController.setHistoryAppendObserver { entry in
                Task(priority: .utility) { await exporter.append(entry) }
            }
        }

        // The History section: playback and Show in Finder need the store;
        // Retranscribe and Transcribe File need the resident engine; a file
        // row is exported like a dictation. The engine stays behind the
        // domain protocol — KvoiceUI never sees WhisperKit.
        historyViewModel.audioStore = composition.historyAudioStore
        // ADR-018: a transcribed file gets the dictionary too, read at call
        // time so it is the list as it stands when the file is dropped.
        let transcribe = HistoryFileTranscription.transcriber(engine: engine) { [weak self] in
            await MainActor.run { self.map { DictionaryPrompt.render($0.currentSettings.dictionary) } ?? nil }
        }
        // One model, one inference at a time: the engine throws
        // `inferenceInProgress` if a dictation owns it, which would surface
        // as a failed dictation. Refuse up front instead; `receiveShortcut`
        // refuses the other direction while a file is being transcribed.
        // ADR-022 item 3: "Transcribe File while a job or test runs" is the
        // projection's `.transcribeFile` row (the job half). ADR-022 item 5:
        // the file transcription is then the library's `.transcribingFile`
        // activity for its duration — begun under the transition table, so
        // the test, a reload, an unload or a model operation that races
        // this call is refused by the library rather than by a flag; the
        // view model's own `isTranscribingFile` only guards a second drop.
        let whenIdle: @Sendable (URL) async throws -> FileTranscription = { [weak self] url in
            guard let self else { throw KVoiceError(code: .appCancelled) }
            guard let library = await self.composition.modelManager else {
                throw KVoiceError(code: .modelNotInstalled)
            }
            guard await self.settingAvailability(.transcribeFile).isEnabled else {
                throw KVoiceError(code: .appBusy)
            }
            do {
                try await library.beginActivity(.transcribingFile)
            } catch is ModelActivityRefusal {
                throw KVoiceError(code: .appBusy)
            }
            do {
                let result = try await transcribe(url)
                await library.endActivity()
                return result
            } catch {
                await library.endActivity()
                throw error
            }
        }
        historyViewModel.fileTranscriber = whenIdle
        historyViewModel.retranscriber = { url in try await whenIdle(url).text }
        historyViewModel.onEntryAppended = { entry in
            await exporter.append(entry)
        }
    }

    /// True while "Transcribe File…" holds the resident engine — the
    /// library's `.transcribingFile` activity (ADR-022 item 5).
    var isTranscribingFile: Bool {
        modelActivity == .transcribingFile
    }

    /// Runs the retention pass now and then daily. Called once settings are
    /// loaded, so the first pass sees the user's retention rather than the
    /// defaults; a second call is a no-op.
    func startHistoryMaintenance() {
        Task { [weak self] in
            guard let self, !self.terminationInProgress else { return }
            await self.composition.historyMaintenance.start()
        }
    }

    /// "Run Transcript Cleanup Now": a forced pass, reported as counts.
    func runHistoryCleanupNow() async -> DataPrivacyCleanupOutcome? {
        let report = await composition.historyMaintenance.runOnce(force: true)
        return DataPrivacyCleanupOutcome(
            deletedEntries: report.deletedEntryCount,
            deletedAudioFiles: report.deletedAudioFileCount,
            hadErrors: report.hadErrors
        )
    }

    /// Row count, database size, and stored-audio size for the section.
    func historyStorageMetrics() async -> DataPrivacyMetrics? {
        let store = composition.historyStore
        guard let count = try? await store.count(),
              let bytes = try? await store.storageSizeBytes() else { return nil }
        let audio = (try? await composition.historyAudioStore.totalSizeBytes()) ?? 0
        return DataPrivacyMetrics(entryCount: count, databaseBytes: bytes, audioBytes: audio)
    }

    // MARK: Transcribe File (Open With / Dock drop)

    /// `CFBundleDocumentTypes` in Info.plist lists the media types, so a file
    /// dropped on the Dock icon or opened with kvoice lands here. Files are
    /// transcribed one at a time through the same path as the History
    /// toolbar button; nothing is inserted anywhere.
    func application(_: NSApplication, open urls: [URL]) {
        guard !terminationInProgress else { return }
        let supported = urls.filter {
            MediaFileDecoder.supportedExtensions.contains($0.pathExtension.lowercased())
        }
        guard !supported.isEmpty else {
            NSSound.beep()
            return
        }
        openMainWindow(section: .history)
        Task { [weak self] in
            for url in supported {
                guard let self, !self.terminationInProgress else { return }
                await self.historyViewModel.transcribeFile(at: url)
            }
        }
    }
}
