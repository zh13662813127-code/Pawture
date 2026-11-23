import CoreGraphics
import Foundation

public enum EncounterKind: String, CaseIterable, Identifiable, Sendable {
    case greeting, sharedNap, chase
    public var id: Self { self }
    public var title: String {
        switch self {
        case .greeting: "碰鼻蹭脸"
        case .sharedNap: "挨着打盹"
        case .chase: "轮流追跑"
        }
    }
}

public struct EncounterCat: Sendable {
    public let profile: CatProfile
    public let position: CGPoint
    public let action: CatAction
    public let available: Bool
    /// Offset from the center to the cheek when this portrait faces right.
    public let contactOffset: CGPoint?
    public let waitingForClip: Bool

    public init(profile: CatProfile, position: CGPoint, action: CatAction, available: Bool = true,
                contactOffset: CGPoint? = nil, waitingForClip: Bool = false) {
        self.profile = profile; self.position = position; self.action = action
        self.available = available; self.contactOffset = contactOffset; self.waitingForClip = waitingForClip
    }

    fileprivate var awake: Bool { [.loaf, .watch, .groom, .wander].contains(action) }
}

public struct EncounterCue: Sendable {
    public let catID: UUID
    public let action: CatAction
    public let target: CGPoint?
    public let lookAt: CGPoint?
    /// Zero on release cues: the ambient simulation then owns duration again.
    public let duration: Double
}

private struct Beat {
    var seconds: Double
    var cues: [EncounterCue]
}

private struct Encounter {
    let kind: EncounterKind
    let ids: Set<UUID>
    var beats: [Beat]
    var index = 0
    var due: Double
    var started: Double
}

/// The overlay keeps drawing and individual actions interrupt normally. The
/// coordinator owns only the two participants, and emits each change once.
public struct CatEncounters {
    private var scene: Encounter?
    private var nextProbe: Double?
    public var activeIDs: Set<UUID> { scene?.ids ?? [] }
    public var activeKind: EncounterKind? { scene?.kind }
    public func involves(_ id: UUID) -> Bool { scene?.ids.contains(id) ?? false }

    public init() {}

    public mutating func cancel(at time: Double) {
        guard scene != nil else { return }
        scene = nil
        nextProbe = time + 108
    }

    public mutating func preview(_ kind: EncounterKind, initiator: UUID, partner: UUID, at time: Double,
                    cats: [EncounterCat], bounds: CGRect, mode: CompanionMode) -> [EncounterCue] {
        guard initiator != partner, kind != .chase || mode == .mischief,
              let a = cats.first(where: { $0.profile.id == initiator }),
              let b = cats.first(where: { $0.profile.id == partner }) else { return [] }
        return start(kind, a: a, b: b, bounds: bounds, time: time, declined: false)
    }

    public mutating func tick(at time: Double, cats: [EncounterCat], bounds: CGRect,
                    mode: CompanionMode, roll: @autoclosure () -> Double) -> [EncounterCue] {
        if var running = scene {
            let participants = cats.filter { running.ids.contains($0.profile.id) }
            guard participants.count == 2, participants.allSatisfy(\.available),
                  mode == .mischief || running.kind != .chase else { cancel(at: time); return [] }
            if time - running.started < 8, participants.contains(where: \.waitingForClip) {
                running.due = time + running.beats[running.index].seconds
                scene = running
                return []
            }
            guard time >= running.due else { return [] }
            running.index += 1
            let beat = running.beats[running.index]
            if running.index == running.beats.count - 1 {
                scene = nil
                nextProbe = time + 155 + 110 * roll()
            } else {
                running.started = time
                running.due = time + beat.seconds
                scene = running
            }
            return beat.cues
        }

        guard let nextProbe else { self.nextProbe = time + 37; return [] }
        guard time >= nextProbe else { return [] }
        self.nextProbe = time + 24 + 15 * roll()
        guard bounds.width >= 120, bounds.height >= 40 else { return [] }
        // Opposite corners on the same edge are neighbors for this purpose;
        // two diagonal corners are not. Within this set, favor a nearby peer.
        var best: (a: EncounterCat, b: EncounterCat, score: Double)?
        for a in cats where a.available && a.awake {
            for b in cats where a.profile.id != b.profile.id && b.available && (b.awake || b.action == .nap) {
                let separation = distance(a.position, b.position)
                let onEdge = sameEdge(a.position, b.position, in: bounds)
                guard separation <= 230 || onEdge else { continue }
                let score = 0.42 * (onEdge ? 1 : 0) - min(separation / 2300, 0.65) +
                    0.22 * a.profile.personality.curious + 0.12 * a.profile.personality.clingy + 0.55 * roll()
                if best == nil || score > best!.score { best = (a, b, score) }
            }
        }
        guard let (a,b,_) = best else { return [] }
        let p = a.profile.personality, q = b.profile.personality
        guard roll() < 0.36 + 0.20 * p.curious + 0.18 * p.clingy - 0.10 * p.independent else { return [] }
        let nap = 0.11 + 0.40 * (p.sleepy + q.sleepy) / 2
        let chase = mode == .mischief ? 0.06 + 0.28 * min(p.playful, q.playful) : 0
        let draw = roll()
        let kind: EncounterKind = b.action == .nap || draw < nap ? .sharedNap : (draw < nap + chase ? .chase : .greeting)
        let declined = b.awake && roll() < 0.06 + 0.34 * q.independent + 0.10 * q.sleepy - 0.06 * q.clingy
        if declined, kind == .sharedNap { return [] }
        return start(kind, a: a, b: b, bounds: bounds, time: time, declined: declined)
    }

