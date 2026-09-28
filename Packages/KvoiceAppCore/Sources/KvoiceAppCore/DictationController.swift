import Foundation
import KvoiceDomain

public struct NullDiagnosticLogger: DiagnosticLogging {
    public init() {}

    public func log(_: DiagnosticEvent) async {}
}

/// The one lifecycle owner for local dictation — since ADR-022 slice 6 the
/// **coordinator** half of the controller split.
///
/// Each job is run by a `DictationJobRunner` (its state machine, pipeline,
/// Escape matrix and diagnostics). This actor owns what spans jobs: the
/// shortcut edges and trigger timing, start admission (the terminal-HUD
/// restart, the C.6 busy pulse, and — behind the `overlappingJobs` flag —
/// the FIFO of at most two finishing jobs), the engine and insertion turns
/// that keep one pass on the runtime and insertions in recording order, the
/// published `Snapshot` the shell renders, the recovery and App Intent
/// commands, the settings and prerequisite checks at the start edge, and
/// the shell hooks (history, AI context).
///
/// The published state is derived: a `.blocked` attempt the user just made,
/// else the recording job, else the oldest job in flight. With the flag off
/// there is never more than one runner, so nothing observable changed in the
/// split; every controller test predates it and passes unchanged.
///
/// Runners are plain classes confined to this actor: their suspending
/// methods take `self` as an `isolated` parameter, so the whole pipeline
/// still runs on one serial executor and every reentrancy invariant the
/// single-job controller relied on still holds (see `DictationJobRunner`).
/// No detached content work is created.
///
/// The actor is spread over three files — this one, `+Start.swift` (the
/// start edge and admission) and `+Turns.swift` (the engine and insertion
/// turns) — so members those extensions touch are internal rather than
/// `private`; nothing outside KvoiceAppCore sees them.
public actor DictationController {
    // MARK: - Runners

    /// Every job attempt still on screen or in flight, in start order. A
    /// runner leaves when its state returns to `.idle` (Escape, dismiss,
    /// reset). Never contains an `.idle` runner between calls.
    var runners: [DictationJobRunner] = []
    /// `.quit` was applied; with no runners left the state is
    /// `.terminating(nil)`, as the reducer produced before the split.
    var terminating = false
    /// Turn bookkeeping (`DictationController+Turns.swift`): who holds the
    /// engine / the insertion slot, and who waits, as continuations the
    /// coordinator resumes itself.
    var engineHolder: JobID?
    var engineWaiters: [(jobID: JobID, continuation: CheckedContinuation<Bool, Never>)] = []
    var insertionHolder: JobID?
    var insertionWaiters: [(jobID: JobID, continuation: CheckedContinuation<Bool, Never>)] = []

    /// The runner whose state the shell sees: a `.blocked` attempt (feedback
    /// for the press just made; at most one exists), else the recording job,
    /// else the oldest — "the HUD shows the recording plus a badge; when
    /// the recording ends and older jobs are still finishing, the oldest
    /// job's phase" (ADR-022 item 7).
    var focusedRunner: DictationJobRunner? {
        runners.first { $0.state.kind == .blocked } ?? recordingRunner ?? runners.first
    }

    var recordingRunner: DictationJobRunner? {
        runners.first { $0.state.kind == .recording }
    }

    /// The oldest failed job whose exact text is still retained: the one
    /// Copy / Insert Again act on, whatever else is running.
    var recoveryRunner: DictationJobRunner? {
        runners.first { $0.recoverableFailure != nil }
    }

    func runner(for jobID: JobID) -> DictationJobRunner? {
        runners.first { $0.jobID == jobID }
    }

    /// Jobs in a post-processing phase other than the focused one — the
    /// HUD's "N finishing" badge and the FIFO's occupancy.
    private var finishingCount: Int {
        let focused = focusedRunner
        return runners.filter { $0.isFinishing && $0 !== focused }.count
    }

    // MARK: - Per-job queries

    /// A job's own state, whether or not it is the one `state` shows; nil
    /// once its runner is gone (dismissed, escaped, never admitted). With
    /// overlapping jobs the shell's published state is one job's, so tests
    /// and a future per-job HUD read the others here.
    public func jobState(_ jobID: JobID) -> DictationState? {
        runner(for: jobID)?.state
    }

    /// The jobs still on screen or in flight, in start (recording) order.
    public var jobIDsInStartOrder: [JobID] {
        runners.map(\.jobID)
    }

    // MARK: - Published state

    public var state: DictationState {
        focusedRunner?.state ?? (terminating ? .terminating(nil) : .idle)
    }
    /// Canonical state projected for a HUD. It intentionally carries no audio
    /// or transcript content; UI can render this snapshot without owning
    /// lifecycle transitions. Same value as `state` since the split.
    public var hudState: DictationState { state }
    public var activeJob: DictationJob? { focusedRunner?.job }
    /// Settings captured at the start edge of the focused job. Changes made
    /// while a job is active cannot affect that job's mode or target.
    public var activeSettingsSnapshot: AppSettings? { focusedRunner?.settingsSnapshot }
    /// The exact final string retained after a result cannot be inserted. A
    /// warning UI may render this value as selectable text or offer a copy
    /// action; it is cleared when a job is explicitly discarded.
    public var exactFinalTextForFallback: String? { focusedRunner?.exactFinalTextForFallback }
    /// Bounded microphone level for the recording HUD. No samples are exposed
    /// or retained by the controller. Updated at most 20 times a second (D.5).
    public var hudInputLevel: Double { focusedRunner?.hudInputLevel ?? 0 }
    /// True from the first captured buffer with signal until the job leaves
    /// `.recording` (2026-09-16). Until then the input route may still be
    /// switching (a Bluetooth headset takes 0.5–2 s) and nothing the user
    /// says is being recorded, so the HUD says "Starting mic…" rather than
    /// "Recording" and the start cue has not played. Reset at every start.
    public var captureStarted: Bool { focusedRunner?.captureStarted ?? false }
    /// Incremented every time a shortcut press is ignored because a job is
    /// still finishing (C.6). The HUD uses it to pulse "Finishing previous
    /// dictation" without the controller queuing anything.
    public internal(set) var busyShortcutCount: Int = 0 {
        didSet { publishSnapshotIfChanged() }
    }
    /// Final text of the most recent in-app delivery (onboarding's dictation
    /// test). Never populated for normal insertion jobs.
    public internal(set) var inAppDeliveredText: InAppDeliveredText? {
        didSet { publishSnapshotIfChanged() }
    }
    /// ADR-017: live partial text of a streaming dictation, for the HUD only.
    /// `""` from the moment streaming starts (so the HUD reserves its line),
    /// updated on each `.partialText`, and `nil` outside recording,
    /// finalizing, and transcribing. Never inserted, stored, or logged.
    public var partialTranscript: String? { focusedRunner?.partialTranscript }
    /// ADR-022 item 7: the developer flag is on but the environment turned
    /// it off, and a press that would have overlapped got the busy pulse
    /// instead. Set at that refusal, cleared when the next start is
    /// admitted or the controller goes idle; the HUD and the status menu
    /// show it as one note.
    public internal(set) var overlapPausedReason: OverlapPauseReason? {
        didSet { publishSnapshotIfChanged() }
    }

    // MARK: - Snapshot stream

    /// Everything a shell needs to project the controller onto a menu and a
    /// HUD, published on change so no caller has to poll the actor.
    public struct Snapshot: Sendable, Equatable {
        public let state: DictationState
        public let inputLevel: Double
        public let activeSettings: AppSettings?
        public let recoverableTranscript: String?
        public let busyShortcutCount: Int
        public let inAppDeliveredText: InAppDeliveredText?
        /// ADR-017 live partial text; see `DictationController.partialTranscript`.
        public let partialTranscript: String?
        /// ADR-022 item 6: true while a `.failed` job keeps a transcript the
        /// controller will actually Copy / Insert Again — the same check
        /// `retryInsertion()` and `copyRetainedTranscript()` make (job,
        /// text, delivery). The HUD's buttons and the status-menu items are
        /// both driven from this one scalar so they can never drift from
        /// what the commands accept. Since slice 6 it may be true while
        /// another job records: the failed job is kept behind the recorder.
        public let canRecoverFailedInsertion: Bool
        /// `state == .recording` and the first buffer with signal has been
        /// captured (`DictationController.captureStarted`); false in every
        /// other state. The HUD's "Starting mic…" reads this.
        public let captureStarted: Bool
        /// ADR-022 item 7: jobs still finishing behind the one `state`
        /// shows — the HUD's "1 finishing" badge. 0 unless overlapping jobs
        /// are on and in use.
        public let finishingCount: Int
        /// ADR-022 item 7: see `DictationController.overlapPausedReason`.
        public let overlapPausedReason: OverlapPauseReason?
    }

    private var snapshotContinuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var lastPublishedSnapshot: Snapshot?
    /// How many snapshots `publishSnapshotIfChanged` has published, so a
    /// test reading an unbounded stream knows exactly how many to read.
    private(set) var publishedSnapshotCount = 0

    public var snapshot: Snapshot {
        let focused = focusedRunner
        return Snapshot(
            state: state,
            inputLevel: focused?.hudInputLevel ?? 0,
            activeSettings: focused?.settingsSnapshot,
            recoverableTranscript: focused?.exactFinalTextForFallback,
            busyShortcutCount: busyShortcutCount,
            inAppDeliveredText: inAppDeliveredText,
            partialTranscript: focused?.partialTranscript,
            canRecoverFailedInsertion: recoveryRunner != nil,
            captureStarted: focused.map { $0.state.kind == .recording && $0.captureStarted } ?? false,
            finishingCount: finishingCount,
            overlapPausedReason: overlapPausedReason
        )
    }

    /// Delivers the current snapshot immediately, then every change. Each
    /// subscriber keeps only the newest value, so a slow consumer sees the
    /// latest state rather than a backlog — and may therefore miss a
    /// short-lived state (the `idle` between a dismissed terminal state and
    /// the restarted recording) entirely.
    public func snapshots() -> AsyncStream<Snapshot> {
        snapshots(bufferingPolicy: .bufferingNewest(1))
    }

    /// `snapshots()` with an explicit buffer. `.unbounded` keeps every
    /// published snapshot in order, which is what a test that asserts a
    /// sequence of states needs: with the newest-only buffer, whether a
    /// transient state is observed depends on when the consumer happens to
    /// be scheduled.
    func snapshots(bufferingPolicy: AsyncStream<Snapshot>.Continuation.BufferingPolicy) -> AsyncStream<Snapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(
            bufferingPolicy: bufferingPolicy
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSnapshotSubscriber(id) }
        }
        snapshotContinuations[id] = continuation
        continuation.yield(snapshot)
        return stream
    }

    /// An unbounded `snapshots` stream and the publish count at the moment
    /// it was made, taken in one actor turn so no publish falls between
    /// them: the stream holds its initial snapshot plus exactly
    /// `publishedSnapshotCount - count` more.
    func unboundedSnapshots() -> (stream: AsyncStream<Snapshot>, count: Int) {
        (snapshots(bufferingPolicy: .unbounded), publishedSnapshotCount)
    }

    private func removeSnapshotSubscriber(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    func publishSnapshotIfChanged() {
        let current = snapshot
        guard current != lastPublishedSnapshot else { return }
        lastPublishedSnapshot = current
        publishedSnapshotCount += 1
        for continuation in snapshotContinuations.values {
            continuation.yield(current)
        }
    }

    // MARK: - Composition

    let services: DictationServices
    let settingsRepository: (any SettingsRepository)?
    let makeJobID: @Sendable () -> JobID
    /// Verifies microphone permission and model readiness at the start edge
    /// (C.5 step 3). Nil means the caller has already verified them.
    let prerequisiteChecker: (@Sendable () async -> StartPrerequisites)?
    /// ADR-022 item 7: the effective `overlappingJobs` row, pushed by the
    /// shell whenever the resolver re-resolves (`setOverlappingJobs`) and
    /// read at each key-down. `.limitedBy(fact)` is what the HUD note says.
    var overlappingJobs: Resolved<Bool>
    /// Live history enablement, updated by the app shell when the setting
    /// changes. Consulted together with the job snapshot at write time.
    var liveHistoryEnabled: Bool?
    /// AI actions: reads the clipboard and the focused selection for actions
    /// that opted into them (product decision #2). Installed by the app
    /// shell; absent means no context is ever attached.
    var aiContextProvider: (any AIContextProviding)?
    /// Opt-in stored audio (decision #1).  Nil means no file is ever written.
    /// The job's settings snapshot (`audioStorage.keepRecordings`) decides
    /// per job; the shell wires `HistoryAudioFileStore` here.
    var historyAudioStore: (any HistoryAudioStoring)?
    /// Called after each history row is committed, with the row.  The shell
    /// wires Auto Daily Export here.  Its failures cannot affect the
    /// dictation, but it is awaited inside the job's pipeline task, so it
    /// must return promptly: the shell detaches anything that touches a disk
    /// (a slow volume here would keep the pipeline alive and make the next
    /// dictation's start a silent no-op).
    var historyAppendObserver: (@Sendable (HistoryEntry) async -> Void)?

    var startInProgress = false
    private var physicalShortcutIsDown = false
    var configuredRecordingInteraction: RecordingInteraction

    // MARK: Trigger timing

    var clock: any KvoiceClock { services.clock }
    var diagnosticLogger: any DiagnosticLogging { services.diagnosticLogger }
    var tunables: Tunables { services.tunables }
    /// When the current physical press began; drives the Hybrid tap/hold
    /// decision on release.
    private var pressStartedAt: ContinuousClock.Instant?
    /// True while a Hybrid press that started (or armed) a recording is still
    /// held, so its release can choose between tap and hold.
    private var hybridHoldPending = false
    /// The previous key-down of the primary trigger, for double-press.
    private var lastPrimaryKeyDownAt: ContinuousClock.Instant?

    /// The first `.level` above `tunables.speechGate.signalPeakDBFS` is the
    /// first buffer that carried signal (shared with the recorder's
    /// leading-silence drop): the timing stamp, the start cue, and
    /// `captureStarted` all key off that one buffer. The compiled value is
    /// `SpeechGate.signalPeakThresholdDBFS`.
    static let firstAudioPeakThresholdDBFS: Float = SpeechGate.signalPeakThresholdDBFS
    /// The opening of the recording whose peak `leadingPeakDBFS` reports.
    static let leadingPeakWindow: Duration = .milliseconds(500)

    /// The developer defaults the controller reads (ADR-022 slice 5): the
    /// speech-gate thresholds and the two trigger windows. `.compiled` is
    /// the shipped table; `AppComposition` passes
    /// `Tunables(defaults: loaded.values)`.
    public struct Tunables: Sendable, Equatable {
        public var speechGate: SpeechGate.Thresholds
        /// Key-up within this window after key-down is a tap in Hybrid mode.
        public var hybridTapWindow: Duration
        /// Two key-downs within this window arm auto-send.
        public var doublePressWindow: Duration

        public init(
            speechGate: SpeechGate.Thresholds = .compiled,
            hybridTapWindow: Duration = TriggerSettings.hybridTapWindow,
            doublePressWindow: Duration = TriggerSettings.doublePressWindow
        ) {
            self.speechGate = speechGate
            self.hybridTapWindow = hybridTapWindow
            self.doublePressWindow = doublePressWindow
        }

        public init(defaults: DeveloperDefaults) {
            self.init(
                speechGate: defaults.speechGate,
                hybridTapWindow: defaults.hybridTapWindow,
                doublePressWindow: defaults.doublePressWindow
            )
        }

        public static let compiled = Tunables()
    }

    /// Creates a reducer-only controller. This initializer preserves the
    /// original app-core foundation API; the service-aware initializer below
    /// is used by the app composition root and integration tests.
    public init(
        initialState: DictationState = .idle,
        activeJob: DictationJob? = nil,
        diagnosticLogger: any DiagnosticLogging = NullDiagnosticLogger()
    ) {
        self.init(
            initialState: initialState,
            activeJob: activeJob,
            diagnosticLogger: diagnosticLogger,
            audioService: nil,
            transcriptionEngine: nil,
            insertionService: nil,
            settingsRepository: nil,
            aiProcessingClient: nil,
            secretsRepository: nil,
            historyRepository: nil,
            recordingInteraction: .pushToTalk,
            makeJobID: { UUID() },
            prerequisiteChecker: nil
        )
    }

    /// Creates the production/test coordinator with its four M1 seams.
    ///
    /// The model is deliberately not managed here: M1 assumes the composition
    /// root has loaded a verified local model into the supplied engine. AI and
    /// history are likewise not injected until their later milestones.
    public init(
        initialState: DictationState = .idle,
        activeJob: DictationJob? = nil,
        diagnosticLogger: any DiagnosticLogging = NullDiagnosticLogger(),
        audioService: (any AudioCaptureService)? = nil,
        transcriptionEngine: (any TranscriptionEngine)? = nil,
        insertionService: (any TextInsertionService)? = nil,
        settingsRepository: (any SettingsRepository)? = nil,
        aiProcessingClient: (any AIProcessingClient)? = nil,
        secretsRepository: (any SecretsRepository)? = nil,
        historyRepository: (any HistoryRepository)? = nil,
        recordingInteraction: RecordingInteraction = .pushToTalk,
        makeJobID: @escaping @Sendable () -> JobID = { UUID() },
        prerequisiteChecker: (@Sendable () async -> StartPrerequisites)? = nil,
        clock: any KvoiceClock = SystemKvoiceClock(),
        feedbackPlayer: (any RecordingFeedbackPlaying)? = nil,
        outputMuter: (any SystemOutputMuting)? = nil,
        returnKeySender: (any ReturnKeySending)? = nil,
        tunables: Tunables = .compiled,
        overlappingJobs: Resolved<Bool> = Resolved(false, .default)
    ) {
        services = DictationServices(
            diagnosticLogger: diagnosticLogger,
            audioService: audioService,
            transcriptionEngine: transcriptionEngine,
            insertionService: insertionService,
            aiProcessingClient: aiProcessingClient,
            secretsRepository: secretsRepository,
            historyRepository: historyRepository,
            clock: clock,
            feedbackPlayer: feedbackPlayer,
            outputMuter: outputMuter,
            returnKeySender: returnKeySender,
            tunables: tunables
        )
        self.settingsRepository = settingsRepository
        self.makeJobID = makeJobID
        self.prerequisiteChecker = prerequisiteChecker
        self.overlappingJobs = overlappingJobs
        configuredRecordingInteraction = recordingInteraction
        if initialState.kind != .idle || activeJob != nil {
            // The foundation initializer's seeded state, as one runner.
            let runner = DictationJobRunner(
                jobID: activeJob?.id ?? initialState.jobID ?? makeJobID(),
                startCommandAt: clock.now,
                overlapped: false,
                services: services
            )
            runner.seed(state: initialState, job: activeJob)
            runners = [runner]
        }
        for runner in runners {
            installChangeHook(on: runner)
        }
    }

    /// Convenience labels matching the domain service names used by the app
    /// composition root. It still constructs this same single actor.
    public init(
        audio: any AudioCaptureService,
        transcription: any TranscriptionEngine,
        insertion: any TextInsertionService,
        settings: (any SettingsRepository)? = nil,
        ai: (any AIProcessingClient)? = nil,
        secrets: (any SecretsRepository)? = nil,
        history: (any HistoryRepository)? = nil,
        recordingInteraction: RecordingInteraction = .pushToTalk,
        diagnosticLogger: any DiagnosticLogging = NullDiagnosticLogger(),
        makeJobID: @escaping @Sendable () -> JobID = { UUID() },
        prerequisiteChecker: (@Sendable () async -> StartPrerequisites)? = nil,
        clock: any KvoiceClock = SystemKvoiceClock(),
        feedbackPlayer: (any RecordingFeedbackPlaying)? = nil,
        outputMuter: (any SystemOutputMuting)? = nil,
        returnKeySender: (any ReturnKeySending)? = nil,
        tunables: Tunables = .compiled,
        overlappingJobs: Resolved<Bool> = Resolved(false, .default)
    ) {
        self.init(
            diagnosticLogger: diagnosticLogger,
            audioService: audio,
            transcriptionEngine: transcription,
            insertionService: insertion,
            settingsRepository: settings,
            aiProcessingClient: ai,
            secretsRepository: secrets,
            historyRepository: history,
            recordingInteraction: recordingInteraction,
            makeJobID: makeJobID,
            prerequisiteChecker: prerequisiteChecker,
            clock: clock,
            feedbackPlayer: feedbackPlayer,
            outputMuter: outputMuter,
            returnKeySender: returnKeySender,
            tunables: tunables,
            overlappingJobs: overlappingJobs
        )
    }

    /// Mirrors the History setting so a change made while a job is in flight
    /// still suppresses that job's row (FR-HIST-001).
    public func setHistoryEnabled(_ enabled: Bool) {
        liveHistoryEnabled = enabled
    }

    /// AI actions: installs the clipboard/selection reader used for actions
    /// with context awareness on. Shell hook; nil disables context.
    public func setAIContextProvider(_ provider: (any AIContextProviding)?) {
        aiContextProvider = provider
    }

    public func setHistoryAudioStore(_ store: (any HistoryAudioStoring)?) {
        historyAudioStore = store
    }

    public func setHistoryAppendObserver(_ observer: (@Sendable (HistoryEntry) async -> Void)?) {
        historyAppendObserver = observer
    }

    /// ADR-022 item 7: the shell pushes the resolver's effective row here
    /// after every re-resolve (a settings commit, an environment change).
    /// Read at the next key-down; a job already admitted is unaffected.
    public func setOverlappingJobs(_ value: Resolved<Bool>) {
        overlappingJobs = value
    }

    // MARK: - Runner bookkeeping

    func makeRunner(jobID: JobID, startCommandAt: ContinuousClock.Instant, overlapped: Bool) -> DictationJobRunner {
        let runner = DictationJobRunner(
            jobID: jobID,
            startCommandAt: startCommandAt,
            overlapped: overlapped,
            services: services
        )
        installChangeHook(on: runner)
        return runner
    }

    /// The runner's published fields fire this after every change — the
    /// `didSet` publishing the controller's own stored properties had. Runner
    /// code only ever runs on this actor's executor (its suspending methods
    /// take the actor as an `isolated` parameter), which is the assumption
    /// `assumeIsolated` checks at run time rather than trusts.
    nonisolated private func installChangeHook(on runner: DictationJobRunner) {
        runner.onChange = { [unowned self] in
            self.assumeIsolated { coordinator in
                coordinator.runnerDidChange()
            }
        }
    }

    func admit(_ runner: DictationJobRunner) {
        runners.append(runner)
        publishSnapshotIfChanged()
    }

    func remove(_ runner: DictationJobRunner) {
        runners.removeAll { $0 === runner }
        publishSnapshotIfChanged()
    }

    /// Synchronous follow-up to any runner change: drop runners that
    /// returned to `.idle`, release the turns of runners that can no longer
    /// take them, hand the turns to whoever is next, publish.
    func runnerDidChange() {
        runners.removeAll { $0.state.kind == .idle }
        abandonStaleWaiters()
        grantEngineIfPossible()
        grantInsertionIfPossible()
        if runners.isEmpty {
            overlapPausedReason = nil
        }
        publishSnapshotIfChanged()
    }

    /// Called by a runner at the end of `apply`, after its state moved and
    /// its lines were logged. Nothing suspends here today; it exists so a
    /// cross-job reaction to a transition has one named place.
    func runnerDidTransition(_ runner: DictationJobRunner) async {
        runnerDidChange()
    }

    /// Called by a runner when its pipeline task (or a retry) has finished —
    /// after the history row, so nothing the job still needed is touched.
    /// A completion the HUD cannot show (a newer job is recording) is
    /// dismissed here at once: its text has landed and its row is written,
    /// and showing "Inserted" for the *previous* sentence once the recorder
    /// goes away would read as the current one's result. A failure is kept
    /// for Copy / Insert Again until the user dismisses it.
    func runnerPipelineDidFinish(_ runner: DictationJobRunner) async {
        guard runner.state.kind == .completed,
              runners.contains(where: { $0 === runner }),
              focusedRunner !== runner
        else { return }
        await dismissHiddenCompletion(runner)
    }

    /// Dismisses a `.completed` runner the HUD is not showing, with its one
    /// scalar line. Also used by `startRecording` for a job that completed
    /// while a new start was still capturing its target.
    func dismissHiddenCompletion(_ runner: DictationJobRunner) async {
        await diagnosticLogger.log(
            DiagnosticEvent(
                name: .dictationStateChanged,
                jobID: runner.jobID,
                result: .success,
                attributes: DiagnosticAttributes(activeState: runner.state.kind, reason: "hiddenCompletionDismissed")
            )
        )
        _ = try? await runner.apply(.dismiss, self)
    }

    /// The onboarding in-app test's final text, kept until the next start.
    func recordInAppDelivery(_ delivered: InAppDeliveredText) {
        inAppDeliveredText = delivered
    }

    /// The hard cap ended the recording; a Hybrid hold is no longer pending.
    func recordingEndedByCap() {
        hybridHoldPending = false
    }

    // MARK: - In-recorder AI controls (ADR-021)

    /// ⌘1–⌘0 while recording: run `id` for the *current* job. Returns false
    /// when there is no such job phase, the job is the onboarding in-app
    /// test (it never runs AI, C.2 step 9), the action is unknown or not
    /// usable, or no endpoint exists (the switch would read "on" while
    /// nothing could run).
    ///
    /// This is job-aggregate context, not a lifecycle transition — the same
    /// category as `recordAIDuration` and `armAutoSend` — which is why it
    /// lives beside them and outside the reducer: G.5's transitions are
    /// unchanged, the reducer still validates `.rawTranscript` against the
    /// job's `modeSnapshot`, and the only thing that moved is the value that
    /// snapshot holds. Like the ADR-020 override, choosing an action by hand
    /// mid-dictation is an explicit request, so the switch is turned on for
    /// this job's snapshot; `settingsRepository` is never written. The
    /// phases (`DictationJobRunner.aiControlPhases`) are recording and
    /// finalizing: the AI stage reads the snapshot only once the transcript
    /// exists, and a push-to-talk release lands in finalizing within
    /// milliseconds of a ⌘digit press.
    @discardableResult
    public func setAIAction(id: UUID) async -> Bool {
        guard let runner = aiControlRunner, var settings = runner.aiControlSettings(),
              let action = settings.promptModes.first(where: { $0.id == id }),
              action.isUsable
        else { return false }
        settings.apply(promptMode: action)
        settings.isEnabled = true
        guard settings.mode != .off else { return false }
        await runner.applyAIControl(settings, reason: "recorderAIAction", self)
        return true
    }

    /// ⌘⇧A while recording: the master switch for the *current* job only.
    /// Turning it on with no usable default action or endpoint is refused
    /// for the same reason as above. Returns false when nothing changed.
    @discardableResult
    public func setAIEnabled(_ enabled: Bool) async -> Bool {
        guard let runner = aiControlRunner, var settings = runner.aiControlSettings(),
              settings.isEnabled != enabled else { return false }
        settings.isEnabled = enabled
        guard !enabled || settings.mode != .off else { return false }
        await runner.applyAIControl(settings, reason: "recorderAIToggle", self)
        return true
    }

    /// The job the recorder's ⌘ keys address: the newest one still in an
    /// AI-control phase.
    private var aiControlRunner: DictationJobRunner? {
        runners.last { $0.aiControlSettings() != nil }
    }

    // MARK: - Reducer boundary

    /// Routes a reducer event to the runner it belongs to. A `.start` with no
    /// job in flight creates the runner (the reducer-only path the foundation
    /// tests use); every other event goes to the runner with its job id, or
    /// to the focused runner when none matches, whose reducer then produces
    /// the same stale/illegal diagnostics the single-job controller did.
    @discardableResult
    public func apply(
        _ event: DictationEvent,
        job: DictationJob? = nil
    ) async throws -> DictationState {
        if case .quit = event {
            // Before the first await: a job queued on a turn is never handed
            // it once quitting began (see `terminate()`).
            terminating = true
            for runner in runners {
                _ = try? await runner.apply(.quit, self)
            }
            publishSnapshotIfChanged()
            return state
        }
        // After `.quit` the reducer refused a start from `.terminating`; with
        // no runner left the flag is what remembers that.
        if case .start(let jobID, _) = event, runners.isEmpty, !terminating {
            let runner = makeRunner(jobID: jobID, startCommandAt: clock.now, overlapped: false)
            admit(runner)
            do {
                let next = try await runner.apply(event, job: job, self)
                if runner.state.kind == .idle { remove(runner) }
                return next
            } catch {
                remove(runner)
                throw error
            }
        }
        guard let target = event.jobID.flatMap(runner(for:)) ?? focusedRunner else {
            return try await applyWithoutRunner(event)
        }
        return try await target.apply(event, job: job, self)
    }

    /// No job at all: the reducer on the published state, for the same
    /// ignored-transition line as before the split.
    private func applyWithoutRunner(_ event: DictationEvent) async throws -> DictationState {
        do {
            _ = try DictationReducer.reduce(state, event: event)
            // Unreachable: from `.idle` only `.start` (handled above) and
            // `.quit` (handled above) are legal; from `.terminating` nothing.
            return state
        } catch let transitionError as DictationTransitionError {
            await diagnosticLogger.log(
                DiagnosticEvent(
                    name: .dictationStateChanged,
                    jobID: event.jobID,
                    result: .ignored,
                    errorCode: transitionError.errorCode,
                    attributes: DiagnosticAttributes(
                        activeState: state.kind,
                        reason: event.kind.rawValue
                    )
                )
            )
            return state
        }
    }

    // MARK: - Shortcut and lifecycle commands

    /// Which physical trigger produced a key edge.
    public enum ShortcutTrigger: Sendable, Equatable {
        /// The recording shortcut; honours the configured interaction mode.
        case primary
        /// The middle mouse button: always toggle semantics, whatever the
        /// keyboard mode, because a mouse button is not held to talk.
        case middleMouse
    }

    /// Converts a key edge into a push-to-talk, toggle, or hybrid command.
    /// Repeated key-down and unmatched key-up edges are ignored before they
    /// can reach the lifecycle reducer. A busy controller never queues a
    /// second job — unless overlapping jobs are on (ADR-022 item 7), in
    /// which case a press while the previous job is finishing starts a new
    /// recording; see `startAdmission`.
    ///
    /// Hybrid (product decision #5): a key-up within
    /// `TriggerSettings.hybridTapWindow` of its key-down is a tap and leaves
    /// the recording running hands-free; a longer hold is push-to-talk and the
    /// release stops. The next key-down while recording stops it.
    ///
    /// Auto-send: a second key-down within `TriggerSettings.doublePressWindow`
    /// while the first press's recording is still running arms
    /// `DictationStartOptions.autoSend` instead of stopping (Toggle and
    /// Hybrid; a push-to-talk release has already stopped the job).
    ///
    /// `at` is the instant the physical edge happened. The app shell should
    /// capture it synchronously when the adapter reports the edge and pass it
    /// here, because the start edge awaits target capture and engine start and
    /// a quick tap would otherwise be measured as a hold. It defaults to the
    /// controller's clock for callers that do not care about Hybrid timing.
    @discardableResult
    public func handleShortcut(
        _ event: ShortcutEvent,
        mode: RecordingInteraction? = nil,
        trigger: ShortcutTrigger = .primary,
        at instant: ContinuousClock.Instant? = nil
    ) async -> DictationState {
        let configured = mode ?? configuredRecordingInteraction
        let interaction: RecordingInteraction = trigger == .middleMouse ? .toggle : configured
        let now = instant ?? clock.now
        let options = DictationStartOptions()

        switch event {
        case .keyDown:
            guard !physicalShortcutIsDown else { return state }
            physicalShortcutIsDown = true

            let previousKeyDown = trigger == .primary ? lastPrimaryKeyDownAt : nil
            if trigger == .primary {
                lastPrimaryKeyDownAt = now
            }

            // Double-press while the first press's recording still runs arms
            // auto-send; the press that would have stopped the recording is
            // consumed. In Hybrid the release still decides tap vs hold.
            if let recording = recordingRunner,
               trigger == .primary,
               interaction != .pushToTalk,
               recording.settingsSnapshot?.triggers.autoSendEnabled == true,
               recording.job?.options.autoSend == false,
               let previousKeyDown,
               now - previousKeyDown <= tunables.doublePressWindow
            {
                recording.armAutoSend()
                pressStartedAt = now
                hybridHoldPending = interaction == .hybrid
                await diagnosticLogger.log(
                    DiagnosticEvent(
                        name: .dictationStateChanged,
                        jobID: recording.jobID,
                        result: .success,
                        attributes: DiagnosticAttributes(
                            activeState: state.kind,
                            reason: "autoSendArmed"
                        )
                    )
                )
                return state
            }

            switch interaction {
            case .pushToTalk:
                hybridHoldPending = false
                return await startRecording(options: options)
            case .toggle:
                hybridHoldPending = false
                if recordingRunner != nil {
                    return await stopRecording()
                }
                if case .refuse(let refusal) = startAdmission() {
                    await refuseStart(refusal)
                    return state
                }
                return await startRecording(options: options)
            case .hybrid:
                if recordingRunner != nil {
                    hybridHoldPending = false
                    return await stopRecording()
                }
                if case .refuse(let refusal) = startAdmission() {
                    await refuseStart(refusal)
                    return state
                }
                pressStartedAt = now
                hybridHoldPending = true
                return await startRecording(options: options)
            }

        case .keyUp:
            guard physicalShortcutIsDown else { return state }
            physicalShortcutIsDown = false

            switch interaction {
            case .pushToTalk:
                return await stopRecording()
            case .toggle:
                return state
            case .hybrid:
                guard hybridHoldPending, let pressStartedAt else { return state }
                hybridHoldPending = false
                self.pressStartedAt = nil
                let held = now - pressStartedAt
                if held <= tunables.hybridTapWindow {
                    // A tap: hands-free until the next press.
                    return state
                }
                return await stopRecording()
            }
        }
    }

    /// Routes an app-shell command through this controller. The explicit job
    /// ID in `AppCommand` is retained for deterministic tests and stale-event
    /// diagnostics; a start command still snapshots live target/settings before
    /// the job is admitted.
    @discardableResult
    public func handle(_ command: AppCommand) async -> DictationState {
        switch command {
        case .start(let jobID, let prerequisites):
            guard prerequisites == .passed else {
                return (try? await apply(.start(jobID: jobID, prerequisites: prerequisites))) ?? state
            }
            return await startRecording(jobID: jobID)
        case .stop(let jobID):
            return await stopRecording(for: jobID)
        case .escape(let jobID):
            return await cancel(for: jobID)
        case .quit:
            return await terminate()
        case .dismiss:
            return (try? await apply(.dismiss)) ?? state
        }
    }

    // MARK: - Failure recovery (ADR-022 item 6)

    /// Why a recovery command was refused; scalars for the menu and tests.
    public enum RecoveryRefusal: Error, Sendable, Equatable {
        case notFailed
        case noRetainedText
        case noInsertionService
        case clipboardWriteFailed
    }

    /// True while the failure HUD may offer Copy and Insert Again: a job
    /// ended in `.failed` and its exact final text is still retained.
    public var canRecoverFailedInsertion: Bool {
        recoveryRunner != nil
    }

    /// "Copy" on the failure HUD: writes the exact retained text to the
    /// pasteboard through the insertion boundary's write-only fallback.
    /// This is the one place kvoice touches the pasteboard *for a failure*
    /// (FR-AX-009 is about the success path). The state stays `.failed` so
    /// the user can still Insert Again or dismiss with Escape. Acts on the
    /// oldest failed job with retained text, even while another records.
    /// Returns the refusal, or nil when the text was copied.
    @discardableResult
    public func copyRetainedTranscript() async -> RecoveryRefusal? {
        guard let runner = recoveryRunner ?? runners.first(where: { $0.state.kind == .failed }) else {
            return .notFailed
        }
        return await runner.copyRetainedTranscript()
    }

    /// "Insert Again" on the failure HUD: re-captures the *currently*
    /// frontmost application, then runs the ordinary insertion tiers over
    /// the retained text — `.failed → .inserting → .completed / .failed`
    /// through the reducer's `retryInsertion` row. The job aggregate is
    /// reused (same id, same transcript, same settings snapshot); a history
    /// row is written only if the original attempt wrote none, and without
    /// stored audio, which the controller does not keep past the pipeline.
    /// Refused outside `.failed`, without retained text, or for the
    /// in-app onboarding test. Like Copy, it acts on the oldest failed job.
    @discardableResult
    public func retryInsertion() async -> Result<DictationState, RecoveryRefusal> {
        guard let runner = recoveryRunner ?? runners.first(where: { $0.state.kind == .failed }) else {
            return .failure(.notFailed)
        }
        return await runner.retryInsertion(self)
    }

    // MARK: - Stop, cancel, terminate

    /// Stops recording and starts the local, non-streaming transcription
    /// pipeline. The method returns after audio has stopped; callers may await
    /// waitForCompletion() for deterministic integration-test completion.
    @discardableResult
    public func stopRecording(for requestedJobID: JobID? = nil) async -> DictationState {
        guard let runner = recordingRunner,
              requestedJobID == nil || requestedJobID == runner.jobID
        else {
            return state
        }
        await runner.stopRecording(self)
        return state
    }

    public func stopRecording() async -> DictationState {
        await stopRecording(for: nil)
    }

    /// Escape/cancel semantics. Applies to the recording job if one exists,
    /// otherwise the oldest job in flight (ADR-022 item 7); the per-phase
    /// matrix is the runner's (`DictationJobRunner.cancel`). A pending start
    /// reservation — the press just made, still capturing its target — is
    /// cancelled before any job is admitted.
    @discardableResult
    public func cancel(for requestedJobID: JobID? = nil) async -> DictationState {
        if startInProgress, recordingRunner == nil {
            startInProgress = false
            return state
        }
        let runner: DictationJobRunner?
        if let requestedJobID {
            runner = self.runner(for: requestedJobID)
        } else {
            runner = recordingRunner ?? focusedRunner
        }
        guard let runner, runner.job != nil else { return state }
        switch runner.state.kind {
        case .recording, .finalizing, .transcribing:
            hybridHoldPending = false
        default:
            break
        }
        await runner.cancel(self)
        return state
    }

    public func cancel() async -> DictationState {
        await cancel(for: nil)
    }

    /// App termination is a hard boundary: cancel pending work, stop capture,
    /// and make every late callback stale before it can reach insertion.
    @discardableResult
    public func terminate() async -> DictationState {
        // Set before the first await. Each runner's `terminate` suspends
        // (volume, history row) before it applies `.quit`; were the flag set
        // only after the loop, the first runner's quit would release the
        // engine turn to a job still queued behind it, and that job would
        // start a transcription pass after quit began whenever it happened
        // to be scheduled inside one of those suspensions. With the flag
        // set, no turn is granted; the queued job's wait is abandoned when
        // its own runner quits (`abandonStaleWaiters`).
        terminating = true
        for runner in runners {
            await runner.terminate(self)
        }
        hybridHoldPending = false
        publishSnapshotIfChanged()
        return state
    }

    /// Waits for every structured pipeline task. This is useful for
    /// deterministic tests and app teardown; it does not create work.
    public func waitForCompletion() async {
        while let task = runners.compactMap(\.pipelineTask).first {
            await task.value
            if runners.allSatisfy({ $0.pipelineTask == nil }) { return }
            await Task.yield()
        }
    }

    // MARK: - Job content (routed by job id)

    public func recordRawTranscript(_ text: String, for jobID: JobID) {
        runner(for: jobID)?.recordRawTranscript(text)
    }

    public func recordFinalText(_ text: String, for jobID: JobID) {
        runner(for: jobID)?.recordFinalText(text)
    }

    public func recordDurationCap(for jobID: JobID) {
        runner(for: jobID)?.recordDurationCap(for: jobID)
    }

    public func recordAIFallback(_ code: AIErrorCode, for jobID: JobID) {
        runner(for: jobID)?.recordAIFallback(code, for: jobID)
    }

    // MARK: - Service callbacks (routed by job id)

    /// A late event for a job that is gone finds no runner and is dropped —
    /// the reentrancy rule of 2026-09-14, structurally.
    func receiveAudioEvent(_ event: AudioCaptureEvent, for jobID: JobID) async {
        guard let runner = runner(for: jobID) else { return }
        await runner.receiveAudioEvent(event, self)
    }

    func receiveTranscriptionEvent(_ event: TranscriptionEvent, for jobID: JobID) {
        runner(for: jobID)?.receiveTranscriptionEvent(event)
    }

}

/// Final text handed back to the app shell for an in-app delivery job.
public struct InAppDeliveredText: Sendable, Equatable {
    public let jobID: JobID
    public let text: String

    public init(jobID: JobID, text: String) {
        self.jobID = jobID
        self.text = text
    }
}

/// Compatibility name matching the architecture specification. This is a
/// typealias, not a second actor or lifecycle owner.
public typealias DictationCoordinator = DictationController
