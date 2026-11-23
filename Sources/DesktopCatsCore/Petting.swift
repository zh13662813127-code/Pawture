import CoreGraphics
import Foundation

private enum ContactPosture {
    case asleep, lying, supine, upright

    init?(_ action: CatAction) {
        switch action {
        case .nap, .sleepMurmur: self = .asleep
        case .loaf, .loafNuzzle: self = .lying
        case .bellyUp, .bellyNuzzle: self = .supine
        case .watch, .groom, .wander, .approach, .chase, .playTogether, .stalk, .petRub: self = .upright
        case .wakeStretch, .zoom, .startle, .pounce, .greetSniff, .greetRub: return nil
        }
    }

    var acknowledgement: CatAction {
        switch self {
        case .asleep: .sleepMurmur
        case .lying: .loafNuzzle
        case .supine: .bellyNuzzle
        case .upright: .petRub
        }
    }
}

/// One responder per cat, independent of pointer sampling and drag cancellation.
public struct CatTapResponder {
    private var previous = -Double.infinity
    private var lastChoice = -Double.infinity

    public init() {}

    public mutating func tap(at time: Double, action: CatAction, personality: CatPersonality,
                             roll: @autoclosure () -> Double) -> CatAction? {
        let interval = time - previous
        guard interval >= 0.5, let posture = ContactPosture(action) else { return nil }
        previous = time
        if action != posture.acknowledgement { return posture.acknowledgement }

        // A second touch may invite more affection, but cannot restart a
        // short pose or repeatedly roll the dice while that pose is playing.
        guard posture != .supine, interval >= 0.95, interval < 4.8, time - lastChoice >= 7 else { return nil }
        lastChoice = time
        switch action {
        case .sleepMurmur:
            let reply = BehaviorEngine.sustainedSleepResponse(personality: personality, roll: roll())
            return reply == .sleepMurmur ? nil : reply
        case .loafNuzzle, .petRub:
            return BehaviorEngine.offersBelly(personality, roll: roll()) ? .bellyUp : nil
        default: return nil
        }
    }
}

/// Screen-point sampling shared by the preview and desktop. A short, directed
/// stroke acknowledges contact; affection builds from movement, not turn counts.
public struct PettingTracker {
    private var posture: ContactPosture?
    private var motionPoint: CGPoint?
    private var motionAt = 0.0
    private var lastContact: Double?
    private var lastMovement: Double?
    private var entry = CGPoint.zero
    private var segmentOrigin = CGPoint.zero
    private var bestSpan = 0.0
    private var distance = 0.0
    private var movingTime = 0.0
    private var lastFeedback = -Double.infinity
    private var feedbackMotion = 0.0
    private var earliestFeedback = -Double.infinity
    private var acknowledged = false
    private var consideredBelly = false
    private var returnMotion: Double?

    // A hand can leave the outline between strokes, without counting the
    // return jump as movement. A different cat must own a separate session.
    private static let edgeGrace = 0.95

    public init() {}
    public var retainsContact: Bool { lastContact != nil }

    public mutating func sample(_ point: CGPoint?, at time: Double, action: CatAction,
                                personality: CatPersonality, buttonDown: Bool = false,
                                roll: @autoclosure () -> Double) -> CatAction? {
        guard !buttonDown, let nextPosture = ContactPosture(action) else { self = Self(); return nil }
        guard let point else {
            if let lastContact, time - lastContact > Self.edgeGrace { self = Self() }
            motionPoint = nil
            return nil
        }
        let gap = time - (lastContact ?? time)
        if lastContact == nil || gap <= 0 || gap > Self.edgeGrace || posture != nextPosture ||
            (lastMovement.map { time - $0 > 1.8 } == true) {
            let justRolled = consideredBelly && posture != nextPosture && nextPosture == .supine
            self = Self()
            posture = nextPosture
            earliestFeedback = justRolled ? time + 1.3 : time
            acknowledged = action == nextPosture.acknowledgement
        }
        let sampleGap = gap > 0.27
        defer { lastContact = time }
        guard let motionPoint, !sampleGap else {
            if acknowledged, gap > 0.30, time - lastFeedback >= 1.8,
               action != nextPosture.acknowledgement {
                returnMotion = movingTime
            }
            self.motionPoint = point
            motionAt = time
            entry = point
            segmentOrigin = point
            return nil
        }

        let step = hypot(point.x - motionPoint.x, point.y - motionPoint.y)
        // Subpixel trackpad motion accumulates from the last accepted point.
        guard step > 0.2 else { return nil }
        let dt = min(time - motionAt, max(gap, 0.08))
        defer { self.motionPoint = point; motionAt = time }
        guard step / dt <= 195 else {
            self = Self()
            posture = nextPosture
            entry = point
            segmentOrigin = point
            return nil
        }

        lastMovement = time
        movingTime += dt
        bestSpan = max(bestSpan, hypot(point.x - entry.x, point.y - entry.y))
        let length = hypot(point.x - segmentOrigin.x, point.y - segmentOrigin.y)
        if length >= 5 {
            distance += length
            segmentOrigin = point
        }
        guard time >= earliestFeedback else { return nil }
        let movingCat = [.wander, .approach, .chase, .playTogether, .stalk].contains(action)
        let reach = movingCat ? 20.0 : (nextPosture == .asleep ? 9.0 : 11.0)
        guard bestSpan >= reach, movingTime >= (movingCat ? 0.24 : 0.13) else { return nil }
        if !acknowledged {
            acknowledged = true
            return feedback(nextPosture.acknowledgement, at: time)
        }
        if let returnMotion, movingTime - returnMotion >= 0.13,
           hypot(point.x - entry.x, point.y - entry.y) >= reach {
            self.returnMotion = nil
            return feedback(nextPosture.acknowledgement, at: time)
        }

        // Short breaks do not drain the accumulated contact. Personality
        // affects both patience and willingness; no number of passes forces a roll.
        let patience = 1.25 + 0.45 * personality.independent - 0.25 * personality.clingy
        if !consideredBelly, nextPosture != .supine, movingTime >= patience,
           distance >= 46, time - lastFeedback >= 0.95 {
            consideredBelly = true
            if nextPosture == .asleep {
                return feedback(BehaviorEngine.sustainedSleepResponse(personality: personality, roll: roll()), at: time)
            }
            if (nextPosture == .lying || action == .petRub), BehaviorEngine.offersBelly(personality, roll: roll()) {
                return feedback(.bellyUp, at: time)
            }
        }

        // While the hand is still engaged, an occasional small acknowledgement
        // is enough. Don't rewind an in-flight nuzzle or keep a belly-up pose alive.
        if action != nextPosture.acknowledgement, nextPosture != .supine,
           time - lastFeedback >= 4.4, movingTime - feedbackMotion >= 1.2 {
            return feedback(nextPosture.acknowledgement, at: time)
        }
        return nil
    }

    private mutating func feedback(_ action: CatAction, at time: Double) -> CatAction {
        lastFeedback = time
        feedbackMotion = movingTime
        return action
    }
}
