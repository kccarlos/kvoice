import Foundation
import KvoiceDomain
import KvoiceTranscription

/// Downloads one manifest-described artifact into a caller-owned staging
/// directory. A manager downloads files sequentially so aggregate progress is
/// deterministic and only one URLSessionDownloadTask is active at a time.
public protocol ModelDownloadClient: Sendable {
    func download(
        from url: URL,
        to destination: URL,
        resumeData: Data?,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws

    func cancel() async
    func latestResumeData() async -> Data?
}

/// The production downloader uses URLSessionDownloadTask directly. It keeps
/// no request/response logging and only exposes byte counts to the manager.
///
/// `download(_:)` is cancellation-aware (2026-09-16 slice-4 review): the
/// continuation is wrapped in `withTaskCancellationHandler`, so cancelling
/// the Swift task cancels the `URLSessionDownloadTask` (keeping its resume
/// data) and the call throws `CancellationError` within a network round
/// trip. Without this a cancelled install unwound only when the current
/// *file* finished — minutes on a slow link — and, because the shell now
/// awaits a cancelled model task before starting the next
/// (`AppDelegate+Model.runModelTask`), a second Download press would have
/// waited that long. `finish` resumes the continuation exactly once
/// whichever of the cancel completion and the delegate's
/// `didCompleteWithError` arrives first.
public final class URLSessionModelDownloadClient: NSObject, ModelDownloadClient, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private lazy var session: URLSession = URLSession(
        configuration: configuration,
        delegate: self,
        delegateQueue: nil
    )
    private var activeTask: URLSessionDownloadTask?
    private var activeContinuation: CheckedContinuation<Void, Error>?
    private var activeDestination: URL?
    private var activeProgress: (@Sendable (Int64, Int64?) -> Void)?
    private var resumeData: Data?
    /// Set when the task's cancellation handler ran before the download
    /// task existed (the calling task was already cancelled on entry);
    /// consumed by the very next `download` body, which then throws at once.
    private var cancellationPending = false

    public override convenience init() {
        self.init(configuration: .ephemeral)
    }

