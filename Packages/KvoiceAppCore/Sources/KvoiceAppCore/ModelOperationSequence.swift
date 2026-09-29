import Foundation
import KvoiceDomain

/// 2026-09-29: the order in which the shell runs one model operation behind
/// the previous one, once `ModelOperationAdmission` has let it in.
///
/// The previous shell task is **never cancelled** — it may be the launch
/// restore (whose first Neural Engine compile the owner's TestFlight log
/// shows thrown away by exactly such a cancel), and a cancelled restore
/// would also leave the wizard's "Checking which speech model…" up. For a
/// superseded download only the *download* is cancelled, at the library:
/// `cancel(id)` is a no-op once the transaction has left its byte phase
/// (the manager's installation context is gone by then), so a decision
/// taken on a state polled 250 ms earlier cannot pause a verify or a load.
/// The download may not be the shell's task at all (the ADR-025 automatic
/// asset install runs from the language poll), hence the wait for the
/// library to be idle before the new body runs.
///
/// Sequence: supersede → `cancelDownload(id)`, then `previous`, then
/// `waitUntilIdle`, then `body`; start → `previous`, then `body`; refuse →
/// nothing (the caller has already said why).
public enum ModelOperationSequence {
    @MainActor
    public static func run(
        _ admission: ModelOperationAdmission,
        downloadID: ModelID?,
        previous: Task<Void, Never>?,
        cancelDownload: @escaping @MainActor (ModelID) async -> Void,
        waitUntilIdle: @escaping @MainActor () async -> Void,
        body: @escaping @MainActor () async -> Void
    ) async {
        switch admission {
        case .refuse:
            return
        case .supersedeDownload:
            if let downloadID {
                await cancelDownload(downloadID)
            }
            if let previous { await previous.value }
            await waitUntilIdle()
        case .start:
            if let previous { await previous.value }
        }
        guard !Task.isCancelled else { return }
        await body()
    }
}
