import Foundation
import KvoiceDomain

/// Where a model is on its way to "Ready" (fix/post-0.1.7, 2026-10-22): the
/// one projection of `ModelLifecycleState` that the menu-bar icon, the status
/// panel, the menu header, the sidebar pill, Home's hero, the wizard and the
/// Speech Models page all read, with the words each of them shows.
///
/// Before it, the panel keyed its progress row on `ModelActivity` — whose
/// `.downloading(id)` is the whole transaction (download → verify → install
/// → load) and whose `.installing(id)` covers the launch re-verification
/// that loads the default — and always said "Downloading <model>…", while
/// Speech Models, reading the lifecycle state, said the model was being
/// optimized for the Neural Engine. The readiness line said "Model
/// loading…" for a download. Every surface now names the phase the library
/// reports, and `SurfaceStateMatrixTests` walks every lifecycle state
/// through all of them.
public enum ModelReadinessPhase: Equatable, Sendable {
    /// Bytes are moving; `fraction` is nil while the total is unknown.
    case downloading(fraction: Double?)
    /// A download stopped with bytes kept; nothing is running.
    case downloadPaused
    /// Hashing the package (or validating an external folder).
    case verifying
    /// Moving the verified package into place.
    case installing
    /// Loading the compiled model into memory (seconds).
    case loading
    /// The first Core ML build on this Mac (minutes, once).
    case optimizing

    /// The phase of `state`, or nil when the model is not on its way
    /// anywhere: absent, ready, in use, failed, being removed, unavailable.
    /// Exhaustive on purpose — a new lifecycle state must pick a phase here.
    public init?(_ state: ModelLifecycleState) {
        switch state {
        case .downloading(let completed, let total):
            self = .downloading(fraction: total > 0 ? min(max(Double(completed) / Double(total), 0), 1) : nil)
        case .downloadPaused:
            self = .downloadPaused
        case .validatingExternal, .verifying:
            self = .verifying
        case .installing:
            self = .installing
        case .loading:
            self = .loading
        case .optimizing:
            self = .optimizing
        case .absent, .ready, .inference, .corrupt, .incompatible, .deleting, .error, .unavailable:
            return nil
        }
    }

    /// The model the library is working on and the phase to show for it,
    /// for the menu-bar surfaces' progress row; nil when no library
    /// operation is bringing a model closer to ready (a delete, a test, an
    /// unload). `state` is that model's lifecycle state; when it has not
    /// caught up with the activity yet (the first poll of an operation),
    /// the activity's own phase stands in.
    public static func inProgress(activity: ModelActivity, state: ModelLifecycleState?) -> (id: ModelID, phase: ModelReadinessPhase)? {
        let id: ModelID
        let fallback: ModelReadinessPhase?
        switch activity {
        case .downloading(let model):
            id = model
            fallback = .downloading(fraction: nil)
        case .installing(let model):
            id = model
            fallback = nil
        case .loading(let model):
            id = model
            fallback = .loading
        case .idle, .reloadingUnits, .testing, .transcribingFile, .unloading:
            return nil
        }
        // A paused state under a running activity is the resume's first
        // poll: the activity's phase until the state catches up.
        if let state, let phase = ModelReadinessPhase(state), phase != .downloadPaused {
            return (id, phase)
        }
        if case .deleting? = state { return nil }
        return fallback.map { (id, $0) }
    }

    /// The download's fraction; nil for every other phase and while the
    /// total is unknown — the progress bar is then indeterminate.
    public var fraction: Double? {
        if case .downloading(let fraction) = self { return fraction }
        return nil
    }

    /// Bytes are coming in: the panel's download arrow and Pause Download
    /// belong to this phase only.
    public var isDownload: Bool {
        if case .downloading = self { return true }
        return false
    }

    /// The readiness line while the default model is not ready yet (status
    /// row, panel, sidebar pill, Home hero): no model name, which the panel
    /// shows on its own row.
    public var readinessTitle: String {
        switch self {
        case .downloading: return String(localized: "Downloading model…", bundle: .module)
        case .downloadPaused: return String(localized: "Download paused", bundle: .module)
        case .verifying: return String(localized: "Verifying model…", bundle: .module)
        case .installing: return String(localized: "Installing model…", bundle: .module)
        case .loading: return String(localized: "Loading the model…", bundle: .module)
        case .optimizing: return String(localized: "Optimizing model for this Mac (first time only)…", bundle: .module)
        }
    }

    /// The readiness line for a default model that is not ready: its phase,
    /// or "Model not ready" when nothing is bringing it closer.
    public static func readinessTitle(for state: ModelLifecycleState) -> String {
        ModelReadinessPhase(state)?.readinessTitle ?? String(localized: "Model not ready", bundle: .module)
    }

    /// The progress row's words, without the percentage (the panel draws it
    /// apart; the menu header appends it through `progressLabel(modelName:withPercent:)`).
    public func progressLabel(modelName: String) -> String {
        switch self {
        case .downloading: return String(localized: "Downloading \(modelName)…", bundle: .module)
        case .downloadPaused: return String(localized: "Download paused", bundle: .module)
        case .verifying: return String(localized: "Verifying \(modelName)…", bundle: .module)
        case .installing: return String(localized: "Installing \(modelName)…", bundle: .module)
        case .loading: return String(localized: "Loading \(modelName)…", bundle: .module)
        case .optimizing: return String(localized: "Optimizing \(modelName) for this Mac (first time only)…", bundle: .module)
        }
    }

    /// "Downloading Nemotron… 42%" while the total is known; otherwise the
    /// plain `progressLabel(modelName:)`.
    public func progressLabel(modelName: String, withPercent: Bool) -> String {
        if withPercent, case .downloading(let fraction?) = self {
            let percent = Int((fraction * 100).rounded(.down))
            return String(localized: "Downloading \(modelName)… \(percent)%", bundle: .module)
        }
        return progressLabel(modelName: modelName)
    }
}