    public init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
        super.init()
    }

    public func download(
        from url: URL,
        to destination: URL,
        resumeData: Data?,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        let request = URLRequest(url: url)
        // A cancellation that lands in the instant between the transfer
        // finishing (`activeTask` already nil) and the handler being
        // uninstalled would leave `cancellationPending` set for the *next*
        // caller, which would then throw for a cancellation that was never
        // its own. The handler can only run while this call is inside the
        // scope below, so clearing the note on the way out closes that gap.
        defer { clearCancellationNote() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                precondition(activeTask == nil, "Only one model download may be active")
                if cancellationPending {
                    cancellationPending = false
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                activeContinuation = continuation
                activeDestination = destination
                activeProgress = progress
                self.resumeData = nil

                let task: URLSessionDownloadTask
                if let resumeData {
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    task = session.downloadTask(with: request)
                }
                activeTask = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            cancelActiveTaskForTaskCancellation()
        }
    }

    private func clearCancellationNote() {
        lock.lock()
        cancellationPending = false
        lock.unlock()
    }

    /// The Swift task running `download` was cancelled: cancel the transfer
    /// (keeping resume data) and resume the continuation with
    /// `CancellationError`. If the transfer has not been created yet, leave a
    /// note for the body to throw immediately.
    private func cancelActiveTaskForTaskCancellation() {
        lock.lock()
        guard let task = activeTask else {
            cancellationPending = true
            lock.unlock()
            return
        }
        lock.unlock()
        task.cancel { [weak self] data in
            self?.finish(.failure(CancellationError()), resumeData: data)
        }
    }

    public func cancel() async {
        let task: URLSessionDownloadTask? = {
            lock.lock()
            defer { lock.unlock() }
            return activeTask
        }()
        guard let task else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            task.cancel { [weak self] data in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.finish(.failure(CancellationError()), resumeData: data)
                continuation.resume()
            }
        }
    }

    public func latestResumeData() async -> Data? {
        latestResumeDataLocked()
    }

    private func latestResumeDataLocked() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return resumeData
    }

    private func finish(_ result: Result<Void, Error>, resumeData: Data? = nil) {
        lock.lock()
        let continuation = activeContinuation
        activeContinuation = nil
        activeTask = nil
        activeDestination = nil
        activeProgress = nil
        if let resumeData {
            self.resumeData = resumeData
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

extension URLSessionModelDownloadClient: URLSessionDownloadDelegate {
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let progress = activeProgress
        lock.unlock()
        progress?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let destination = activeDestination
        lock.unlock()

        guard let destination else {
            finish(.failure(ModelManagementError.downloadFailed("The download destination was lost.")))
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(ModelManagementError.downloadFailed(error.localizedDescription)))
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        // A cancelled transfer is a cancellation whichever callback lands
        // first, so the manager pauses instead of recording a failure.
        let isCancelled = (error as? URLError)?.code == .cancelled
        finish(.failure(isCancelled ? CancellationError() : error), resumeData: resumeData)
    }
}

/// A URL builder for the pinned Hugging Face repository. It intentionally has
/// no fallback or model discovery behavior.
public protocol ModelDownloadURLProviding: Sendable {
    func url(for descriptor: ModelFileDescriptor, manifest: ModelManifest) throws -> URL
}

public struct PinnedHuggingFaceModelURLProvider: ModelDownloadURLProviding {
    public let host: URL

    public init(host: URL = KvoiceManagedModel.defaultDownloadHost) {
        self.host = host
    }

    public func url(for descriptor: ModelFileDescriptor, manifest: ModelManifest) throws -> URL {
        // ADR-017 / ADR-019: only a release in the pinned table, from its
        // pinned repository and revision. There is still no discovery or
        // fallback.
        guard let release = PinnedModelReleases.release(matching: manifest) else {
            throw ModelManagementError.unsupportedModel(manifest.modelID)
        }
        let path = try ModelRelativePath.validated(descriptor.path)
        // The manifest describes the *installed* layout (`model/…`, and for
        // Whisper `tokenizer/models/openai/whisper-large-v3/…`), which is
        // not how the files are published. Verified against the live host on
        // 2026-09-13 (Whisper) and 2026-09-14 (Parakeet): CoreML artifacts
        // sit directly under the package subdirectory (the repository root
        // when `subdirectory` is empty), and Whisper's tokenizer files come
        // from the upstream Whisper repository.
        var result: URL
        if let tokenizerSource = release.tokenizerSource, path.hasPrefix(tokenizerSource.installedPrefix) {
            result = host
                .appendingPathComponent(tokenizerSource.repository, isDirectory: false)
                .appendingPathComponent("resolve", isDirectory: false)
                .appendingPathComponent(tokenizerSource.revision, isDirectory: false)
                .appendingPathComponent(String(path.dropFirst(tokenizerSource.installedPrefix.count)), isDirectory: false)
        } else if path.hasPrefix(Self.modelPrefix) {
            result = host
                .appendingPathComponent(release.repository, isDirectory: false)
                .appendingPathComponent("resolve", isDirectory: false)
                .appendingPathComponent(release.revision, isDirectory: false)
            if !release.subdirectory.isEmpty {
                result = result.appendingPathComponent(release.subdirectory, isDirectory: false)
            }
            result = result.appendingPathComponent(String(path.dropFirst(Self.modelPrefix.count)), isDirectory: false)
        } else {
            throw ModelManagementError.unsupportedModel(manifest.modelID)
        }
        var components = URLComponents(url: result, resolvingAgainstBaseURL: false)
        components?.query = "download=true"
        result = components?.url ?? result
        return result
    }

    static let modelPrefix = "model/"
}
