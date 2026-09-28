import AVFoundation
import Foundation
import KvoiceDomain

/// Decodes an audio or video file to the transcription boundary format:
/// 16 kHz mono Float32 (`AudioRecording`).
///
/// One path for every container: `AVAssetReader` with an audio-mix output
/// asked for the target format directly, so wav, mp3, m4a, aiff, aac, flac,
/// caf, mp4, and mov all go through the same resampler and a video file
/// simply contributes its audio track.  This is also what reads a stored
/// history WAV back for the waveform and for Retranscribe.
///
/// AVFoundation stays inside this type; nothing vendor-specific crosses the
/// `AudioRecording` boundary.
public enum MediaFileDecoder {
    public static let targetSampleRate: Double = 16_000

    /// File extensions the app registers as openable (`CFBundleDocumentTypes`).
    public static let supportedExtensions: [String] = [
        "wav", "mp3", "m4a", "aiff", "aif", "mp4", "mov", "aac", "flac", "caf"
    ]

    public enum DecodeError: Error, Equatable {
        case noAudioTrack
        case unreadable
        case empty
    }

    /// Decodes the whole file.  Long files are read in chunks; nothing is
    /// held beyond the sample array itself.
    public static func decode(_ url: URL) async throws -> AudioRecording {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw DecodeError.unreadable
        }
        guard !tracks.isEmpty else { throw DecodeError.noAudioTrack }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw DecodeError.unreadable
        }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DecodeError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw DecodeError.unreadable }

        var samples = ContiguousArray<Float>()
        var peak: Float = 0
        var clipped = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw DecodeError.unreadable }
            for sample in chunk {
                let magnitude = abs(sample)
                if magnitude > peak { peak = magnitude }
                if magnitude >= 1 { clipped += 1 }
            }
            samples.append(contentsOf: chunk)
        }
        if reader.status == .failed { throw DecodeError.unreadable }
        guard !samples.isEmpty else { throw DecodeError.empty }

        let seconds = Double(samples.count) / targetSampleRate
        return AudioRecording(
            samples: samples,
            sampleRate: targetSampleRate,
            channelCount: 1,
            duration: .seconds(seconds),
            peakLevelDBFS: peak > 0 ? 20 * log10(peak) : -160,
            clippedFrameCount: clipped
        )
    }

    /// Peak amplitude per bin for a waveform strip; `bins` values in `0...1`.
    public static func waveform(of recording: AudioRecording, bins: Int) -> [Float] {
        guard bins > 0, !recording.samples.isEmpty else { return [] }
        let perBin = max(1, recording.samples.count / bins)
        var result: [Float] = []
        result.reserveCapacity(bins)
        var index = 0
        while index < recording.samples.count, result.count < bins {
            let end = min(index + perBin, recording.samples.count)
            var peak: Float = 0
            for sample in recording.samples[index..<end] {
                let magnitude = abs(sample)
                if magnitude > peak { peak = magnitude }
            }
            result.append(min(1, peak))
            index = end
        }
        return result
    }
}
