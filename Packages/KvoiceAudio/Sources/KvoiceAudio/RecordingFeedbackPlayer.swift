import AudioToolbox
import AVFoundation
import Foundation
import KvoiceDomain

/// Where the bundled macOS alert sounds live. They ship with every macOS
/// install, so nothing is bundled; if a file is missing the cue is silently
/// skipped.
public enum RecordingFeedbackSoundMap {
    public static let soundsDirectory = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)

    /// The classic mapping (Tink / Pop / Funk / Purr), kept for the
    /// `.systemClassic` cue set and the audio tests.
    public static func soundName(for cue: RecordingFeedbackCue) -> String {
        RecordingFeedbackCueSet.systemClassic.systemSoundName(for: cue) ?? "Tink"
    }

    public static func soundURL(for cue: RecordingFeedbackCue) -> URL {
        soundURL(named: soundName(for: cue))
    }

    public static func soundURL(named name: String) -> URL {
        soundsDirectory.appendingPathComponent("\(name).aiff")
    }
}

/// Plays the recording cues for whichever `RecordingFeedbackCueSet` the
/// caller names. Never blocks: `.kvoice` cues are `AVAudioPlayer`s over the
/// synthesised WAV data, prepared once per cue and restarted from the top
/// (`AVAudioPlayer.play()` returns at once); the system sets go through
/// `AudioServicesPlaySystemSound`, whose IDs are created once per sound name.
///
/// `AVAudioPlayer` plays on the media channel at media volume — which is
/// what makes the kvoice tones audible through a Bluetooth headset that has
/// just switched profiles, where the alert path is not (see
/// `SynthesizedCueSet`). It is not `Sendable`; it lives only inside this
/// actor.
public actor SystemRecordingFeedbackPlayer: RecordingFeedbackPlaying {
    private var soundIDs: [String: SystemSoundID] = [:]
    private var tonePlayers: [RecordingFeedbackCue: AVAudioPlayer] = [:]
    private let fileManager: FileManager
    /// Off in the tests: the synthesised data is still built, but no
    /// `AVAudioPlayer` is created, so the suite never opens an output device.
    private let playsTones: Bool

    public init(fileManager: FileManager = .default, playsTones: Bool = true) {
        self.fileManager = fileManager
        self.playsTones = playsTones
    }

    deinit {
        for id in soundIDs.values {
            AudioServicesDisposeSystemSoundID(id)
        }
    }

    public func play(_ cue: RecordingFeedbackCue, using set: RecordingFeedbackCueSet) {
        if let name = set.systemSoundName(for: cue) {
            guard let id = soundID(named: name) else { return }
            AudioServicesPlaySystemSound(id)
            return
        }
        guard let player = tonePlayer(for: cue) else { return }
        player.currentTime = 0
        player.play()
    }

    private func tonePlayer(for cue: RecordingFeedbackCue) -> AVAudioPlayer? {
        guard playsTones else { return nil }
        if let existing = tonePlayers[cue] {
            return existing
        }
        guard let player = try? AVAudioPlayer(data: SynthesizedCueSet.wavData(for: cue), fileTypeHint: AVFileType.wav.rawValue) else {
            return nil
        }
        player.prepareToPlay()
        tonePlayers[cue] = player
        return player
    }

    private func soundID(named name: String) -> SystemSoundID? {
        if let existing = soundIDs[name] {
            return existing
        }
        let url = RecordingFeedbackSoundMap.soundURL(named: name)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return nil }
        soundIDs[name] = id
        return id
    }
}
