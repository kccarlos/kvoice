import Foundation

public struct AudioLevelMeasurement: Sendable, Equatable {
    public let rmsDBFS: Float
    public let peakDBFS: Float
    public let clippedFrameCount: Int

    public init(rmsDBFS: Float, peakDBFS: Float, clippedFrameCount: Int) {
        self.rmsDBFS = rmsDBFS
        self.peakDBFS = peakDBFS
        self.clippedFrameCount = clippedFrameCount
    }
}

enum AudioLevelMeter {
    static let silenceFloorDBFS: Float = -120
    static let clippingThreshold: Float = 0.999

    static func measure(_ samples: some Collection<Float>) -> AudioLevelMeasurement? {
        guard !samples.isEmpty else { return nil }

        var sumOfSquares = 0.0
        var peak = 0.0
        var clipped = 0
        for sample in samples {
            guard sample.isFinite else { return nil }
            let magnitude = abs(Double(sample))
            sumOfSquares += magnitude * magnitude
            peak = max(peak, magnitude)
            if sample.magnitude >= clippingThreshold {
                clipped += 1
            }
        }

        let rms = sqrt(sumOfSquares / Double(samples.count))
        return AudioLevelMeasurement(
            rmsDBFS: dbfs(rms),
            peakDBFS: dbfs(peak),
            clippedFrameCount: clipped
        )
    }

    static func dbfs(_ amplitude: Double) -> Float {
        guard amplitude.isFinite, amplitude > 0 else { return silenceFloorDBFS }
        let value = 20 * log10(amplitude)
        guard value.isFinite else { return silenceFloorDBFS }
        return Float(max(Double(silenceFloorDBFS), value))
    }
}
