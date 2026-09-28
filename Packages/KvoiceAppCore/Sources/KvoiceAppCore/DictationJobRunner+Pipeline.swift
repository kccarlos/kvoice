import Foundation
import KvoiceDomain

/// The transcribe → AI → insert pipeline of one job (ADR-022 slice 6).
/// Same type as `DictationJobRunner.swift`; split by phase so each file
/// stays readable. Every suspending method takes the coordinator as an
/// `isolated` parameter, as the main file explains.
extension DictationJobRunner {
    // MARK: - Pipeline: transcribe → AI → insert

    func launchTranscription(recording: AudioRecording, _ coordinator: isolated Coordinator) {
        guard pipelineTask == nil || pipelineTask?.isCancelled == true else { return }
        // The strong capture of `coordinator` is what isolates this closure
        // to the coordinator actor (see the type's doc comment).
        let task = Task {
            await self.runTranscriptionAndInsertion(recording: recording, coordinator)
        }
        pipelineTask = task
    }

    private func runTranscriptionAndInsertion(
        recording: AudioRecording,
        _ coordinator: isolated Coordinator
    ) async {
        defer {
            pipelineTask = nil
        }
        guard isCurrent(.transcribing) else { return }
        guard let transcriptionEngine = services.transcriptionEngine else {
            _ = try? await apply(.transcriptionFailure(jobID: jobID, code: .sttFailed), coordinator)
            return
        }

        // ADR-022 item 7: one engine, one pass at a time, in job order. With
        // a single job the turn is granted at once; an overlapped job waits
        // here, still `.transcribing`, until the older pass has returned.
        // The turn is released the moment `transcribe` returns (below), not
        // at the end of the pipeline: the AI and insertion phases of this
        // job must not keep the next job's pass off the runtime.
        guard await coordinator.acquireEngine(for: jobID) else { return }
        guard isCurrent(.transcribing) else {
            coordinator.releaseEngine(for: jobID)
            return
        }

        do {
            // The user often stops speaking but keeps the shortcut held; the
            // model then sees a silent tail and appends "Thank you." (2026-09-13
            // user report). Trim that tail from the model's input only. The
            // original `recording` still goes to history and stored audio, so
            // the row's duration is the length the user recorded.
            let modelInput = SpeechGate.trimmingTrailingSilence(recording, thresholds: tunables.speechGate)
            let jobID = jobID
            let request = TranscriptionRequest(
                jobID: jobID,
                audio: modelInput,
                // ADR-017: the transcription-language setting is a hint;
                // nil keeps Whisper's automatic detection (FR-STT-003).
                languageHint: settingsSnapshot?.transcriptionLanguage,
                task: .transcribe,
                // ADR-018: the snapshot's dictionary, so a list edited while
                // the job runs does not change what this job's model sees.
                initialPrompt: settingsSnapshot.flatMap { DictionaryPrompt.render($0.dictionary) }
            )
            let result: TranscriptionResult
            do {
                defer { coordinator.releaseEngine(for: jobID) }
                result = try await transcriptionEngine.transcribe(request) { [weak coordinator] event in
                    await coordinator?.receiveTranscriptionEvent(event, for: jobID)
                }
            }
            try Task.checkCancellation()
            guard isCurrent(.transcribing) else { return }
            job?.recordTranscriptionDuration(
                result.timings.inferenceEnd - result.timings.requestStart
            )

            // Second line against the same hallucination: a trailing segment
            // that is a known silence phrase over quiet audio is dropped.
            // Energy-conditioned per segment, so a spoken "thank you" stays.
            // `modelInput.samples` is the *unpadded* clip: the engine's
            // `ShortClipPadding` zeros never come back here. A segment whose
            // timestamps fall past the real end collapses to an empty range
            // in `peakLevelDBFS` and reads as the silence floor — the same
            // clamp WhisperKit's own 30 s window padding relies on — so the
            // hallucination check still fires over the padded tail.
            let stripped = SpeechGate.strippingTrailingHallucinations(
                text: result.text,
                segments: result.segments,
                samples: modelInput.samples,
                sampleRate: modelInput.sampleRate,
                thresholds: tunables.speechGate
            )
            if stripped.droppedSegmentCount > 0 {
                // Scalars only: how often it fires, never what was dropped.
                await diagnosticLogger.log(
                    DiagnosticEvent(
                        name: .sttSegmentsDropped,
                        jobID: jobID,
                        result: .warning,
                        attributes: DiagnosticAttributes(
                            reason: "trailingHallucinationDropped",
                            segmentCount: stripped.droppedSegmentCount
                        )
                    )
                )
            }

            let rawText = stripped.text
            guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !SpeechGate.isLikelyHallucination(rawText, peakLevelDBFS: recording.peakLevelDBFS, thresholds: tunables.speechGate)
            else {
                _ = try? await apply(.transcriptionFailure(jobID: jobID, code: .sttEmpty), coordinator)
                return
            }
            recordRawTranscript(rawText)
            recordFinalText(rawText)

            let mode = job?.modeSnapshot ?? .off
            _ = try? await apply(.rawTranscript(jobID: jobID, mode: mode), coordinator)
            guard job?.id == jobID else { return }

            if mode != .off {
                await processAI(coordinator)
            }
            guard isCurrent(.inserting) else { return }
            // History and data: the recording rides along so the history
            // write can keep it when stored audio is opted in.
            await performInsertion(recording: recording, coordinator)
        } catch is CancellationError {
            // Escape/termination intentionally suppresses both cancellation
            // errors and late non-cooperative runtime callbacks.
        } catch let error as KVoiceError {
            guard isCurrent(.transcribing) else { return }
            _ = try? await apply(.transcriptionFailure(jobID: jobID, code: error.code), coordinator)
        } catch {
            guard isCurrent(.transcribing) else { return }
            _ = try? await apply(.transcriptionFailure(jobID: jobID, code: .sttFailed), coordinator)
        }
        await coordinator.runnerPipelineDidFinish(self)
    }