    private mutating func start(_ kind: EncounterKind, a originalA: EncounterCat, b originalB: EncounterCat,
                                bounds: CGRect, time: Double, declined: Bool) -> [EncounterCue] {
        guard bounds.width >= 120, bounds.height >= 40 else { return [] }
        // Never send an already sleeping cat to walk when sharing a bed.
        if kind == .sharedNap, originalA.action == .nap, originalB.action == .nap {
            // A preview can be acknowledged without touching either sleeping
            // pose or deadline. If they are apart, leave the choice to the UI.
            guard distance(originalA.position, originalB.position) <= 112 else { return [] }
            scene = Encounter(kind:.sharedNap,ids:[originalA.profile.id,originalB.profile.id],
                              beats:[Beat(seconds:2,cues:[]),Beat(seconds:0,cues:[])],
                              due:time+2,started:time)
            return []
        }
        let swap = kind == .sharedNap && originalA.action == .nap && originalB.action != .nap
        let (a,b) = swap ? (originalB,originalA) : (originalA,originalB)
        guard kind != .sharedNap || a.action != .nap else { return [] }
        let id = a.profile.id, peer = b.profile.id
        let clipped: (CGPoint) -> CGPoint = { p in
            CGPoint(x: min(bounds.maxX,max(bounds.minX,p.x)), y: min(bounds.maxY,max(bounds.minY,p.y)))
        }
        func cue(_ cat: UUID, _ action: CatAction, _ seconds: Double, _ to: CGPoint? = nil,
                 _ facing: CGPoint? = nil) -> EncounterCue {
            EncounterCue(catID: cat, action: action, target: to, lookAt: facing, duration: seconds)
        }
        func movement(_ from: CGPoint, _ to: CGPoint, speed: Double = 150) -> Double {
            max(0.42, distance(from,to) / speed)
        }
        var beats: [Beat] = []
        func step(_ seconds: Double, _ cues: EncounterCue...) { beats.append(Beat(seconds: seconds,cues: cues)) }
        if kind == .sharedNap {
            let anchor = b.position
            // Curled portraits at desktop scale are about 122pt wide. Leave the
            // faces and front paws distinct, even if the sleeper faces the visitor.
            let cardinal: [CGPoint] = [CGPoint(x: -101,y: 3), CGPoint(x: 101,y: 3),
                                        CGPoint(x: 0,y: -73), CGPoint(x: 0,y: 73)]
            let candidates = cardinal.map { clipped(CGPoint(x:anchor.x+$0.x,y:anchor.y+$0.y)) }
            guard let bed = candidates.filter({ distance(anchor,$0) >= 72 }).min(by: {
                distance(a.position,$0) < distance(a.position,$1)
            }) else { return [] }
            let travel = movement(a.position, bed)
            var arrivals = [cue(id, .approach, travel, bed, anchor)]
            if b.action != .nap { arrivals.append(cue(peer, .loaf, travel, nil, bed)) }
            beats.append(Beat(seconds:travel,cues:arrivals))
            var settling = [cue(id, .loaf, 1.8, nil, anchor)]
            // An awake partner settles first; an existing sleeper is never
            // assigned a new pose or sleep deadline.
            if b.action != .nap { settling.append(cue(peer, .nap, 0)) }
            beats.append(Beat(seconds:1.8,cues:settling))
            step(0, cue(id, .nap, 0))
        } else {
            guard var (first, second) = meet(a,b,in:bounds) else { return [] }
            let horizontal = !sameEdge(first, second, in:bounds) ||
                min(abs(first.y-bounds.minY),abs(first.y-bounds.maxY)) < 116 || bounds.height < 200
            // Reserve both ends of the lane before walking the cats into
            // their starting places. Clamping a dash independently at the
            // edge would otherwise make one cat run in place.
            if kind == .chase {
                let r = horizontal ? bounds.minX...bounds.maxX : bounds.minY...bounds.maxY
                let x = horizontal ? first.x : first.y, y = horizontal ? second.x : second.y
                let offset = min((r.upperBound - r.lowerBound - abs(x-y))/2, 140)
                guard offset >= 102 else { return [] }
                let low = r.lowerBound + offset, high = r.upperBound - offset
                let delta = max(0,low-min(x,y)) + min(0,high-max(x,y))
                if horizontal { first.x += delta; second.x += delta }
                else { first.y += delta; second.y += delta }
            }
            let travel = max(movement(a.position,first), movement(b.position,second))
            step(travel, cue(id,.approach,travel,first,second), cue(peer,.approach,travel,second,first))
            step(0.95, cue(id,.greetSniff,0.95,nil,second), cue(peer,.watch,0.95,nil,first))
            if declined {
                let direction = second.x >= first.x ? 1.0 : -1.0
                let aside = clipped(CGPoint(x:second.x + direction*62, y:second.y))
                step(1.2, cue(id,.watch,1.2,nil,second), cue(peer,.wander,1.2,aside))
                step(0, cue(id,.loaf,0), cue(peer,.watch,0))
            } else if kind == .greeting {
                let toward = second.x >= first.x ? 1.0 : -1.0
                let cheek = clipped(CGPoint(x:first.x + toward*7,y:first.y+3))
                step(1.45, cue(id,.greetRub,1.45,cheek,second), cue(peer,.greetSniff,1.45,nil,cheek))
                step(1.45, cue(id,.watch,1.45,nil,second), cue(peer,.greetRub,1.45,nil,cheek))
                step(0, cue(id,.loaf,0), cue(peer,.watch,0))
            } else {
                // The first cat darts away. Only after it has a head start does
                // its partner follow; then the front cat stops and roles reverse.
                let axis = horizontal ? CGPoint(x:1,y:0) : CGPoint(x:0,y:1)
                let isLower = horizontal ? first.x < second.x : first.y < second.y
                let dir = isLower ? -1.0 : 1.0
                func shifted(_ p: CGPoint, _ amount: Double) -> CGPoint {
                    clipped(CGPoint(x:p.x + axis.x*amount, y:p.y + axis.y*amount))
                }
                let lead = shifted(first,dir*140), follow = shifted(lead,-dir*88)
                let back = shifted(second,-dir*140), behind = shifted(back,dir*88)
                step(0.36,cue(id,.zoom,0.36,lead),cue(peer,.watch,0.36,nil,lead))
                step(0.66,cue(id,.watch,0.66,nil,second),cue(peer,.playTogether,0.66,follow,lead))
                step(0.48,cue(peer,.watch,0.48,nil,lead),cue(id,.watch,0.48,nil,follow))
                step(0.36,cue(peer,.zoom,0.36,back),cue(id,.watch,0.36,nil,back))
                step(0.66,cue(peer,.watch,0.66,nil,follow),cue(id,.playTogether,0.66,behind,back))
                step(0,cue(id,.loaf,0),cue(peer,.loaf,0))
            }
        }
        scene = Encounter(kind:kind,ids:[id,peer],beats:beats,due:time + beats[0].seconds,started:time)
        return beats[0].cues
    }

