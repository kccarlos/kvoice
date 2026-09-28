@preconcurrency import AVFoundation
import Foundation
import KvoiceDomain

/// Converts one hardware-format tap snapshot at a time and flushes any
/// converter tail on `finish`.  Implementations are reference types because
/// AVAudioConverter is stateful; callers serialize access to an instance.
public protocol AudioConverterAdapter: AnyObject, Sendable {
    var outputSampleRate: Double { get }
    var outputChannelCount: Int { get }

    func convert(_ input: AudioInputBuffer) throws -> ContiguousArray<Float>
    func finish() throws -> ContiguousArray<Float>
}

public protocol AudioConverterFactory: Sendable {
    func makeConverter(for inputFormat: AudioInputFormat) throws -> any AudioConverterAdapter
}

public struct AVAudioConverterFactory: AudioConverterFactory, Sendable {
    public init() {}

    public func makeConverter(for inputFormat: AudioInputFormat) throws -> any AudioConverterAdapter {
        try AVAudioConverterAdapter(inputFormat: inputFormat)
    }
}

private final class ConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var consumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else {
            inputStatus.pointee = .noDataNow
            return nil
        }
        consumed = true
        inputStatus.pointee = .haveData
        return buffer
    }
}

/// Production mono 16 kHz Float32 converter backed by AVAudioConverter.
public final class AVAudioConverterAdapter: AudioConverterAdapter, @unchecked Sendable {
    public let outputSampleRate: Double = 16_000
    public let outputChannelCount: Int = 1

    private let inputFormat: AudioInputFormat
    private let converter: AVAudioConverter
    private let sourceAVFormat: AVAudioFormat
    private let outputAVFormat: AVAudioFormat

    public init(inputFormat: AudioInputFormat) throws {
        guard inputFormat.isValid else {
            throw KVoiceError(code: .audioInputUnavailable, retryable: false)
        }

        guard let sourceAVFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: AVAudioChannelCount(inputFormat.channelCount),
            interleaved: false
        ),
        let outputAVFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: sourceAVFormat, to: outputAVFormat)
        else {
            throw KVoiceError(code: .audioConversionFailed, retryable: false)
        }

        self.inputFormat = inputFormat
        self.sourceAVFormat = sourceAVFormat
        self.outputAVFormat = outputAVFormat
        self.converter = converter
    }

    public func convert(_ input: AudioInputBuffer) throws -> ContiguousArray<Float> {
        guard input.format == inputFormat, input.isValid else {
            throw KVoiceError(code: .audioInputChanged, retryable: false)
        }
        guard input.frameLength > 0 else { return [] }

        let sourceBuffer = try makeSourceBuffer(from: input)
        let outputCapacity = outputCapacity(for: input.frameLength)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputAVFormat,
            frameCapacity: AVAudioFrameCount(outputCapacity)
        ) else {
            throw KVoiceError(code: .audioConversionFailed, retryable: false)
        }

        let inputProvider = ConverterInputProvider(buffer: sourceBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) {
            _, inputStatus in
            inputProvider.next(inputStatus)
        }

        if status == .error || conversionError != nil {
            throw KVoiceError(code: .audioConversionFailed, retryable: false)
        }
        return try copyOutput(from: outputBuffer)
    }

    public func finish() throws -> ContiguousArray<Float> {
        var result = ContiguousArray<Float>()
        // AVAudioConverter can produce a final priming/tail buffer after the
        // input block reports endOfStream.  Keep a strict iteration bound so a
        // broken platform converter cannot spin indefinitely on stop.
        for _ in 0..<64 {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputAVFormat,
                frameCapacity: 4096
            ) else {
                throw KVoiceError(code: .audioConversionFailed, retryable: false)
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) {
                _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }

            if status == .error || conversionError != nil {
                throw KVoiceError(code: .audioConversionFailed, retryable: false)
            }
            result.append(contentsOf: try copyOutput(from: outputBuffer))

            switch status {
            case .endOfStream:
                return result
            case .haveData, .inputRanDry:
                // Continue until the converter acknowledges the end marker.
                continue
            case .error:
                throw KVoiceError(code: .audioConversionFailed, retryable: false)
            @unknown default:
                throw KVoiceError(code: .audioConversionFailed, retryable: false)
            }
        }

        throw KVoiceError(code: .audioConversionFailed, retryable: false)
    }

    private func makeSourceBuffer(from input: AudioInputBuffer) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: sourceAVFormat,
            frameCapacity: AVAudioFrameCount(input.frameLength)
        ),
        let channelData = buffer.floatChannelData
        else {
            throw KVoiceError(code: .audioConversionFailed, retryable: false)
        }

        buffer.frameLength = AVAudioFrameCount(input.frameLength)
        for frame in 0..<input.frameLength {
            for channel in 0..<input.format.channelCount {
                channelData[channel][frame] = input.samples[frame * input.format.channelCount + channel]
            }
        }
        return buffer
    }

    private func outputCapacity(for inputFrames: Int) -> Int {
        let ratio = outputSampleRate / inputFormat.sampleRate
        let estimated = Double(inputFrames) * ratio
        guard estimated.isFinite, estimated >= 0 else { return 4096 }
        return max(4096, min(Int.max / 2, Int(ceil(estimated)) + 32))
    }

    private func copyOutput(from buffer: AVAudioPCMBuffer) throws -> ContiguousArray<Float> {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.channelCount == 1,
              let channelData = buffer.floatChannelData
        else {
            throw KVoiceError(code: .audioConversionFailed, retryable: false)
        }
        let frameLength = Int(buffer.frameLength)
        guard frameLength >= 0 else {
            throw KVoiceError(code: .audioConversionFailed, retryable: false)
        }

        var output = ContiguousArray<Float>()
        output.reserveCapacity(frameLength)
        for frame in 0..<frameLength {
            output.append(channelData[0][frame])
        }
        guard output.allSatisfy(\.isFinite) else {
            throw KVoiceError(code: .sttInvalidAudio, retryable: false)
        }
        return output
    }
}
