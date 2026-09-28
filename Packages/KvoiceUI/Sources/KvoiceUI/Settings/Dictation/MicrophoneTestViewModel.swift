import Foundation
import KvoiceDomain
import Observation

/// The meter-only microphone test, shared by onboarding and the Dictation tab.
///
/// It owns the test state, the displayed level, and the name of the current
/// input device. It never retains audio: the domain `MicrophoneTestResult`
/// carries aggregate numbers only, and that is all this type keeps.
///
/// The capture service streams privacy-safe `.level` events while the test
/// runs, so the meter reads live (C.2 step 5); the returned peak is applied
/// when the test finishes for adapters that stream nothing.
@Observable
@MainActor
public final class MicrophoneTestViewModel {
    public private(set) var state: MicrophoneTestState = .notStarted
    public private(set) var levelDBFS: Float = -.infinity
    /// True once a live sample has arrived during the current test, so the
    /// view can say whether the meter is live or post-hoc.
    public private(set) var levelIsLive = false
    public private(set) var inputDeviceName: String?

    private let audioCapture: (any AudioCaptureService)?
    private let inputDeviceNameProvider: @Sendable () -> String?

    public init(
        audioCapture: (any AudioCaptureService)? = nil,
        inputDeviceNameProvider: @escaping @Sendable () -> String? = { nil },
        state: MicrophoneTestState = .notStarted
    ) {
        self.audioCapture = audioCapture
        self.inputDeviceNameProvider = inputDeviceNameProvider
        self.state = state
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Re-reads the system default input. Cheap enough to call whenever the
    /// hosting tab appears or the app becomes active.
    public func refreshInputDevice() {
        inputDeviceName = inputDeviceNameProvider()
    }

    /// Runs the test. `authorization` is checked first so a test can never
    /// start before the grant (FR-ONB-004); the caller supplies the current
    /// value rather than this type prompting for it.
    public func run(
        authorization: PermissionAuthorization,
        duration: Duration = .seconds(3)
    ) async {
        guard authorization == .granted else {
            state = .failed(String(localized: "Grant Microphone permission before running the level test.", bundle: .module))
            return
        }
        guard !isRunning else { return }

        state = .running
        levelIsLive = false
        levelDBFS = -.infinity

        guard let audioCapture else {
            state = .failed(String(localized: "Microphone testing is unavailable in this app session.", bundle: .module))
            return
        }

        do {
            let result = try await audioCapture.runMicrophoneTest(duration: duration) { [weak self] event in
                guard case .level(let rms, let peak) = event else { return }
                await self?.updateLevel(rmsDBFS: rms, peakDBFS: peak)
            }
            if !levelIsLive {
                levelDBFS = result.peakLevelDBFS
            }
            state = .completed(result)
        } catch {
            state = .failed(Self.userFacingMessage(for: error))
        }
    }

    /// Production audio adapters can feed meter samples while a test is
    /// running. No sample data is stored here.
    public func updateLevel(rmsDBFS: Float, peakDBFS: Float) {
        levelDBFS = max(rmsDBFS, peakDBFS)
        if isRunning {
            levelIsLive = true
        }
    }

    public func markSkipped() {
        state = .skipped
    }

    /// Returns to Not Started (used when a previously skipped test becomes
    /// possible again after a grant).
    public func reset() {
        state = .notStarted
        levelDBFS = -.infinity
        levelIsLive = false
    }

    // MARK: Presentation helpers

    /// 0…1 for a linear meter, mapping −60 dBFS…0 dBFS.
    public var meterValue: Double {
        let level = Double(levelDBFS)
        guard level.isFinite else { return 0 }
        return min(max((level + 60) / 60, 0), 1)
    }

    public var meterAccessibilityValue: String {
        guard levelDBFS.isFinite else { return String(localized: "No signal yet", bundle: .module) }
        return String(format: String(localized: "%.1f decibels relative to full scale", bundle: .module), levelDBFS)
    }

    public var statusDescription: String {
        switch state {
        case .notStarted: return String(localized: "No level test has run yet.", bundle: .module)
        case .running: return String(localized: "Listening…", bundle: .module)
        case .completed(let result):
            let peak = String(format: "%.1f", result.peakLevelDBFS)
            return String(localized: "Level test complete (peak \(peak) dBFS).", bundle: .module)
        case .failed(let message): return message
        case .skipped: return String(localized: "Level test skipped.", bundle: .module)
        }
    }

    private static func userFacingMessage(for error: Error) -> String {
        let description = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        return description.isEmpty ? String(localized: "The microphone test could not be completed.", bundle: .module) : description
    }
}
