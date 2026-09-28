import Accelerate
@preconcurrency import CoreML
import Foundation

// The Core ML tensor plumbing the FluidAudio-facing pipelines share, split
// out of `FluidAudioParakeetRuntime.swift` on 2026-09-16 (review request:
// keep the one FluidAudio file to the vendor-facing pipelines). Nothing
// here names a FluidAudio type — only `MLMultiArray` and vDSP — so it is
// unit-tested directly on hand-built arrays, without a model. Rule 1 still
// holds: `MLMultiArray` never crosses a `KvoiceDomain` protocol; this file
// is internal to the adapter package.

/// A tensor a graph produced that cannot be turned into text: the symptom
/// of an fp16/int8 export run off the Neural Engine (SenseVoice's card,
/// Paraformer as measured). Surfaced as an error naming the model and the
/// compute units so a misplaced graph is a diagnosis, never garbage text.
enum CoreMLTensorError: Error, Sendable, Equatable, LocalizedError {
    case nonFiniteOutput(model: String, units: String)

    var errorDescription: String? {
        switch self {
        case let .nonFiniteOutput(model, units):
            return "\(model) produced non-finite output (\(units)); this graph cannot run on these compute units"
        }
    }
}

/// Reads rows of a `[1, R, V]` tensor over its real row stride (Core ML
/// pads rows for the Neural Engine) as Float32, whatever the storage type.
enum LogitRows {
    /// The argmax of each of the first `rows` rows. Refuses a row whose sum
    /// is non-finite (one `vDSP_sve` per row) with an error naming the
    /// model and the compute units, so a graph that cannot run on this
    /// device is an error, never garbage text.
    static func argmax(_ logits: MLMultiArray, rows validRows: Int, model: String, units: String) throws -> [Int] {
        let rows = min(validRows, logits.shape[1].intValue)
        let vocabulary = logits.shape[2].intValue
        var row = [Float](repeating: 0, count: vocabulary)
        var argmax: [Int] = []
        argmax.reserveCapacity(rows)
        for index in 0..<rows {
            try read(logits, row: index, width: vocabulary, into: &row)
            var sum: Float = 0
            row.withUnsafeBufferPointer { vDSP_sve($0.baseAddress!, 1, &sum, vDSP_Length(vocabulary)) }
            guard sum.isFinite else { throw CoreMLTensorError.nonFiniteOutput(model: model, units: units) }
            var best: Float = 0
            var bestIndex: vDSP_Length = 0
            row.withUnsafeBufferPointer { vDSP_maxvi($0.baseAddress!, 1, &best, &bestIndex, vDSP_Length(vocabulary)) }
            argmax.append(Int(bestIndex))
        }
        return argmax
    }

    /// The first `count` rows of `width` values each, as Float32 arrays,
    /// with the same non-finite refusal as `argmax`.
    static func rows(_ array: MLMultiArray, count validCount: Int, width: Int, model: String, units: String) throws -> [[Float]] {
        let count = min(validCount, array.shape[1].intValue)
        var rows: [[Float]] = []
        rows.reserveCapacity(count)
        var row = [Float](repeating: 0, count: width)
        for index in 0..<count {
            try read(array, row: index, width: width, into: &row)
            var sum: Float = 0
            row.withUnsafeBufferPointer { vDSP_sve($0.baseAddress!, 1, &sum, vDSP_Length(width)) }
            guard sum.isFinite else { throw CoreMLTensorError.nonFiniteOutput(model: model, units: units) }
            rows.append(row)
        }
        return rows
    }

    private static func read(_ array: MLMultiArray, row index: Int, width: Int, into row: inout [Float]) throws {
        let stride = array.strides[1].intValue
        try row.withUnsafeMutableBufferPointer { destination in
            switch array.dataType {
            case .float32:
                let source = array.dataPointer.assumingMemoryBound(to: Float32.self) + index * stride
                destination.baseAddress!.update(from: source, count: width)
            case .float16:
                // Half floats as raw bit patterns → fp32 through vImage, so
                // the conversion does not depend on `Float16` (absent on
                // x86_64). `dataPointer` matches the library's own readers.
                var source = vImage_Buffer(
                    data: array.dataPointer + index * stride * 2,
                    height: 1, width: vImagePixelCount(width), rowBytes: width * 2
                )
                var target = vImage_Buffer(
                    data: destination.baseAddress!, height: 1, width: vImagePixelCount(width), rowBytes: width * 4
                )
                let status = vImageConvert_Planar16FtoPlanarF(&source, &target, 0)
                precondition(status == kvImageNoError, "vImage fp16→fp32 conversion failed: \(status)")
            default:
                // Unreachable for these graphs (the exports declare fp16 or
                // fp32 outputs); the boxed path is the safe fallback.
                for offset in 0..<width { destination[offset] = array[index * stride + offset].floatValue }
            }
        }
    }
}

/// Building the fixed-shape Float32 inputs the FunASR graphs take.
enum FeatureTensors {
    /// `features [1, T, dimension]` copied into a zero-filled
    /// `[1, bucket, dimension]` array — the padding to an enumerated
    /// encoder shape both SenseVoice and Paraformer need. Only the first
    /// `frames` rows are copied; `bucket` must be at least `frames`.
    /// `dataPointer` rather than `withUnsafeMutableBytes`, matching the
    /// library's own managers (parity with their decode is what was
    /// checked); both spellings are current on macOS 15.
    static func zeroPadded(_ features: MLMultiArray, frames: Int, bucket: Int, dimension: Int) throws -> MLMultiArray {
        precondition(bucket >= frames, "the bucket must hold every frame")
        let padded = try MLMultiArray(shape: [1, NSNumber(value: bucket), NSNumber(value: dimension)], dataType: .float32)
        let target = padded.dataPointer.assumingMemoryBound(to: Float32.self)
        memset(target, 0, bucket * dimension * MemoryLayout<Float32>.size)
        let count = frames * dimension
        if features.dataType == .float32 {
            memcpy(target, features.dataPointer, count * MemoryLayout<Float32>.size)
        } else {
            // Unreachable for the shipped packages: both preprocessors
            // declare fp32 `features`. Kept as the library keeps it, for a
            // re-export.
            for index in 0..<count { target[index] = features[index].floatValue }
        }
        return padded
    }

    /// A one-element Int32 tensor (`speech_lengths`, `language`, `textnorm`, …).
    static func scalar(_ value: Int32) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1], dataType: .int32)
        array[0] = NSNumber(value: value)
        return array
    }
}