    func performInsertion(recording: AudioRecording?, _ coordinator: isolated Coordinator) async {
        guard isCurrent(.inserting),
              let job,
              let finalText = job.finalText ?? job.rawTranscript,
              !finalText.isEmpty
        else { return }
        exactFinalTextForFallback = finalText

        if job.delivery == .inApp {
            // Onboarding's test field: no AX resolution, no clipboard, no
            // history. The shell reads `inAppDeliveredText` for this job.
            coordinator.recordInAppDelivery(InAppDeliveredText(jobID: jobID, text: finalText))
            _ = try? await apply(.insertionSucceeded(jobID: jobID, outcome: .deliveredInApp), coordinator)
            return
        }

        guard let insertionService = services.insertionService else {
            // A reducer-only controller has no side-effect service available.
            // Retain the exact text and surface a safe failure instead of
            // inventing a destination.
            _ = try? await apply(.clipboardFailure(jobID: jobID, code: .accessibilityNoFrontmostApp), coordinator)
            return
        }

        // ADR-022 item 7: insertions land in recording order, never
        // interleaved. A single job is granted at once; an overlapped job
        // whose AI finished first waits here, in `.inserting`, until every
        // older job's insertion has completed or failed.
        guard await coordinator.acquireInsertionTurn(for: jobID) else { return }
        defer { coordinator.releaseInsertionTurn(for: jobID) }
        guard isCurrent(.inserting), self.job?.id == job.id else { return }

        // Manage Models options apply only to what reaches the target; the
        // in-app delivery above and the history row keep the verbatim text.
        let preparedText = InsertionTextPreparation.prepare(
            finalText,
            settings: settingsSnapshot ?? AppSettings()
        )

        guard let target = job.target else {
            // No target was captured at recording start. Copy exactly once via
            // the insertion boundary's write-only fallback; never resolve AX
            // again because that could target a different application.
            do {
                try Task.checkCancellation()
                // The clipboard fallback carries the exact final text (spec
                // "clipboard contains exact final text"), not the prepared one.
                try await insertionService.copyToClipboard(finalText, jobID: jobID)
                try Task.checkCancellation()
                guard isCurrent(.inserting) else { return }
                _ = try? await apply(
                    .insertionFallback(
                        jobID: jobID,
                        outcome: .copiedToClipboard(reason: .noFrontmostApplication)
                    ),
                    coordinator
                )
                await appendHistoryIfEnabled(
                    outcome: .copiedToClipboard(reason: .noFrontmostApplication),
                    recording: recording,
                    coordinator
                )
            } catch is CancellationError {
                // Cancellation suppresses any late terminal claim.
            } catch let error as KVoiceError {
                guard isCurrent(.inserting) else { return }
                _ = try? await apply(.clipboardFailure(jobID: jobID, code: error.code), coordinator)
            } catch {
                guard isCurrent(.inserting) else { return }
                _ = try? await apply(.clipboardFailure(jobID: jobID, code: .clipboardWriteFailed), coordinator)
            }
            return
        }

        do {
            let outcome = try await insertionService.insert(
                preparedText,
                into: target,
                jobID: jobID
            )
            guard isCurrent(.inserting) else { return }
            switch outcome {
            case .inserted, .deliveredInApp:
                await completeSuccessfulInsertion(finalText: finalText, target: target, job: job)
                _ = try? await apply(.insertionSucceeded(jobID: jobID, outcome: outcome), coordinator)
            case .copiedToClipboard:
                _ = try? await apply(.insertionFallback(jobID: jobID, outcome: outcome), coordinator)
            case .abortedAtTermination:
                // An insertion service never reports this; it is a history-only
                // outcome written by terminate().
                _ = try? await apply(.clipboardFailure(jobID: jobID, code: .appInternal), coordinator)
                return
            }
            await appendHistoryIfEnabled(outcome: outcome, recording: recording, coordinator)
        } catch is CancellationError {
            // Never claim a clipboard copy or retry an uncertain AX mutation.
        } catch let error as KVoiceError {
            guard isCurrent(.inserting) else { return }
            _ = try? await apply(.clipboardFailure(jobID: jobID, code: error.code), coordinator)
        } catch {
            guard isCurrent(.inserting) else { return }
            _ = try? await apply(.clipboardFailure(jobID: jobID, code: .clipboardWriteFailed), coordinator)
        }
    }

