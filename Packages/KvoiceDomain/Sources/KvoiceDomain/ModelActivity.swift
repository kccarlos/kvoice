import Foundation

/// ADR-022 item 5: what the model library is doing right now, as one state
/// instead of four flags.
///
/// `SpeechModelLibrary` (KvoiceModelManagement) owns exactly one
/// `ModelActivity` and every operation that touches a package or the
/// resident engine — a download, an install, a default switch, a
/// compute-unit reload, the Runtime card's test, Transcribe File, an unload
/// — begins by asking `ModelActivityTransition` whether it may start and
/// ends by returning to `.idle`. The per-package `ModelLifecycleState`
/// stays the *package* fact (downloading 40 %, verified, absent); this is
/// the *library* fact: is anything in flight, and what.
///
/// The two reentrancy bugs of 2026-09-14 — GPU units reaching the Unified
/// encoder mid-reload, and the memory-pressure reload racing a compute-unit
/// reload — were both a second engine operation slipping in while a first
/// was between `unload` and `load`. Under this table both are a refused
/// `begin`, tested as such in `SpeechModelLibraryTests`.
///
/// Adding a model operation: add a case here, decide its `name`, add the
/// row to `ModelActivityTransitionTests`, and wrap the library method in
/// `withActivity`. The table itself needs no change: only `.idle` accepts a
/// new activity, and every activity returns to `.idle` on completion,
/// failure, or cancellation.
public enum ModelActivity: Equatable, Sendable, Hashable {
    case idle
    /// A manager's install transaction for `id` (download → verify →
    /// install → load when `id` is the default). `resume` and `retry` are
    /// the same transaction picked up again.
    case downloading(ModelID)
    /// Any other package transaction on `id`: an external-folder
    /// selection, a delete, a forget, or the launch / refresh
    /// re-verification (which loads the default when it is verified).
    case installing(ModelID)
    /// The resident runtime is being (re)loaded for `id`: a default-model
    /// switch, or the reload-on-next-dictation after a memory-pressure
    /// unload.
    case loading(ModelID)
    /// `setComputeUnits`: the engine is between runtimes.
    case reloadingUnits
    /// The Runtime card's performance test holds the engine.
    case testing
    /// History › Transcribe File… holds the engine.
    case transcribingFile
    /// "Unload model now" / the critical-pressure auto-unload is releasing
    /// the runtime.
    case unloading

    /// The bounded token for diagnostics: the case name, never the model ID.
    public var name: String {
        switch self {
        case .idle: return "idle"
        case .downloading: return "downloading"
        case .installing: return "installing"
        case .loading: return "loading"
        case .reloadingUnits: return "reloadingUnits"
        case .testing: return "testing"
        case .transcribingFile: return "transcribingFile"
        case .unloading: return "unloading"
        }
    }

    /// The package the activity is about, for the activities that have one.
    public var modelID: ModelID? {
        switch self {
        case .downloading(let id), .installing(let id), .loading(let id): return id
        case .idle, .reloadingUnits, .testing, .transcribingFile, .unloading: return nil
        }
    }

    public var isIdle: Bool { self == .idle }

    /// The activities during which a shortcut press gets the busy beep
    /// instead of reaching the controller: the engine is in use by the
    /// shell's own operations (the test, a file) or mid-reload, and a
    /// dictation started now would fail with `sttFailed` or `loadInProgress`
    /// rather than be Blocked on a missing model. A package operation or a
    /// pressure unload/reload is *not* in this set: the controller's
    /// prerequisite check turns those into a Blocked HUD with a reason, as
    /// before.
    public var refusesDictationStart: Bool {
        switch self {
        case .reloadingUnits, .testing, .transcribingFile: return true
        case .idle, .downloading, .installing, .loading, .unloading: return false
        }
    }
}

/// A `begin` the table refused: `requested` could not start because
/// `running` had not returned to `.idle`. Thrown by the library so a caller
/// can map it to its own busy error and so the refusal is never a silent
/// drop; the library also logs it as one scalar `model.activity.refused`
/// line (`reason` = requested name, `site` = running name).
public struct ModelActivityRefusal: Error, Equatable, Sendable {
    public let requested: ModelActivity
    public let running: ModelActivity

    public init(requested: ModelActivity, running: ModelActivity) {
        self.requested = requested
        self.running = running
    }
}

/// The legal-transition table, pure and table-tested
/// (`ModelActivityTransitionTests` enumerates every (current, requested)
/// pair).
///
/// | Current | `begin(x)` (x ≠ idle) | `completed` / `failed` / `cancelled` |
/// | --- | --- | --- |
/// | idle | → x | → idle (nothing was running; harmless) |
/// | any other | refused (`ModelActivityRefusal`) | → idle |
///
/// `begin(.idle)` is never legal: ending is an event, not an activity.
public enum ModelActivityTransition {
    public enum Event: Equatable, Sendable {
        case begin(ModelActivity)
        case completed
        case failed
        case cancelled
    }

    /// Whether `requested` may start while `current` is the activity.
    public static func canBegin(_ requested: ModelActivity, from current: ModelActivity) -> Bool {
        current == .idle && requested != .idle
    }

    /// The state after `event`, or the typed refusal when `event` is a
    /// `begin` the table rejects.
    public static func next(
        _ current: ModelActivity,
        _ event: Event
    ) -> Result<ModelActivity, ModelActivityRefusal> {
        switch event {
        case .begin(let requested):
            guard canBegin(requested, from: current) else {
                return .failure(ModelActivityRefusal(requested: requested, running: current))
            }
            return .success(requested)
        case .completed, .failed, .cancelled:
            return .success(.idle)
        }
    }

    /// Every case with a representative payload, for table-driven tests
    /// and for callers that need to enumerate the machine.
    public static func representativeActivities(modelID: ModelID = "model") -> [ModelActivity] {
        [
            .idle, .downloading(modelID), .installing(modelID), .loading(modelID),
            .reloadingUnits, .testing, .transcribingFile, .unloading
        ]
    }
}
