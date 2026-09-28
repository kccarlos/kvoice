import Foundation
import XCTest
import KvoiceDomain
@testable import KvoiceAudio

/// ADR-017: the streaming input path forwards converted 16 kHz mono samples to
/// an installed sink, in capture order, while the recording continues, and
/// never after stop or cancel. The final `AudioRecording` is unaffected.
final class StreamingChunkSinkTests: XCTestCase {
    func testSinkInstalledBeforeStartReceivesEveryAcceptedSampleInOrder() async throws {
        let engine = PassthroughAudioEngine()
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: IdentityConverterFactory(),
            permissionProvider: AlwaysGrantedPermission(),
            maximumDuration: .seconds(10)
        )
        let jobID = UUID()
        let received = ChunkCollector()

        await service.setStreamingChunkSink(jobID: jobID) { chunk in
            await received.append(chunk)
        }
        try await service.start(jobID: jobID) { _ in }

        let first: [Float] = [0.1, 0.2, 0.3]
        let second: [Float] = [0.4, 0.5]
        let third: [Float] = [0.6]
        engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: first))
        engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: second))
        engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: third))
        try await waitUntil { await received.samples.count == 6 }

        let samples = await received.samples
        XCTAssertEqual(samples, first + second + third, "chunks arrive in capture order")
        let chunks = await received.chunks
        XCTAssertTrue(chunks.allSatisfy(\.isEngineCompatible))

        // Pad to the minimum recording length; the recording still carries
        // every sample, independent of what the sink saw.
        engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: Array(repeating: 0, count: 200)))
        let recording = try await service.stop(jobID: jobID)
        XCTAssertEqual(recording.samples.count, 206)
        XCTAssertEqual(Array(recording.samples.prefix(6)), first + second + third)

        // Nothing is delivered after stop, even if a late buffer arrives.
        let countAtStop = await received.samples.count
        engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: [0.9]))
        await Task.yield()
        await Task.yield()
        let countAfter = await received.samples.count
        XCTAssertEqual(countAfter, countAtStop)
    }

    func testSinkInstalledAfterStartCanBeRemovedAndCancelStopsDelivery() async throws {
        let engine = PassthroughAudioEngine()
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: IdentityConverterFactory(),
            permissionProvider: AlwaysGrantedPermission(),
            maximumDuration: .seconds(10)
        )
        let jobID = UUID()
        let received = ChunkCollector()

        try await service.start(jobID: jobID) { _ in }
        // Buffers before a sink exists are not retained for it.
        engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: [0.01]))
        await service.setStreamingChunkSink(jobID: jobID) { chunk in
            await received.append(chunk)
        }
        engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: [0.5, 0.6]))
        try await waitUntil { await received.samples.count == 2 }
        let afterInstall = await received.samples
        XCTAssertEqual(afterInstall, [0.5, 0.6])

        await service.setStreamingChunkSink(jobID: jobID, nil)
        engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: [0.7]))
        await Task.yield()
        await Task.yield()
        let afterRemoval = await received.samples
        XCTAssertEqual(afterRemoval, [0.5, 0.6], "a removed sink receives nothing")

        await service.setStreamingChunkSink(jobID: jobID) { chunk in
            await received.append(chunk)
        }
        await service.cancel(jobID: jobID)
        engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: [0.8]))
        await Task.yield()
        await Task.yield()
        let afterCancel = await received.samples
        XCTAssertEqual(afterCancel, [0.5, 0.6], "cancel tears the pipeline down")
        let recording = await service.isRecording
        XCTAssertFalse(recording)
    }

    func testSinkForAnotherJobIsNeverArmed() async throws {
        let engine = PassthroughAudioEngine()
        let service = AVAudioCaptureService(
            engine: engine,
            converterFactory: IdentityConverterFactory(),
            permissionProvider: AlwaysGrantedPermission(),
            maximumDuration: .seconds(10)
        )
        let received = ChunkCollector()
        await service.setStreamingChunkSink(jobID: UUID()) { chunk in
            await received.append(chunk)
        }
        let jobID = UUID()
        try await service.start(jobID: jobID) { _ in }
        engine.emit(.init(sampleRate: 16_000, channelCount: 1, samples: Array(repeating: 0.2, count: 200)))
        await Task.yield()
        await Task.yield()
        let samples = await received.samples
        XCTAssertTrue(samples.isEmpty)
        _ = try await service.stop(jobID: jobID)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition did not become true within \(timeout)")
    }
}

private actor ChunkCollector {
    private(set) var chunks: [AudioSampleChunk] = []

    var samples: [Float] {
        chunks.flatMap { Array($0.samples) }
    }

    func append(_ chunk: AudioSampleChunk) {
        chunks.append(chunk)
    }
}

private struct AlwaysGrantedPermission: MicrophonePermissionProviding, Sendable {
    func authorization() async -> PermissionAuthorization { .granted }
    func requestAccess() async -> PermissionAuthorization { .granted }
}

private final class PassthroughAudioEngine: AudioEngineAdapter, @unchecked Sendable {
    let inputFormat: AudioInputFormat? = AudioInputFormat(sampleRate: 16_000, channelCount: 1)
    let inputDeviceName: String? = "Test Input"
    var onEvent: (@Sendable (AudioEngineAdapterEvent) -> Void)?
    private let lock = NSLock()
    private var handler: (@Sendable (AudioInputBuffer) -> Void)?

    func installInputTap(
        bufferSize _: Int,
        format _: AudioInputFormat,
        handler: @escaping @Sendable (AudioInputBuffer) -> Void
    ) throws {
        lock.withLock { self.handler = handler }
    }

    func removeInputTap() {
        lock.withLock { handler = nil }
    }

    func start() throws {}
    func stop() {}

    func emit(_ input: AudioInputBuffer) {
        lock.withLock { handler }?(input)
    }
}

private struct IdentityConverterFactory: AudioConverterFactory {
    func makeConverter(for _: AudioInputFormat) throws -> any AudioConverterAdapter {
        IdentityConverter()
    }
}

private final class IdentityConverter: AudioConverterAdapter, @unchecked Sendable {
    let outputSampleRate: Double = 16_000
    let outputChannelCount: Int = 1

    func convert(_ input: AudioInputBuffer) throws -> ContiguousArray<Float> {
        input.samples
    }

    func finish() throws -> ContiguousArray<Float> {
        []
    }
}
