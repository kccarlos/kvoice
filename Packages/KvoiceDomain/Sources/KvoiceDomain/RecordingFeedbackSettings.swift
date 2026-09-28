import Foundation

/// Recording-time feedback and side effects (HoAh "Recording Settings").
public struct RecordingFeedbackSettings: Codable, Sendable, Equatable {
    /// Short cues at the start, stop, cancel, and insertion edges. On by
    /// default; the cues are the only audible signal in push-to-talk that
    /// the key registered.
    public var soundFeedbackEnabled: Bool

    /// Which sounds the cues are (2026-09-16). kvoice's own tones by
    /// default: they play on the media channel, so a Bluetooth headset that
    /// has just switched to its call profile still renders them cleanly,
    /// which the stock alert sounds do not (see the Changelog entry).
    public var cueSet: RecordingFeedbackCueSet

    /// Lowers the default output device's volume to zero while recording and
    /// restores it afterwards (CoreAudio virtual main volume, public API).
    /// Media playback is not paused: doing that needs the private
    /// MediaRemote framework, which the project does not use.
    public var muteSystemAudioDuringRecording: Bool

    /// After a successful Accessibility or typed insertion, also copy the
    /// final text to the pasteboard. Off by default because FR-AX-009 says a
    /// success must not touch the pasteboard; enabling it is an accepted
    /// opt-in deviation recorded in KNOWN_ISSUES.md.
    public var preserveTranscriptInClipboard: Bool

    public init(
        soundFeedbackEnabled: Bool = true,
        cueSet: RecordingFeedbackCueSet = .kvoice,
        muteSystemAudioDuringRecording: Bool = false,
        preserveTranscriptInClipboard: Bool = false
    ) {
        self.soundFeedbackEnabled = soundFeedbackEnabled
        self.cueSet = cueSet
        self.muteSystemAudioDuringRecording = muteSystemAudioDuringRecording
        self.preserveTranscriptInClipboard = preserveTranscriptInClipboard
    }

    private enum CodingKeys: String, CodingKey {
        case soundFeedbackEnabled
        case cueSet
        case muteSystemAudioDuringRecording
        case preserveTranscriptInClipboard
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            soundFeedbackEnabled: try values.decodeIfPresent(Bool.self, forKey: .soundFeedbackEnabled) ?? true,
            // A settings file written before the cue set existed gets the
            // new default, not the alert sounds it used to play.
            cueSet: try values.decodeIfPresent(RecordingFeedbackCueSet.self, forKey: .cueSet) ?? .kvoice,
            muteSystemAudioDuringRecording: try values.decodeIfPresent(
                Bool.self,
                forKey: .muteSystemAudioDuringRecording
            ) ?? false,
            preserveTranscriptInClipboard: try values.decodeIfPresent(
                Bool.self,
                forKey: .preserveTranscriptInClipboard
            ) ?? false
        )
    }
}

/// The audible cue points the controller reports. The player decides what
/// each sounds like; the controller never sees an audio file.
public enum RecordingFeedbackCue: String, Sendable, Equatable, CaseIterable {
    case start
    case stop
    case cancel
    case pasted
}

/// Which sounds stand for the four cues. Stored as one string so a settings
/// file stays readable (`"kvoice"`, `"systemClassic"`, `"system:Glass"`);
/// anything unrecognised decodes as `.kvoice` rather than failing the load.
public enum RecordingFeedbackCueSet: Sendable, Equatable, Hashable, Codable {
    /// Four short tones kvoice synthesises in memory and plays on the media
    /// channel (`SynthesizedCueSet` in KvoiceAudio). The default.
    case kvoice
    /// The behaviour before 2026-09-16: the bundled macOS alert sounds
    /// Tink / Pop / Funk / Purr for start / stop / cancel / pasted, played as
    /// system alerts.
    case systemClassic
    /// One bundled macOS alert sound (`/System/Library/Sounds/<name>.aiff`)
    /// for every cue, played as a system alert.
    case system(name: String)

    /// The sound files every macOS install ships in `/System/Library/Sounds`,
    /// in the order the Sound settings pane lists them.
    public static let systemSoundNames: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    /// True for the two system-alert choices, whose cues go through the
    /// alert volume rather than the media channel.
    public var usesSystemAlertSounds: Bool {
        switch self {
        case .kvoice: return false
        case .systemClassic, .system: return true
        }
    }

    /// The bundled alert sound a cue maps to, or nil for the kvoice tones.
    public func systemSoundName(for cue: RecordingFeedbackCue) -> String? {
        switch self {
        case .kvoice:
            return nil
        case .systemClassic:
            switch cue {
            case .start: return "Tink"
            case .stop: return "Pop"
            case .cancel: return "Funk"
            case .pasted: return "Purr"
            }
        case .system(let name):
            return name
        }
    }

    // MARK: Codable (one string)

    private static let systemPrefix = "system:"

    public var rawValue: String {
        switch self {
        case .kvoice: return "kvoice"
        case .systemClassic: return "systemClassic"
        case .system(let name): return Self.systemPrefix + name
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "kvoice":
            self = .kvoice
        case "systemClassic":
            self = .systemClassic
        default:
            if rawValue.hasPrefix(Self.systemPrefix) {
                let name = String(rawValue.dropFirst(Self.systemPrefix.count))
                self = name.isEmpty ? .kvoice : .system(name: name)
            } else {
                self = .kvoice
            }
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Plays one short cue from the given set. Implementations must return
/// immediately and never block the caller on playback. The set travels
/// with every call because the controller plays a job's cues from that
/// job's settings snapshot, and the Settings page previews a set the user
/// has not committed yet.
public protocol RecordingFeedbackPlaying: Sendable {
    func play(_ cue: RecordingFeedbackCue, using set: RecordingFeedbackCueSet) async
}

/// Lowers and restores the system output volume around a recording.
///
/// `restore()` must be safe to call without a matching `mute()` and more than
/// once, because the controller calls it from every recording exit path
/// (stop, cancel, capture failure, termination).
public protocol SystemOutputMuting: Sendable {
    func mute() async
    func restore() async
}

/// Posts a Return key event to the target application after auto-send
/// insertion. The production adapter reuses the ADR-016 typed keyboard-event
/// poster and addresses the target PID only; it never builds a paste chord.
public protocol ReturnKeySending: Sendable {
    func sendReturnKey(to target: TargetApplicationSnapshot, jobID: JobID) async throws
}
