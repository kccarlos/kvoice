import Foundation
import KvoiceDomain

/// UI v2 fidelity F5: the recorder's one subtitle line outside a recording
/// (`Recorder.dc.html`): what runs, where the text went, or the one fact
/// that explains a warning. The recording's instruction and length hint
/// are drawn by the view from `HUDRecordingState`.
public struct HUDSubtitle: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        /// `text-2`.
        case plain
        /// The design's link colour (`cursor-ink`): the one clickable line,
        /// "Open Speech Models to reinstall".
        case link
    }

    public let text: String
    public let style: Style
    /// False for the design's own short lines, which stay on one line; true
    /// for product copy that can run longer (a reason with no short form),
    /// which wraps rather than losing its end to an ellipsis.
    public let wraps: Bool

    public init(_ text: String, style: Style = .plain, wraps: Bool = false) {
        self.text = text
        self.style = style
        self.wraps = wraps
    }
}

extension HUDViewState {
    /// The subtitle the recorder shows; nil for none (and while recording,
    /// whose lines come from `HUDRecordingState`). The busy and overlap
    /// notes outrank the facts while the job is processing: they are the
    /// news of the moment.
    public var subtitle: HUDSubtitle? {
        switch phase {
        case .idle, .recording:
            return nil
        case .finalizing, .transcribing, .processingAI, .inserting:
            if let overlapPausedReason {
                return HUDSubtitle(Self.overlapPausedNote(overlapPausedReason))
            }
            if busyHint {
                return HUDSubtitle(String(localized: "Finishing previous dictation…", bundle: .module))
            }
            switch phase {
            case .finalizing:
                return facts.modelName.map { HUDSubtitle($0) }
            case .transcribing:
                return facts.modelName.map { HUDSubtitle(String(localized: "\($0) · on device", bundle: .module)) }
            case .processingAI:
                return facts.aiProviderName.map { HUDSubtitle($0) }
            default:
                return facts.targetAppName.map { HUDSubtitle(String(localized: "into \($0)", bundle: .module)) }
            }
        case .completed(let completion):
            switch completion.kind {
            case .success:
                if completion.durationCapReached, let warning = completion.warningMessage, !warning.isEmpty {
                    return HUDSubtitle(warning, wraps: true)
                }
                return Self.insertedLine(words: facts.wordCount, app: facts.targetAppName).map { HUDSubtitle($0) }
            case .aiFallback:
                if let code = completion.aiFallback {
                    return HUDSubtitle(Self.aiFallbackLine(code, provider: facts.aiProviderName))
                }
                return completion.warningMessage.map { HUDSubtitle($0, wraps: true) }
            case .clipboardFallback:
                return HUDSubtitle(Self.clipboardLine(completion.clipboardReason))
            }
        case .blocked(let blocked):
            if Self.microphoneCodes.contains(blocked.code) {
                return HUDSubtitle(String(localized: "Microphone access is off", bundle: .module))
            }
            return HUDSubtitle(blocked.message, wraps: true)
        case .failed(let failure):
            if recoverableTranscript != nil {
                return HUDSubtitle(failure.message, wraps: true)
            }
            if failure.isFatal {
                return HUDSubtitle(Self.openSpeechModelsLink, style: .link)
            }
            if Self.noSpeechCodes.contains(failure.code) {
                return HUDSubtitle(String(localized: "No speech detected", bundle: .module))
            }
            return HUDSubtitle(failure.message, wraps: true)
        }
    }

    /// The AI action's name as the processing badge ("Clean Up" beside
    /// "Polishing"); nil outside polishing — "Translating to Japanese"
    /// already says what runs, as the status panel does (F1).
    public var processingBadge: String? {
        if case .processingAI(let ai) = phase, ai.mode == .polish { return facts.aiActionName }
        return nil
    }

    /// True for the one state whose subtitle is a link: the recorder takes
    /// that one click (and stays non-activating).
    public var offersSpeechModelsLink: Bool {
        subtitle?.style == .link
    }

    /// What VoiceOver hears after the title: the subtitle, plus the full
    /// reason wherever the subtitle is the design's short form of it — a
    /// short line must never be all a VoiceOver user gets.
    public var spokenDetail: String? {
        guard let subtitle else { return detail }
        switch phase {
        case .failed(let failure) where failure.isFatal && recoverableTranscript == nil:
            return "\(failure.message) \(subtitle.text)"
        case .completed(let completion) where completion.kind != .success:
            if let warning = completion.warningMessage, !warning.isEmpty, warning != subtitle.text {
                return "\(subtitle.text). \(warning)"
            }
            return subtitle.text
        case .blocked(let blocked) where blocked.message != subtitle.text:
            return "\(subtitle.text). \(blocked.message)"
        default:
            return subtitle.text
        }
    }