    private func meet(_ a: EncounterCat, _ b: EncounterCat, in bounds: CGRect) -> (CGPoint, CGPoint)? {
        let alpha = a.contactOffset ?? CGPoint(x:50,y:-25)
        let beta = b.contactOffset ?? CGPoint(x:50,y:-25)
        let gap = abs(alpha.x) + 6 + abs(beta.x)
        let dy = alpha.y - beta.y
        guard gap <= bounds.width, abs(dy) <= bounds.height else { return nil }
        let side = a.position.x <= b.position.x ? 1.0 : -1.0
        let midX = min(bounds.maxX-gap/2, max(bounds.minX+gap/2, (a.position.x+b.position.x)/2))
        let midY = min(bounds.maxY-abs(dy)/2, max(bounds.minY+abs(dy)/2, (a.position.y+b.position.y)/2))
        return (CGPoint(x:midX-side*gap/2,y:midY-dy/2), CGPoint(x:midX+side*gap/2,y:midY+dy/2))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private func sameEdge(_ a: CGPoint, _ b: CGPoint, in r: CGRect) -> Bool {
        let margin = min(108,min(r.width,r.height)*0.24)
        return [max(a.x,b.x)-r.minX, r.maxX-min(a.x,b.x), max(a.y,b.y)-r.minY, r.maxY-min(a.y,b.y)]
            .contains(where: { $0 <= margin })
    }
}
