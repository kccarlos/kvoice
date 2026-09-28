import XCTest
import KvoiceDomain
@testable import KvoiceAppCore

/// Every snapshot a controller publishes from the moment it is made, read
/// without depending on when a task is scheduled.
///
/// The public `snapshots()` keeps only the newest value, so a consumer task
/// reading it may legitimately miss a short-lived state — which is what made
/// assertions over its output fail on a loaded machine. This reads an
/// unbounded stream instead, and reads exactly as many snapshots as the
/// controller published (its initial one plus every publish since), so an
/// earlier snapshot equal to the last cannot end the read early and the read
/// never waits for one that will not come.
struct PublishedSnapshots {
    private let stream: AsyncStream<DictationController.Snapshot>
    private let countAtSubscription: Int

    init(_ controller: DictationController) async {
        (stream, countAtSubscription) = await controller.unboundedSnapshots()
    }

    /// The state kinds published so far, in order. Call it once the
    /// controller is quiescent (after `waitForCompletion()`); it can be
    /// called once.
    func kinds(
        of controller: DictationController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [DictationStateKind] {
        let expected = await 1 + controller.publishedSnapshotCount - countAtSubscription
        var kinds: [DictationStateKind] = []
        for await snapshot in stream {
            kinds.append(snapshot.state.kind)
            if kinds.count == expected { return kinds }
        }
        XCTFail("the stream ended after \(kinds.count) of \(expected) snapshots: \(kinds)", file: file, line: line)
        return kinds
    }
}
