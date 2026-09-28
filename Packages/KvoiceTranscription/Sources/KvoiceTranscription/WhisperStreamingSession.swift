import Foundation
import KvoiceDomain

/// Tunables for the ADR-017 streaming session. Defaults follow the ADR: a
/// pass after at least one second of new audio, a window of at most 28 s,
/// and LocalAgreement-2.
public struct WhisperStreamingPolicy: Sendable, Equatable {
    public static let sampleRate = 16_000.0

    /// New audio required before another pass is worth running.
    public var minimumNewAudioSeconds: Double
    /// The uncommitted window is cut once it grows past this, whether or not
    /// the hypotheses agree, so a pass never exceeds Whisper's 30 s context.
    public var maximumWindowSeconds: Double
    /// How many consecutive passes must agree on a segment before it is
    /// committed. `2` is LocalAgreement-2.
    public var agreementPasses: Int
    /// Whether a forced cut may prefer a silence found by the energy VAD.
    /// Segmentation only; the session never ends a recording (FR-AUD-007).
    public var voiceActivityDetectionEnabled: Bool
    /// Frame length and floor for the energy VAD.
    public var vadFrameSeconds: Double
    public var vadSilenceThresholdDBFS: Float
    /// A silence must be at least this long to count as a cut point.
    public var vadMinimumSilenceSeconds: Double
    /// ADR-022 slice 5: the silence / quiet thresholds the session's gate
    /// reads (`beginPass`, `apply`), from the developer defaults.
    public var speechGate: SpeechGate.Thresholds

    public init(
        minimumNewAudioSeconds: Double = 1.0,
        maximumWindowSeconds: Double = 28.0,
        agreementPasses: Int = 2,
        voiceActivityDetectionEnabled: Bool = true,
        vadFrameSeconds: Double = 0.1,
        vadSilenceThresholdDBFS: Float = -45,
        vadMinimumSilenceSeconds: Double = 0.3,
        speechGate: SpeechGate.Thresholds = .compiled
    ) {
        self.minimumNewAudioSeconds = max(0.1, minimumNewAudioSeconds)
        self.maximumWindowSeconds = min(30, max(5, maximumWindowSeconds))
        self.agreementPasses = max(1, agreementPasses)
        self.voiceActivityDetectionEnabled = voiceActivityDetectionEnabled
        self.vadFrameSeconds = max(0.02, vadFrameSeconds)
        self.vadSilenceThresholdDBFS = vadSilenceThresholdDBFS
        self.vadMinimumSilenceSeconds = max(vadFrameSeconds, vadMinimumSilenceSeconds)
        self.speechGate = speechGate
    }
}

/// The audio and text state of one streaming dictation.
///
/// The session owns the *uncommitted window*: the audio since the last
/// committed boundary. Each pass decodes that window; the resulting segments
/// are compared with the previous pass over the same window, and the prefix
/// of segments that the last `agreementPasses` hypotheses agree on is
/// committed. Committing appends the text to `committedText` and drops the
/// audio up to the committed segment's end, so the next pass starts there.
/// Text that has not been agreed is `tentativeText`; the HUD shows both.
///
/// Silence is gated the same way as the batch pass (`SpeechGate`): a window
/// that never rises above `SpeechGate.silencePeakThresholdDBFS` is not decoded
/// at all — Whisper hallucinates "Thank you." on it — and a segment whose text
/// is a known silence hallucination over quiet audio is dropped before it can
/// be shown or committed. The quiet check is per segment, using the segment's
/// timestamps against the pass window, so a "Thank you." over the silent tail
/// of an otherwise loud window (the user stopped talking but kept the key
/// held) is dropped while a spoken one over audible audio is kept. The energy
/// VAD below is unrelated: it only chooses where a forced cut falls and never
/// ends a recording (FR-AUD-007).
///
/// This is deliberately a value type with no runtime reference so it can be
/// tested pass by pass with scripted results. It never sees the microphone
/// and never decides when a recording ends.
public struct WhisperStreamingSession: Sendable, Equatable {
    public let policy: WhisperStreamingPolicy

    /// Audio since the last committed boundary, 16 kHz mono.
    public private(set) var window: ContiguousArray<Float> = []
    /// Absolute offset of `window[0]` in the recording, in seconds.
    public private(set) var windowStartSeconds: Double = 0
    public private(set) var committedText = ""
    public private(set) var tentativeText = ""
    public private(set) var passCount = 0
    /// Passes `beginPass` refused because the whole window was silent.
    public private(set) var skippedSilentPassCount = 0
    /// Segments `apply` dropped as silence hallucinations over quiet audio.
    /// A scalar for diagnostics; the text is never kept.
    public private(set) var droppedHallucinationSegmentCount = 0

    private var samplesSinceLastPass = 0
    private var passInFlight = false
    /// Peak level of the audio `beginPass` handed out, for the hallucination
    /// check in `apply` when a segment carries no usable timestamps. Full
    /// scale until a pass has begun so a result applied without one is never
    /// gated.
    private var passPeakLevelDBFS: Float = 0
    /// Normalised segment texts of consecutive passes over the current
    /// window start, newest last; cleared whenever the window is cut.
    private var hypotheses: [[String]] = []

