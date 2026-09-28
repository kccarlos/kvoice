import AVFoundation
import Foundation
import Observation

/// Playback state for a stored history recording: play/pause, scrub, and a
/// 20 Hz progress read while playing.
///
/// One player per detail view; `load(_:)` swaps the file when the selection
/// changes and stops whatever was playing.  The waveform is decoded
/// separately by the view model (it needs the samples; playback does not).
@Observable
@MainActor
public final class HistoryAudioPlayer {
    public private(set) var isPlaying = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var loadedURL: URL?
    public private(set) var failedToLoad = false

    private var player: AVAudioPlayer?
    private var delegate: CompletionDelegate?
    private var progressTask: Task<Void, Never>?

    public init() {}

    public var progress: Double {
        duration > 0 ? min(1, max(0, currentTime / duration)) : 0
    }

    public func load(_ url: URL?) {
        stop()
        player = nil
        delegate = nil
        loadedURL = url
        failedToLoad = false
        currentTime = 0
        duration = 0
        guard let url else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            let delegate = CompletionDelegate { [weak self] in
                Task { @MainActor in self?.playbackFinished() }
            }
            player.delegate = delegate
            player.prepareToPlay()
            self.player = player
            self.delegate = delegate
            duration = player.duration
        } catch {
            failedToLoad = true
        }
    }

    public func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    public func play() {
        guard let player, !isPlaying else { return }
        if player.currentTime >= player.duration {
            player.currentTime = 0
        }
        guard player.play() else { return }
        isPlaying = true
        startProgressUpdates()
    }

    public func pause() {
        guard isPlaying else { return }
        player?.pause()
        isPlaying = false
        stopProgressUpdates()
        currentTime = player?.currentTime ?? currentTime
    }

    public func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        stopProgressUpdates()
        currentTime = 0
    }

    /// Scrubs to a fraction of the duration.  Works while paused or playing.
    public func seek(toProgress fraction: Double) {
        guard let player, duration > 0 else { return }
        let time = min(max(0, fraction), 1) * duration
        player.currentTime = time
        currentTime = time
    }

    private func playbackFinished() {
        isPlaying = false
        stopProgressUpdates()
        currentTime = duration
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, let player = self.player, self.isPlaying else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    private func stopProgressUpdates() {
        progressTask?.cancel()
        progressTask = nil
    }

    private final class CompletionDelegate: NSObject, AVAudioPlayerDelegate {
        private let onFinish: @Sendable () -> Void

        init(onFinish: @escaping @Sendable () -> Void) {
            self.onFinish = onFinish
        }

        func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
            onFinish()
        }
    }
}