    /// The opt-in follow-ups to a successful Accessibility or typed insertion,
    /// in order: the pasted cue, the clipboard copy (FR-AX-009 opt-in
    /// deviation), then auto-send's Return key. None of them can change the
    /// insertion outcome; each is best effort and logged as a scalar.
    private nonisolated(nonsending) func completeSuccessfulInsertion(
        finalText: String,
        target: TargetApplicationSnapshot,
        job: DictationJob
    ) async {
        let feedback = activeFeedbackSettings ?? .init()
        if feedback.soundFeedbackEnabled {
            await services.feedbackPlayer?.play(.pasted, using: feedback.cueSet)
        }
        if feedback.preserveTranscriptInClipboard, let insertionService = services.insertionService {
            do {
                try await insertionService.copyToClipboard(finalText, jobID: jobID)
            } catch {
                await diagnosticLogger.log(
                    DiagnosticEvent(
                        name: .insertionCompleted,
                        jobID: jobID,
                        result: .warning,
                        errorCode: .clipboardWriteFailed,
                        attributes: DiagnosticAttributes(reason: "preserveTranscriptInClipboard")
                    )
                )
            }
        }
        if job.options.autoSend, let returnKeySender = services.returnKeySender {
            do {
                try await returnKeySender.sendReturnKey(to: target, jobID: jobID)
                await diagnosticLogger.log(
                    DiagnosticEvent(
                        name: .insertionCompleted,
                        jobID: jobID,
                        result: .success,
                        attributes: DiagnosticAttributes(reason: "autoSendReturn")
                    )
                )
            } catch {
                await diagnosticLogger.log(
                    DiagnosticEvent(
                        name: .insertionCompleted,
                        jobID: jobID,
                        result: .warning,
                        errorCode: .appInternal,
                        attributes: DiagnosticAttributes(reason: "autoSendReturnFailed")
                    )
                )
            }
        }
    }

