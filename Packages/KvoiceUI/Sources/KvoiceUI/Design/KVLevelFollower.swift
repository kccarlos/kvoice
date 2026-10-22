import Foundation

/// Motion spec § 4·6, "Level that feels alive": a level that rises fast and
/// falls slowly, so a meter or halo follows the voice instead of flickering
/// with it. The spec's rule is per 16 ms tick —
///
///     level = raw > level ? lerp(level, raw, 0.6) : lerp(level, raw, 0.15)
///
/// — about 50 ms attack and 200 ms release. Feeds arrive at their own
/// rate (the HUD's rendered state ticks at 20 Hz), so `step` converts the
/// per-tick factors to the elapsed time: `1 − (1 − k)^(dt / 16 ms)`, which
/// is exactly the spec's factor at a 16 ms tick. Pure, so it is tested
/// without a clock and the HUD (F5) can reuse it.
public struct KVLevelFollower: Equatable, Sendable {
    public static let tick: Double = 0.016
    public static let attack: Double = 0.6
    public static let release: Double = 0.15

    public private(set) var level: Double
    /// When `follow(raw:at:)` last stepped; nil before the first.
    public private(set) var lastTick: Date?

    public init(level: Double = 0) {
        self.level = Self.clamp(level)
    }

    /// Advances by `elapsed` seconds towards `raw` (0…1) and returns the
    /// new level. A zero or negative interval leaves the level alone.
    @discardableResult
    public mutating func step(raw: Double, elapsed: Double = KVLevelFollower.tick) -> Double {
        let target = Self.clamp(raw)
        guard elapsed > 0 else { return level }
        let perTick = target > level ? Self.attack : Self.release
        let factor = 1 - pow(1 - perTick, elapsed / Self.tick)
        level += (target - level) * factor
        return level
    }

    /// Steps by the real time since the previous call — clamped to
    /// 16–200 ms, 50 ms for the first — which is how the status panel and
    /// the recorder feed it from the HUD's 20 Hz rendered level, so the
    /// three meters (panel, recorder, menu bar) follow the voice alike.
    @discardableResult
    public mutating func follow(raw: Double, at now: Date) -> Double {
        let elapsed = lastTick.map { min(max(now.timeIntervalSince($0), Self.tick), 0.2) } ?? 0.05
        lastTick = now
        return step(raw: raw, elapsed: elapsed)
    }

    /// The menu-bar halo's opacity for a level (the spec's written rule:
    /// 0.25 + 0.75·level; Reduce Motion keeps it lit at 0.8).
    public static func haloOpacity(level: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 0.8 : 0.25 + 0.75 * clamp(level)
    }

    /// The halo's scale for a level (0.8 + 0.45·level; 1 under Reduce
    /// Motion, where nothing moves).
    public static func haloScale(level: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 1 : 0.8 + 0.45 * clamp(level)
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
