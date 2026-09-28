import Foundation
import KvoiceDomain

/// Age-based cleanup of history rows and stored audio (Settings › Data &
/// Privacy: "Automatically delete transcript history", "Keep audio for").
///
/// `runOnce()` applies whatever the current settings say: transcript rows
/// older than the text retention go in one transaction (their audio files
/// with them), and audio older than the audio retention is removed while its
/// transcript stays.  The two retentions are independent.  `start()` runs a
/// pass immediately and then every `interval` (a day) until `stop()`; the
/// clock is injected so tests can drive the schedule.
///
/// Counts are all it reports.  No transcript text or audio ever leaves here.
public actor HistoryMaintenance {
    public struct Report: Sendable, Equatable {
        public var deletedEntryCount: Int
        public var deletedAudioFileCount: Int
        public var ranAt: Date
        /// `true` when a step failed; the counts cover what did succeed.
        public var hadErrors: Bool

        public init(deletedEntryCount: Int = 0, deletedAudioFileCount: Int = 0, ranAt: Date, hadErrors: Bool = false) {
            self.deletedEntryCount = deletedEntryCount
            self.deletedAudioFileCount = deletedAudioFileCount
            self.ranAt = ranAt
            self.hadErrors = hadErrors
        }
    }

    public private(set) var lastReport: Report?
    public var isRunning: Bool { scheduledTask != nil }

    private let repository: any HistoryRepository
    private let audioStore: (any HistoryAudioStoring)?
    private let settingsProvider: @Sendable () async -> AppSettings
    private let clock: any KvoiceClock
    private let now: @Sendable () -> Date
    private let interval: Duration
    private var scheduledTask: Task<Void, Never>?
    private var passInProgress = false

    public init(
        repository: any HistoryRepository,
        audioStore: (any HistoryAudioStoring)?,
        settingsProvider: @escaping @Sendable () async -> AppSettings,
        clock: any KvoiceClock = SystemKvoiceClock(),
        now: @escaping @Sendable () -> Date = { Date() },
        interval: Duration = .seconds(24 * 60 * 60)
    ) {
        self.repository = repository
        self.audioStore = audioStore
        self.settingsProvider = settingsProvider
        self.clock = clock
        self.now = now
        self.interval = interval
    }

    /// Runs a pass now and then once per `interval`.  Calling it twice does
    /// not start a second loop.
    public func start() {
        guard scheduledTask == nil else { return }
        scheduledTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.runOnce()
                do {
                    try await self.clock.sleep(for: self.interval)
                } catch {
                    return
                }
            }
        }
    }

    public func stop() {
        scheduledTask?.cancel()
        scheduledTask = nil
    }

    /// One cleanup pass.  Also what "Run Transcript Cleanup Now" calls; that
    /// button passes `force: true` so a pass runs even when automatic deletion
    /// is off (the user asked for it, with the retention shown in the picker).
    @discardableResult
    public func runOnce(force: Bool = false) async -> Report {
        let settings = await settingsProvider()
        let current = now()
        var report = Report(ranAt: current)
        // A second caller while a pass is in flight (launch pass racing the
        // button) waits for nothing and reports nothing; the running pass
        // covers it.
        guard !passInProgress else { return report }
        passInProgress = true
        defer { passInProgress = false }

        if settings.historyRetention.autoDeleteEnabled || force {
            let cutoff = settings.historyRetention.cutoff(now: current)
            do {
                let result = try await repository.expireEntries(createdBefore: cutoff)
                report.deletedEntryCount = result.deletedEntryCount
                report.deletedAudioFileCount += await deleteAudioFiles(result.releasedAudioPaths, report: &report)
            } catch {
                report.hadErrors = true
            }
        }

        // Audio retention applies whether or not the user still keeps new
        // recordings: turning the option off must not make old files immortal.
        if audioStore != nil {
            let cutoff = settings.audioStorage.cutoff(now: current)
            do {
                let released = try await repository.expireAudio(createdBefore: cutoff)
                report.deletedAudioFileCount += await deleteAudioFiles(released, report: &report)
            } catch {
                report.hadErrors = true
            }
        }

        lastReport = report
        return report
    }

    private func deleteAudioFiles(_ paths: [String], report: inout Report) async -> Int {
        guard let audioStore, !paths.isEmpty else { return 0 }
        var deleted = 0
        for path in paths {
            let existed = await audioStore.exists(relativePath: path)
            do {
                try await audioStore.delete(relativePath: path)
                if existed { deleted += 1 }
            } catch {
                report.hadErrors = true
            }
        }
        return deleted
    }
}

/// The production `KvoiceClock`: the continuous clock, sleeping for real.
public struct SystemKvoiceClock: KvoiceClock {
    public init() {}

    public var now: ContinuousClock.Instant { ContinuousClock.now }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
