import Foundation
import KvoiceDomain

/// kvoice's own recording cues, generated in memory (2026-09-16).
///
/// Why not the bundled alert sounds: on AirPods the input engine's start
/// forces the Bluetooth A2DP→HFP switch, and an alert played into that
/// switch is either swallowed or rendered through the call profile's narrow
/// band, where the stock `Tink` comes out as something that sounds like
/// the macOS error beep. These tones are short, mid-band (they survive the
/// 8 kHz HFP codec), and played through `AVAudioPlayer` on the media channel
/// at media volume rather than as system alerts. Nothing is bundled: each
/// cue is a few thousand samples of arithmetic, encoded to a WAV `Data`
/// once so the player can hand it to `AVAudioPlayer(data:)`.
///
/// Pure and `Sendable`: the tests assert length and peak of the buffers
/// without playing anything.
public struct SynthesizedCueSet: Sendable {
    public static let sampleRate: Double = 44_100
    /// -12 dBFS: audible on a headset without startling on speakers.
    public static let peakAmplitude: Float = 0.25

    /// One note of a cue: a sine at `frequency` for `duration`, shaped by a
    /// linear attack and release so it neither clicks nor rings.
    public struct Note: Sendable, Equatable {
        public let frequency: Double
        public let duration: Duration
        public let attack: Duration
        public let release: Duration
        public let amplitude: Float

        public init(
            frequency: Double,
            duration: Duration,
            attack: Duration = .milliseconds(10),
            release: Duration = .milliseconds(40),
            amplitude: Float = SynthesizedCueSet.peakAmplitude
        ) {
            self.frequency = frequency
            self.duration = duration
            self.attack = attack
            self.release = release
            self.amplitude = amplitude
        }
    }

    /// Start: a soft rising two-note (660 → 880 Hz, ~150 ms). Stop: the
    /// same pair falling. Cancel: a low double tick. Pasted: one quiet,
    /// short click.
    public static func notes(for cue: RecordingFeedbackCue) -> [Note] {
        switch cue {
        case .start:
            return [
                Note(frequency: 660, duration: .milliseconds(75)),
                Note(frequency: 880, duration: .milliseconds(75))
            ]
        case .stop:
            return [
                Note(frequency: 880, duration: .milliseconds(75)),
                Note(frequency: 660, duration: .milliseconds(75))
            ]
        case .cancel:
            return [
                Note(frequency: 330, duration: .milliseconds(45), attack: .milliseconds(5), release: .milliseconds(20)),
                Note(frequency: 0, duration: .milliseconds(40), attack: .zero, release: .zero, amplitude: 0),
                Note(frequency: 330, duration: .milliseconds(45), attack: .milliseconds(5), release: .milliseconds(20))
            ]
        case .pasted:
            return [
                Note(frequency: 1_320, duration: .milliseconds(30), attack: .milliseconds(3), release: .milliseconds(20), amplitude: peakAmplitude / 2)
            ]
        }
    }

    /// The whole cue as mono Float32 samples at `sampleRate`.
    public static func samples(for cue: RecordingFeedbackCue) -> [Float] {
        notes(for: cue).flatMap(samples(for:))
    }

    static func samples(for note: Note) -> [Float] {
        let frames = Self.frames(note.duration)
        guard frames > 0 else { return [] }
        let attackFrames = min(frames, Self.frames(note.attack))
        let releaseFrames = min(frames, Self.frames(note.release))
        let phaseStep = 2 * Double.pi * note.frequency / sampleRate
        var out = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            var envelope: Float = 1
            if attackFrames > 0, index < attackFrames {
                envelope = Float(index) / Float(attackFrames)
            }
            let fromEnd = frames - 1 - index
            if releaseFrames > 0, fromEnd < releaseFrames {
                envelope = min(envelope, Float(fromEnd) / Float(releaseFrames))
            }
            out[index] = note.amplitude * envelope * Float(sin(phaseStep * Double(index)))
        }
        return out
    }

    /// The cue as a 16-bit PCM WAV file in memory (RIFF, mono, `sampleRate`).
    public static func wavData(for cue: RecordingFeedbackCue) -> Data {
        wavData(samples: samples(for: cue))
    }

    static func wavData(samples: [Float]) -> Data {
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = UInt32(samples.count * Int(blockAlign))

        var data = Data(capacity: 44 + Int(dataSize))
        data.append(ascii: "RIFF")
        data.append(littleEndian: UInt32(36) + dataSize)
        data.append(ascii: "WAVE")
        data.append(ascii: "fmt ")
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1)) // PCM
        data.append(littleEndian: channels)
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)
        data.append(ascii: "data")
        data.append(littleEndian: dataSize)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            data.append(littleEndian: Int16((clamped * Float(Int16.max)).rounded()))
        }
        return data
    }

    static func frames(_ duration: Duration) -> Int {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return max(0, Int((seconds * sampleRate).rounded()))
    }
}

private extension Data {
    mutating func append(ascii: String) {
        append(contentsOf: Array(ascii.utf8))
    }

    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        let little = value.littleEndian
        Swift.withUnsafeBytes(of: little) { append(contentsOf: $0) }
    }
}
