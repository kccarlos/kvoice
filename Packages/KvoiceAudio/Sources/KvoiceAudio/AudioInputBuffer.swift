@preconcurrency import AVFoundation
import Foundation
import KvoiceDomain

/// The small amount of format metadata that is allowed to cross the audio
/// adapter boundary.  Audio is always represented as Float32 samples after a
/// tap snapshot; the sample rate and channel count remain the hardware values
/// until the converter produces the transcription format.
public struct AudioInputFormat: Sendable, Equatable {
    public let sampleRate: Double
    public let channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public var isValid: Bool {
        sampleRate.isFinite && sampleRate > 0 && channelCount > 0
    }
}

/// An immutable snapshot of one input-tap buffer.
///
/// Samples are interleaved (`frame0-channel0, frame0-channel1, ...`).  The
/// snapshot is intentionally a value type so the realtime AVAudioEngine block
/// never hands a mutable AVAudioPCMBuffer to an actor or to a later task.
public struct AudioInputBuffer: Sendable, Equatable {
    public let format: AudioInputFormat
    public let frameLength: Int
    public let samples: ContiguousArray<Float>

    public init(
        format: AudioInputFormat,
        samples: ContiguousArray<Float>,
        frameLength: Int? = nil
    ) {
        self.format = format
        self.samples = samples
        self.frameLength = frameLength ?? {
            guard format.channelCount > 0 else { return 0 }
            return samples.count / format.channelCount
        }()
    }

    public init(
        sampleRate: Double,
        channelCount: Int,
        samples: [Float],
        frameLength: Int? = nil
    ) {
        self.init(
            format: AudioInputFormat(sampleRate: sampleRate, channelCount: channelCount),
            samples: ContiguousArray(samples),
            frameLength: frameLength
        )
    }

    /// Structural validity is checked before conversion.  A malformed frame
    /// length must never be allowed to make the converter read beyond a tap
    /// snapshot's storage.
    public var isStructurallyValid: Bool {
        format.isValid
            && frameLength >= 0
            && frameLength <= Int.max / max(format.channelCount, 1)
            && samples.count == frameLength * format.channelCount
    }

    public var containsOnlyFiniteSamples: Bool {
        samples.allSatisfy(\.isFinite)
    }

    public var isValid: Bool {
        isStructurallyValid && containsOnlyFiniteSamples
    }

    /// Creates a value snapshot from an AVAudioEngine input tap buffer.
    ///
    /// The v1 capture boundary accepts the Float32 format emitted by
    /// AVAudioEngine's input node.  Unsupported native formats fail closed;
    /// they are never coerced with a lossy or implicit conversion here.
    internal init(avAudioBuffer: AVAudioPCMBuffer) throws {
        let nativeFormat = avAudioBuffer.format
        guard nativeFormat.commonFormat == .pcmFormatFloat32,
              nativeFormat.sampleRate.isFinite,
              nativeFormat.sampleRate > 0,
              nativeFormat.channelCount > 0
        else {
            throw KVoiceError(code: .audioConversionFailed, retryable: false)
        }

        let frameLength = Int(avAudioBuffer.frameLength)
        let channelCount = Int(nativeFormat.channelCount)
        guard frameLength >= 0,
              frameLength <= Int.max / channelCount,
              let channelData = avAudioBuffer.floatChannelData
        else {
            throw KVoiceError(code: .audioConversionFailed, retryable: false)
        }

        var samples = ContiguousArray<Float>()
        samples.reserveCapacity(frameLength * channelCount)
        if nativeFormat.isInterleaved {
            let data = channelData[0]
            for index in 0..<(frameLength * channelCount) {
                samples.append(data[index])
            }
        } else {
            for frame in 0..<frameLength {
                for channel in 0..<channelCount {
                    samples.append(channelData[channel][frame])
                }
            }
        }

        self.init(
            format: AudioInputFormat(
                sampleRate: nativeFormat.sampleRate,
                channelCount: channelCount
            ),
            samples: samples,
            frameLength: frameLength
        )

        guard isValid else {
            throw KVoiceError(code: .sttInvalidAudio, retryable: false)
        }
    }
}
