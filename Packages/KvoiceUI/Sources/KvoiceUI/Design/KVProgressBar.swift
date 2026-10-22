import SwiftUI

/// How a drawn progress bar moves (fix/post-0.1.7, 2026-10-22). A known
/// fraction fills to it; an unknown one — a download whose total is not
/// known yet, verifying, loading, the first Core ML build — slides a segment
/// across the track, or under Reduce Motion holds it still in the middle,
/// which still reads as "in progress" next to the phase's words.
public enum KVProgressMotion: Equatable, Sendable {
    case determinate(Double)
    case sliding
    case still

    public static func style(fraction: Double?, reduceMotion: Bool) -> KVProgressMotion {
        if let fraction { return .determinate(min(max(fraction, 0), 1)) }
        return reduceMotion ? .still : .sliding
    }

    /// One pass of the sliding segment.
    static let slidePeriod: TimeInterval = 1.4
    /// The segment's share of the track.
    static let segment: CGFloat = 0.35

    /// The segment's leading edge, as a share of the track, at `time`: it
    /// enters from the left edge and leaves past the right one, so the
    /// track's clip shape shows it moving in and out.
    static func slideOffset(at time: TimeInterval) -> CGFloat {
        let phase = time.truncatingRemainder(dividingBy: slidePeriod) / slidePeriod
        return -segment + (1 + segment) * CGFloat(phase)
    }
}

/// The one drawn progress bar: the wizard's model card (`ProgressStrip`) and
/// the status panel's progress row (`ProgressTrack`) both draw this, so the
/// indeterminate motion lives in one place.
///
/// The sliding segment is driven by a `TimelineView(.animation)`, not by an
/// animation started in `onAppear`: an `onAppear` animation never restarts
/// when a determinate download turns into an indeterminate load in the same
/// view (the wizard's 2026-10-21 fix), and the status panel is a borderless
/// `NSPanel` whose content is laid out before it is on screen. A timeline
/// redraws on every frame while the view is visible, wherever it is hosted,
/// and costs nothing while it is not.
struct KVProgressBar: View {
    let fraction: Double?
    let reduceMotion: Bool
    var height: CGFloat = 6
    var track: Color = Color.kv.fill

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                switch KVProgressMotion.style(fraction: fraction, reduceMotion: reduceMotion) {
                case .determinate(let value):
                    Capsule().fill(Color.kv.cursor)
                        .frame(width: max(height, width * CGFloat(value)))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: value)
                case .still:
                    Capsule().fill(Color.kv.cursor)
                        .frame(width: width * KVProgressMotion.segment)
                        .offset(x: width * (1 - KVProgressMotion.segment) / 2)
                case .sliding:
                    TimelineView(.animation) { context in
                        Capsule().fill(Color.kv.cursor)
                            .frame(width: width * KVProgressMotion.segment)
                            .offset(x: width * KVProgressMotion.slideOffset(at: context.date.timeIntervalSinceReferenceDate))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
