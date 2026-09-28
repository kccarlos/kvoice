import Foundation
import KvoiceDomain

/// The bundled speech clip the Runtime card's performance test transcribes.
///
/// Provenance: generated once on 2026-09-13 with macOS's own synthesiser —
/// `/usr/bin/say -v Samantha -r 180 -o sample.aiff "<text below>"` — and
/// converted with `afconvert -f WAVE -d LEI16@16000 -c 1` to 16 kHz mono
/// 16-bit PCM (about 11.6 s, 375 KB). Synthetic speech rather than a
/// recording so no voice is shipped, and real speech rather than a tone so
/// the decoder does the same work it does on dictation; a tone would make
/// Whisper hallucinate and finish early, which is exactly the wrong thing to
/// time. Regenerate with the same command if the text changes and keep the
/// file under 400 KB; a test asserts the format and the minimum length.
///
/// Text: "This is the kvoice performance sample. It measures how quickly the
/// speech model transcribes about ten seconds of ordinary spoken English on
/// this Mac, so you can check that the model runs on the expected hardware."
public enum PerformanceSampleAudio {
    public static let resourceName = "PerformanceSample"
    /// The test asserts at least this much audio so the RTF is measured
    /// over a dictation-length clip rather than a one-second blip.
    public static let minimumDuration: Duration = .seconds(8)

    public enum LoadError: Error, Sendable, Equatable {
        case resourceMissing
        case notRIFFWave
        case unsupportedFormat(sampleRate: Double, channels: Int, bitsPerSample: Int)
        case dataChunkMissing
    }

    public static var resourceURL: URL? {
        Bundle.module.url(forResource: resourceName, withExtension: "wav")
    }

    /// The clip as the engine's `AudioRecording` (16 kHz mono Float32).
    public static func load() throws -> AudioRecording {
        guard let url = resourceURL else { throw LoadError.resourceMissing }
        return try decode(Data(contentsOf: url))
    }

    /// Minimal RIFF/WAVE reader for 16-bit PCM: walks the chunks (afconvert
    /// writes a `FLLR` padding chunk before `data`) and refuses anything but
    /// the engine's format, so a mis-converted file fails the test instead of
    /// the runtime.
    static func decode(_ data: Data) throws -> AudioRecording {
        guard data.count >= 12,
              data[0..<4] == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8) else {
            throw LoadError.notRIFFWave
        }
        var sampleRate: Double = 0
        var channels = 0
        var bitsPerSample = 0
        var formatSeen = false
        var pcm: Data?
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(readUInt32(data, at: offset + 4))
            let body = offset + 8
            guard body + size <= data.count else { break }
            switch id {
            case "fmt ":
                guard size >= 16 else { throw LoadError.notRIFFWave }
                let formatTag = readUInt16(data, at: body)
                channels = Int(readUInt16(data, at: body + 2))
                sampleRate = Double(readUInt32(data, at: body + 4))
                bitsPerSample = Int(readUInt16(data, at: body + 14))
                formatSeen = true
                guard formatTag == 1 else {
                    throw LoadError.unsupportedFormat(
                        sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample
                    )
                }
            case "data":
                pcm = data.subdata(in: body..<body + size)
            default:
                break
            }
            // Chunks are word-aligned.
            offset = body + size + (size % 2)
        }
        guard formatSeen else { throw LoadError.notRIFFWave }
        guard sampleRate == 16_000, channels == 1, bitsPerSample == 16 else {
            throw LoadError.unsupportedFormat(
                sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample
            )
        }
        guard let pcm else { throw LoadError.dataChunkMissing }

        let frameCount = pcm.count / 2
        var samples = ContiguousArray<Float>(repeating: 0, count: frameCount)
        var peak: Float = 0
        var clipped = 0
        pcm.withUnsafeBytes { raw in
            for index in 0..<frameCount {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                let sample = Float(value) / 32_768
                samples[index] = sample
                let magnitude = abs(sample)
                if magnitude > peak { peak = magnitude }
                if value == Int16.max || value == Int16.min { clipped += 1 }
            }
        }
        let peakDBFS: Float = peak > 0 ? 20 * log10(peak) : -160
        return AudioRecording(
            samples: samples,
            sampleRate: sampleRate,
            channelCount: channels,
            duration: .seconds(Double(frameCount) / sampleRate),
            peakLevelDBFS: peakDBFS,
            clippedFrameCount: clipped
        )
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }
}