    static let openSpeechModelsLink = String(localized: "Open Speech Models to reinstall", bundle: .module)

    static let microphoneCodes: Set<String> = [
        KVoiceErrorCode.permissionMicrophoneNotDetermined.rawValue,
        KVoiceErrorCode.permissionMicrophoneDenied.rawValue,
        KVoiceErrorCode.permissionMicrophoneRestricted.rawValue
    ]

    static let noSpeechCodes: Set<String> = [
        KVoiceErrorCode.audioNoSamples.rawValue,
        KVoiceErrorCode.audioTooShort.rawValue,
        KVoiceErrorCode.sttInvalidAudio.rawValue,
        KVoiceErrorCode.sttEmpty.rawValue
    ]

    /// "38 words → Notes", "1 word → Notes", "38 words", "Into Notes"; nil
    /// with neither fact. Shared by the recorder and the status panel's
    /// outcome card (F1), so the two say it the same way.
    public static func insertedLine(words: Int?, app: String?) -> String? {
        switch (words, app) {
        case (let count?, let app?):
            return count == 1
                ? String(localized: "1 word → \(app)", bundle: .module)
                : String(localized: "\(count) words → \(app)", bundle: .module)
        case (let count?, nil):
            return count == 1
                ? String(localized: "1 word", bundle: .module)
                : String(localized: "\(count) words", bundle: .module)
        case (nil, let app?):
            return String(localized: "Into \(app)", bundle: .module)
        case (nil, nil):
            return nil
        }
    }

    /// "Local Ollama didn't answer · raw transcript used": what happened to
    /// the AI request, naming the configuration ("AI" without one).
    public static func aiFallbackLine(_ code: AIErrorCode, provider: String?) -> String {
        let name = provider ?? String(localized: "AI", bundle: .module)
        switch code {
        case .aiUnreachable, .aiTimeout:
            return String(localized: "\(name) didn’t answer · raw transcript used", bundle: .module)
        case .aiAuthentication:
            return String(localized: "\(name) rejected the key · raw transcript used", bundle: .module)
        case .aiRateLimited, .aiQuotaExhausted:
            return String(localized: "\(name) is at its limit · raw transcript used", bundle: .module)
        case .aiProviderUnavailable:
            return String(localized: "\(name) isn’t available · raw transcript used", bundle: .module)
        case .aiInputTooLong:
            return String(localized: "Too long for \(name) · raw transcript used", bundle: .module)
        case .aiCancelled:
            return String(localized: "AI skipped · raw transcript used", bundle: .module)
        case .aiConfigurationMissing, .aiURLInvalid, .aiInsecureRemoteURL:
            return String(localized: "AI isn’t set up · raw transcript used", bundle: .module)
        default:
            return String(localized: "\(name) sent no usable answer · raw transcript used", bundle: .module)
        }
    }

    /// "This field doesn't accept typing — press ⌘V": why the text is on the
    /// clipboard and the one key that finishes the job. The status panel's
    /// outcome card uses the same line.
    public static func clipboardLine(_ reason: ClipboardFallbackReason?) -> String {
        switch reason {
        case .notEditable?, .unsupportedValueType?, .setFailed?, .verifyFailed?, .timeout?:
            return String(localized: "This field doesn’t accept typing — press ⌘V", bundle: .module)
        case .noFocusedElement?:
            return String(localized: "No text field was selected — press ⌘V", bundle: .module)
        case .noFrontmostApplication?:
            return String(localized: "No app was in front — press ⌘V", bundle: .module)
        case .targetApplicationChanged?:
            return String(localized: "The app in front changed — press ⌘V", bundle: .module)
        case .secureTarget?:
            return String(localized: "Secure fields can’t take dictation — press ⌘V", bundle: .module)
        case .permissionNotGranted?:
            return String(localized: "Accessibility access is off — press ⌘V", bundle: .module)
        case .textTooLarge?:
            return String(localized: "Too long to type — press ⌘V", bundle: .module)
        case nil:
            return String(localized: "Press ⌘V to paste", bundle: .module)
        }
    }
}
