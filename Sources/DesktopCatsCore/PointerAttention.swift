import CoreGraphics
import Foundation

public struct CursorStillness {
    private var anchor: CGPoint?
    private var since = 0.0
    public private(set) var seconds = 0.0

    public init() {}

    public mutating func observe(_ point: CGPoint?, at time: Double) {
        if let anchor, let point, hypot(anchor.x - point.x, anchor.y - point.y) <= 7 {
            seconds = max(0, time - since)
        } else {
            anchor = point
            since = time
            seconds = 0
        }
    }
}

public struct VisitBudget {
    private var next: Double
    private var lastLoafProbe = [UUID: Double]()
    public init(at time: Double) { next = time + 105 }

    public func available(at t: Double, stableFor: Double, distance: CGFloat) -> Bool {
        t >= next && distance >= 110 && stableFor >= (distance <= 400 ? 3.5 : 20)
    }

    public mutating func invitesFromRest(_ cat: CatProfile, action: CatAction, time t: Double,
                    stableFor: Double, distance: CGFloat, roll: @autoclosure () -> Double) -> Bool {
        guard action == .loaf, stableFor >= 20, available(at: t, stableFor: stableFor, distance: distance),
              t - (lastLoafProbe[cat.id] ?? -.infinity) >= 30 else { return false }
        lastLoafProbe[cat.id] = t
        return roll() < 0.06 + 0.24 * cat.personality.clingy * (1 - 0.45 * cat.personality.independent)
    }

    public mutating func recordVisit(at t: Double, roll: Double) {
        next = t + 210 + 120 * min(max(0, roll), 1)
    }
}

public struct VisitInterest {
    public let anchor: CGPoint
    public let arrival: Double

    public init(cursor: CGPoint, arrival: Double) {
        self.anchor = cursor
        self.arrival = arrival
    }

    public enum Response { case stay, acceptContact, leave }

    public func response(cursor: CGPoint?, touching: Bool, at t: Double) -> Response {
        guard let cursor, t <= arrival + 4.2 else { return .leave }
        // Moving from the small clear gap onto the cheek is acceptance, even
        // if that first deliberate touch crosses the stale-anchor radius.
        if touching && t >= arrival - 0.18 { return .acceptContact }
        return hypot(cursor.x - anchor.x, cursor.y - anchor.y) > 20 ? .leave : .stay
    }
}

/// Tracks one coherent axis of motion. The turn is measured from the previous
/// extreme, not between consecutive samples, so small hand jitter isn't a turn.
public struct ToyInvitation {
    private enum Stage { case scanning, watching, stalking }
    private var stage = Stage.scanning
    private var origin: CGPoint?
    private var axis: CGVector?
    private var tip: Double = 0
    private var sign = 1.0
    private var turns = 0
    private var last: CGPoint?
    private var started = 0.0
    private var lastMovement = 0.0
    private var stalkedAt = 0.0
    private var stalkPoint: CGPoint?
    private var cooldownUntil = 0.0
    public var hasAttention: Bool { stage != .scanning }

    public init() {}

    private mutating func reset(at t: Double, cooldown: Double = 0) {
        self = Self()
        cooldownUntil = t + cooldown
    }

    /// A nil cursor represents no nearby awake participant, active work (a
    /// drag), or a pointer outside this display. No pointer events are posted.
    public mutating func sample(_ point: CGPoint?, distance: CGFloat, awake: Bool, mode: CompanionMode,
                                at t: Double, personality: CatPersonality, roll: @autoclosure () -> Double) -> CatAction? {
        guard t >= cooldownUntil else { return nil }
        guard mode == .mischief, awake, distance <= 225, let p = point else {
            let lost = hasAttention
            reset(at: t, cooldown: lost ? 7 : 0)
            return lost ? .loaf : nil
        }
        guard let origin, let last else {
            self.origin = p; self.last = p; started = t; lastMovement = t
            return nil
        }
        self.last = p
        let moved = hypot(p.x - last.x, p.y - last.y)
        if moved >= 2.5 { lastMovement = t }

        if stage == .stalking {
            guard let stalkPoint, hypot(p.x - stalkPoint.x, p.y - stalkPoint.y) <= 18 else {
                reset(at: t, cooldown: 5)
                return .loaf
            }
            guard t - stalkedAt >= 0.52 else { return nil }
            reset(at: t, cooldown: 11)
            return roll() < 0.23 + 0.37 * personality.playful ? .pounce : .loaf
        }
        let still = t - lastMovement
        if stage == .watching, still >= 0.26 {
            stage = .stalking; stalkedAt = t; stalkPoint = p
            return .stalk
        }
        let dx = p.x - origin.x, dy = p.y - origin.y
        let reach = hypot(dx,dy)
        if (stage == .scanning && (still > 0.42 || t - started > 4.2)) ||
            reach > 160 || (stage == .watching && t - started > 6) {
            let lost = hasAttention
            reset(at: t, cooldown: lost ? 5 : 0)
            return lost ? .loaf : nil
        }
        if axis == nil, reach >= 27 {
            axis = CGVector(dx: dx / reach, dy: dy / reach)
            tip = reach
        }
        guard let axis else { return nil }
        if abs(dx * axis.dy - dy * axis.dx) > 31 {
            let lost = hasAttention
            reset(at: t, cooldown: lost ? 5 : 0)
            return lost ? .loaf : nil
        }
        let projection = dx * axis.dx + dy * axis.dy
        if (projection - tip) * sign > 0 {
            tip = projection
        } else if (tip - projection) * sign >= 32 {
            sign *= -1; turns += 1; tip = projection
        }
        if stage == .scanning, turns >= 3, t - started >= 0.68 {
            stage = .watching
            return .watch
        }
        return nil
    }
}