    public init(policy: WhisperStreamingPolicy = WhisperStreamingPolicy()) {
        self.policy = policy
    }

    /// Committed plus tentative text, joined with CJK-aware spacing.
    public var partialText: String {
        Self.join(committedText, tentativeText)
    }

    public var windowSeconds: Double {
        Double(window.count) / WhisperStreamingPolicy.sampleRate
    }

    public var hasAudio: Bool { !window.isEmpty }

    // MARK: Audio

    public mutating func append(_ samples: ContiguousArray<Float>) {
        guard !samples.isEmpty else { return }
        window.append(contentsOf: samples)
        samplesSinceLastPass += samples.count
    }

    /// True when enough new audio has arrived since the last pass began and
    /// no pass is running.
    public var isPassDue: Bool {
        guard !passInFlight else { return false }
        let threshold = Int(policy.minimumNewAudioSeconds * WhisperStreamingPolicy.sampleRate)
        return samplesSinceLastPass >= threshold && !window.isEmpty
    }

    /// Takes the audio for the next pass and marks the pass as running.
    /// Returns `nil` when no pass is due, or when the whole uncommitted window
    /// (which includes every new sample) is below the silence threshold: that
    /// audio is consumed without a runtime call, so a held key over a quiet
    /// room costs nothing and cannot surface "Thank you.".
    public mutating func beginPass() -> [Float]? {
        guard isPassDue else { return nil }
        let peak = SpeechGate.peakLevelDBFS(of: window)
        if peak <= policy.speechGate.silencePeakDBFS {
            skipSilentPass()
            return nil
        }
        passInFlight = true
        passPeakLevelDBFS = peak
        samplesSinceLastPass = 0
        passCount += 1
        return Array(window)
    }

    /// A silent window carries no hypothesis, so it is trimmed to one
    /// `minimumNewAudioSeconds` of context instead of accumulating: otherwise
    /// a minute of silence before the first word would hand the first real
    /// pass a window past Whisper's 30 s context.
    private mutating func skipSilentPass() {
        skippedSilentPassCount += 1
        samplesSinceLastPass = 0
        let keep = Int(policy.minimumNewAudioSeconds * WhisperStreamingPolicy.sampleRate)
        if window.count > keep {
            cutWindow(atSeconds: Double(window.count - keep) / WhisperStreamingPolicy.sampleRate)
        } else {
            hypotheses.removeAll()
        }
        tentativeText = ""
    }

    /// Abandons a pass that did not complete (cancelled or failed). The
    /// audio it took is still in the window, so the next pass covers it.
    public mutating func abandonPass() {
        passInFlight = false
    }

    // MARK: Hypotheses

    /// Applies the runtime result for the window handed out by `beginPass`,
    /// commits what the hypotheses agree on, and returns the new partial
    /// text. `windowSampleCount` is the length of the array `beginPass`
    /// returned, so a cut never removes audio the pass did not see.
    ///
    /// Segments that `SpeechGate` recognises as a silence hallucination over
    /// quiet audio are dropped here, before they can become tentative text or
    /// take part in agreement. The quiet check reads the peak of the audio
    /// the segment spans (its timestamps are relative to the pass window);
    /// a segment without usable timestamps falls back to the pass's peak.
    @discardableResult
    public mutating func apply(_ result: WhisperRuntimeResult, windowSampleCount: Int) -> String {
        passInFlight = false
        let passSamples = window.prefix(min(windowSampleCount, window.count))
        var segments: [(segment: WhisperRuntimeSegment, text: String)] = []
        for segment in result.segments {
            guard let text = Self.normalise(segment.text) else { continue }
            let peak = segment.end > segment.start
                ? SpeechGate.peakLevelDBFS(
                    of: passSamples,
                    in: TranscriptSegment(start: segment.start, end: segment.end, text: ""),
                    sampleRate: WhisperStreamingPolicy.sampleRate
                )
                : passPeakLevelDBFS
            if SpeechGate.isLikelyHallucination(text, peakLevelDBFS: peak, thresholds: policy.speechGate) {
                droppedHallucinationSegmentCount += 1
                continue
            }
            segments.append((segment: segment, text: text))
        }
        let texts = segments.map(\.text)
        hypotheses.append(texts)
        if hypotheses.count > policy.agreementPasses {
            hypotheses.removeFirst(hypotheses.count - policy.agreementPasses)
        }

        var agreedCount = 0
        if hypotheses.count >= policy.agreementPasses {
            agreedCount = texts.count
            for previous in hypotheses.dropLast() {
                let common = zip(previous, texts).prefix { $0 == $1 }.count
                agreedCount = min(agreedCount, common)
            }
        }

        let seenSeconds = Double(min(windowSampleCount, window.count)) / WhisperStreamingPolicy.sampleRate
        if agreedCount > 0 {
            commit(segments.prefix(agreedCount).map { $0 }, seenSeconds: seenSeconds)
            tentativeText = Self.joinTexts(segments.dropFirst(agreedCount).map(\.text))
        } else if seenSeconds >= policy.maximumWindowSeconds {
            forceCut(segments, seenSeconds: seenSeconds)
        } else {
            tentativeText = Self.joinTexts(texts)
        }
        return partialText
    }

