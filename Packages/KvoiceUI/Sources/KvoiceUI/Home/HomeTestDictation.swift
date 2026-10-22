import SwiftUI
import Observation

/// UI v2 fidelity F2: Home's "Try a Test Dictation" (Home.dc hero button).
/// The app shell runs the same in-app path as the setup wizard's first
/// dictation test (C.2 step 9, `delivery: .inApp`): the production recorder
/// and speech model, with the text shown in this sheet and never inserted
/// into another app or put on the pasteboard. This model only tracks the
/// sheet's phase; the shell reports the recorder and the result.
@Observable
@MainActor
public final class HomeTestDictationModel {
    public enum Phase: Equatable, Sendable {
        /// Sheet open, nothing recorded yet.
        case ready
        /// Start asked for; waiting for the recorder.
        case starting
        case recording
        /// Stopped; waiting for the transcript.
        case finishing
        case result(String)
        case failed(String)
    }

    public private(set) var phase: Phase = .ready
    public private(set) var isPresented = false

    /// Starts the in-app test; false when the shell cannot (a dictation is
    /// running or no speech model is ready).
    public var onStart: @MainActor () -> Bool = { false }
    public var onStop: @MainActor () -> Void = {}
    /// The sheet closed while a test was in flight: discard it.
    public var onCancel: @MainActor () -> Void = {}

    public init() {}

    /// True while this sheet owns an in-app test, so the shell routes the
    /// result here and not to the setup wizard.
    public var ownsTest: Bool {
        switch phase {
        case .starting, .recording, .finishing: return true
        default: return false
        }
    }

    public func present() {
        phase = .ready
        isPresented = true
    }

    public func start() {
        guard isPresented, !ownsTest else { return }
        phase = .starting
        if !onStart() {
            phase = .failed(String(localized: "KVoice can’t start a test right now. Make sure a speech model is ready and no other dictation is running.", bundle: .module))
        }
    }

    public func stop() {
        guard phase == .starting || phase == .recording else { return }
        phase = .finishing
        onStop()
    }

    public func dismiss() {
        if ownsTest { onCancel() }
        isPresented = false
        phase = .ready
    }

    /// The shell's recorder state while this sheet owns the test.
    public func setRecording(_ recording: Bool) {
        if recording, phase == .starting { phase = .recording }
    }

    /// The shell could not start the recorder after all.
    public func startDidFail() {
        guard phase == .starting else { return }
        phase = .failed(String(localized: "The microphone did not start. Check Microphone and Permissions, then try again.", bundle: .module))
    }

    /// The test's outcome; nil when it was discarded (Escape).
    public func finish(_ outcome: DictationTestResult?) {
        guard ownsTest else { return }
        switch outcome {
        case .transcript(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = trimmed.isEmpty
                ? .failed(String(localized: "Nothing was heard. Check the microphone and try again.", bundle: .module))
                : .result(trimmed)
        case .failed(let message, _):
            phase = .failed(message)
        case nil:
            phase = .ready
        }
    }
}

/// The sheet: what the test does, Start / Stop, and the transcript (or why
/// there is none). Escape closes it and discards a test in flight.
@MainActor
struct HomeTestDictationSheet: View {
    @Bindable var model: HomeTestDictationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Test Dictation", bundle: .module)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.kv.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Speak a sentence. The text appears here and is not typed into any app.", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.kv.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            outcome
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                .padding(12)
                .background(Color.kv.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.22), value: model.phase)
            HStack(spacing: 8) {
                Spacer()
                Button {
                    model.dismiss()
                } label: {
                    Text("Done", bundle: .module)
                }
                .buttonStyle(KVSmallButtonStyle())
                .keyboardShortcut(.cancelAction)
                primary
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Color.kv.surface)
    }

    @ViewBuilder
    private var outcome: some View {
        switch model.phase {
        case .ready:
            status(String(localized: "Press Start Recording, speak, then press Stop.", bundle: .module))
        case .starting:
            status(String(localized: "Starting the microphone…", bundle: .module))
        case .recording:
            HStack(spacing: 8) {
                Circle().fill(Color.kv.voice).frame(width: 8, height: 8)
                Text("Listening…", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.kv.voiceInk)
            }
            .accessibilityElement(children: .combine)
        case .finishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing…", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.kv.text2)
            }
        case .result(let text):
            Text(verbatim: text)
                .font(.system(size: 13))
                .foregroundStyle(Color.kv.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(verbatim: message)
                .font(.system(size: 13))
                .foregroundStyle(Color.kv.errInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func status(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 13))
            .foregroundStyle(Color.kv.text2)
    }

    @ViewBuilder
    private var primary: some View {
        switch model.phase {
        case .starting, .recording:
            Button {
                model.stop()
            } label: {
                Text("Stop Recording", bundle: .module)
            }
            .buttonStyle(KVPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        case .finishing:
            Button {} label: {
                Text("Stop Recording", bundle: .module)
            }
            .buttonStyle(KVPrimaryButtonStyle())
            .disabled(true)
        case .ready:
            Button {
                model.start()
            } label: {
                Text("Start Recording", bundle: .module)
            }
            .buttonStyle(KVPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        case .result, .failed:
            Button {
                model.start()
            } label: {
                Text("Try Again", bundle: .module)
            }
            .buttonStyle(KVPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }
}