    private func processAI(_ coordinator: isolated Coordinator) async {
        guard isCurrent(.processingAI),
              let job,
              let settings = job.aiSettingsSnapshot,
              let aiProcessingClient = services.aiProcessingClient
        else {
            if isCurrent(.processingAI) {
                recordAIFallback(.aiConfigurationMissing, for: jobID)
                _ = try? await apply(.aiFailure(jobID: jobID, code: .aiConfigurationMissing), coordinator)
            }
            return
        }

        // AI actions: a trigger phrase at the start of the transcript can
        // select another action. The resolver hands back the settings to run
        // (the triggered action applied, or the snapshot unchanged) and the
        // transcript with the trigger removed; the request is built from
        // those exactly as before. Context is attached only for what the
        // running action opted into, and only when the shell installed a
        // provider.
        let resolution = ActionTriggerResolver.resolve(
            transcript: job.rawTranscript ?? "",
            settings: settings
        )
        let resolved = resolution.settings
        let context = await aiRequestContext(for: resolved.activePromptMode, settings: resolved, coordinator)
        // Escape may have landed during the context read; no request then.
        guard isCurrent(.processingAI) else { return }
        let request = AIProcessRequest(
            jobID: jobID,
            mode: resolved.mode,
            rawTranscript: resolution.transcript,
            modelID: resolved.modelID,
            targetLanguage: resolved.translationLanguage,
            polishPrompt: resolved.promptConfiguration.polishPrompt,
            context: context
        )

        // The AI stage runs as a child task so Escape can cancel it at any
        // await — including the credential load — while this pipeline task
        // stays alive to insert the raw transcript. AI requests of different
        // jobs may overlap (ADR-022 item 7): nothing here is shared.
        let secretsRepository = services.secretsRepository
        let aiTask = Task<AIProcessResult, Error> {
            let credentials = try await secretsRepository?.load()
            try Task.checkCancellation()
            if let credentialClient = aiProcessingClient as? any CredentialInjectingAIProcessingClient {
                return try await credentialClient.process(
                    request,
                    settings: resolved,
                    credentials: credentials.map { AICredentialSnapshot(apiKey: $0.apiKey) }
                )
            }
            return try await aiProcessingClient.process(request, settings: resolved)
        }
        self.aiTask = aiTask
        defer { self.aiTask = nil }

        do {
            let result = try await aiTask.value
            guard isCurrent(.processingAI) else { return }
            recordFinalText(result.text)
            self.job?.recordAIDuration(result.requestDuration) // History and data: "Avg AI time" tile
            _ = try? await apply(.aiSuccess(jobID: jobID), coordinator)
        } catch let error as KVoiceError {
            // Scalars only (rule 3): the bounded attribute catalog is all a
            // `KVoiceError` can carry, so nothing here can be text.
            aiFailureMetadata = error.metadata
            await useRawTranscriptAfterAIError(error.code, coordinator)
        } catch is CancellationError {
            await useRawTranscriptAfterAIError(.aiCancelled, coordinator)
        } catch {
            await useRawTranscriptAfterAIError(.aiUnreachable, coordinator)
        }
    }

    /// AI actions: the user profile always, clipboard and selection only
    /// when the action asked for them. Reads happen here, after the
    /// transcript exists, so nothing is captured for a cancelled dictation.
    private func aiRequestContext(
        for action: PromptMode?,
        settings: AIEndpointSettings,
        _ coordinator: isolated Coordinator
    ) async -> AIRequestContext {
        var context = AIRequestContext(userProfile: settings.userProfile)
        guard let action, let aiContextProvider = coordinator.aiContextProvider else { return context }
        if action.includesClipboardText {
            context.clipboardText = await aiContextProvider.clipboardText()
        }
        if action.includesSelectedText {
            context.selectedText = await aiContextProvider.selectedText()
        }
        return context
    }

    private func useRawTranscriptAfterAIError(_ code: KVoiceErrorCode, _ coordinator: isolated Coordinator) async {
        // Escape may already have selected the raw text and advanced the state
        // while the provider task was unwinding. Never emit a second terminal
        // event in that case.
        guard isCurrent(.processingAI) else { return }
        recordAIFallback(code, for: jobID)
        _ = try? await apply(.aiFailure(jobID: jobID, code: code), coordinator)
    }

}