    private mutating func commit(
        _ agreed: [(segment: WhisperRuntimeSegment, text: String)],
        seenSeconds: Double
    ) {
        guard let last = agreed.last else { return }
        for item in agreed {
            committedText = Self.join(committedText, item.text)
        }
        let endSeconds = min(max(Self.seconds(last.segment.end), 0), seenSeconds)
        cutWindow(atSeconds: endSeconds)
    }

    /// The window has grown past the policy limit without agreement. Commit
    /// every segment but the last when there are several; otherwise commit
    /// the whole hypothesis and cut at a silence (or near the end of what the
    /// pass saw), so the next pass starts on fresh audio.
    private mutating func forceCut(
        _ segments: [(segment: WhisperRuntimeSegment, text: String)],
        seenSeconds: Double
    ) {
        if segments.count >= 2 {
            let keep = segments.dropLast()
            for item in keep {
                committedText = Self.join(committedText, item.text)
            }
            tentativeText = segments.last?.text ?? ""
            let end = Self.seconds(keep.last!.segment.end)
            cutWindow(atSeconds: min(max(end, 0), seenSeconds))
            return
        }

        for item in segments {
            committedText = Self.join(committedText, item.text)
        }
        tentativeText = ""
        let fallback = max(seenSeconds - 2, seenSeconds * 0.5)
        let cut = policy.voiceActivityDetectionEnabled
            ? (EnergyVoiceActivity.lastSilenceCenter(
                in: window,
                seenSeconds: seenSeconds,
                notBefore: seenSeconds * 0.5,
                policy: policy
            ) ?? fallback)
            : fallback
        cutWindow(atSeconds: cut)
    }

    private mutating func cutWindow(atSeconds seconds: Double) {
        let samples = min(window.count, max(0, Int(seconds * WhisperStreamingPolicy.sampleRate)))
        guard samples > 0 else {
            hypotheses.removeAll()
            return
        }
        window.removeFirst(samples)
        windowStartSeconds += Double(samples) / WhisperStreamingPolicy.sampleRate
        // Audio not yet decoded by any pass stays counted as new.
        samplesSinceLastPass = min(samplesSinceLastPass, window.count)
        hypotheses.removeAll()
    }

    // MARK: Text helpers

    static func normalise(_ text: String) -> String? {
        let collapsed = text
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func joinTexts(_ texts: [String]) -> String {
        texts.reduce("") { join($0, $1) }
    }

    /// Joins two runs of text with a space unless the boundary is CJK on both
    /// sides, so "你好" + "世界" stays "你好世界" and "hello" + "world" gets a space.
    static func join(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        if let last = lhs.unicodeScalars.last, let first = rhs.unicodeScalars.first,
           isCJK(last), isCJK(first) || isPunctuation(first) {
            return lhs + rhs
        }
        return lhs + " " + rhs
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// A frame-energy voice activity detector used only to choose where a forced
/// window cut may fall. It never stops a recording.
public enum EnergyVoiceActivity {
    /// Centre, in seconds, of the last silent run of at least
    /// `vadMinimumSilenceSeconds` that ends before `seenSeconds` and starts
    /// at or after `notBefore`, or `nil` when there is none.
    public static func lastSilenceCenter(
        in samples: ContiguousArray<Float>,
        seenSeconds: Double,
        notBefore: Double,
        policy: WhisperStreamingPolicy
    ) -> Double? {
        let frameLength = max(1, Int(policy.vadFrameSeconds * WhisperStreamingPolicy.sampleRate))
        let limit = min(samples.count, Int(seenSeconds * WhisperStreamingPolicy.sampleRate))
        guard limit >= frameLength else { return nil }
        let frameCount = limit / frameLength
        let minimumRun = max(1, Int((policy.vadMinimumSilenceSeconds / policy.vadFrameSeconds).rounded(.up)))

        var best: (start: Int, end: Int)?
        var runStart: Int?
        for index in 0..<frameCount {
            let lower = index * frameLength
            let upper = lower + frameLength
            var energy: Float = 0
            for sample in samples[lower..<upper] {
                energy += sample * sample
            }
            let rms = (energy / Float(frameLength)).squareRoot()
            let dbfs = rms > 0 ? 20 * log10(rms) : -160
            if dbfs < policy.vadSilenceThresholdDBFS {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                if index - start >= minimumRun { best = (start, index) }
                runStart = nil
            }
        }
        if let start = runStart, frameCount - start >= minimumRun {
            best = (start, frameCount)
        }
        guard let best else { return nil }
        let center = (Double(best.start + best.end) / 2) * policy.vadFrameSeconds
        return center >= notBefore ? center : nil
    }
}
