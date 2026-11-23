import CoreGraphics
import DesktopCatsCore
import Foundation

let playful = CatPersonality(playful: 1, clingy: 0, sleepy: 0, curious: 1, independent: 0)
let sleepy = CatPersonality(playful: 0, clingy: 1, sleepy: 1, curious: 0, independent: 1)
let origin = CGPoint(x: 160, y: 170)

func actionCounts(_ personality: CatPersonality, _ winter: Double, mode: CompanionMode = .mischief) -> [CatAction: Int] {
    var counts = [CatAction: Int]()
    for i in 0..<1000 {
        let a = BehaviorEngine.ambient(personality: personality, mode: mode, winter: winter,
                                       visitAvailable: false, roll: Double(i) / 1000)
        counts[a, default: 0] += 1
    }
    return counts
}
let jan = SeasonSetting.northern.winterBias(month: 1)
precondition(jan == -SeasonSetting.southern.winterBias(month: 1) && jan == 1)
precondition(jan == -SeasonSetting.northern.winterBias(month: 7) && SeasonSetting.off.winterBias(month: 1) == 0)
let w = actionCounts(sleepy, jan), s = actionCounts(sleepy, -jan), a = actionCounts(playful, jan)
precondition(w[.nap, default: 0] > s[.nap, default: 0] && w[.nap, default: 0] - s[.nap, default: 0] < 80)
precondition(a[.nap, default: 0] < s[.nap, default: 0] && a[.wander, default: 0] > w[.wander, default: 0])
for p in [playful, sleepy] {
    let calm = actionCounts(p, jan, mode: .companion)
    precondition(calm[.loaf] != nil && calm[.nap] != nil)
    for restricted in [CatAction.startle, .zoom, .approach, .pounce, .stalk, .chase, .playTogether,
                       .bellyUp, .petRub, .sleepMurmur, .wakeStretch] {
        precondition(calm[restricted] == nil)
    }
    precondition(BehaviorEngine.hold(.nap, personality: p, winter: -1, roll: 0) >= 120)
    precondition(BehaviorEngine.hold(.nap, personality: p, winter: jan, roll: 0.5) >
                BehaviorEngine.hold(.nap, personality: p, winter: -jan, roll: 0.5))
}

let straight = (0...12).map { CGPoint(x: 100 + $0 * 5, y: 160) }
let back = Array(straight.reversed().dropFirst())
let forth = Array(straight.dropFirst())
let waving = straight + back + forth + back + forth
let paused = waving + Array(repeating: waving.last!, count: 23)

func invitations(_ points: [CGPoint], distance: CGFloat = 110, awake: Bool = true,
                 mode: CompanionMode = .mischief, draw: Double = 0.1) -> [CatAction] {
    var toy = ToyInvitation()
    return points.enumerated().compactMap { n, p in
        toy.sample(p, distance: distance, awake: awake, mode: mode, at: Double(n) * 0.06,
                   personality: playful, roll: draw)
    }
}
precondition(invitations(paused) == [.watch, .stalk, .pounce])
precondition(invitations(paused, draw: 0.98) == [.watch, .stalk, .loaf])
let evasive = waving + Array(repeating: waving.last!, count: 5) + [CGPoint(x: 204, y: 146)]
precondition(invitations(evasive) == [.watch, .stalk, .loaf])
precondition(invitations(straight + back + Array(repeating: straight[0], count: 22)).isEmpty)
precondition(invitations(paused, distance: 350).isEmpty && invitations(paused, awake: false).isEmpty)
precondition(invitations(paused, mode: .companion).isEmpty)

func petting(_ points: [CGPoint?], relaxed: Bool = true, draw: Double = 0.01) -> [CatAction] {
    var tracker = PettingTracker()
    var state: CatAction = relaxed ? .loaf : .watch
    return points.enumerated().compactMap { n, p in
        let reply = tracker.sample(p, at: Double(n) * 0.06, action: state, personality: sleepy, roll: draw)
        if let reply { state = reply }
        return reply
    }
}
let pet = waving + back + forth
precondition(petting(pet) == [.loafNuzzle, .bellyUp, .bellyNuzzle], "Unexpected awake contact sequence: \(petting(pet))")
precondition(petting(pet, relaxed: false, draw: 0.8) == [.petRub])
precondition(petting(pet, draw: 0.8) == [.loafNuzzle])
precondition(petting(straight) == [.loafNuzzle] && petting(straight, relaxed: false) == [.petRub])
precondition(petting(Array(repeating: origin, count: 180)).isEmpty)
precondition(petting([.zero, origin, .zero, origin, .zero, origin]).isEmpty)
precondition(petting(straight + [nil] + back, draw: 0.8) == [.loafNuzzle])

func sleepTouch(_ samples: [CGPoint?], personality: CatPersonality = sleepy, die: Double = 0.01,
                dragging: Bool = false) -> [CatAction] {
    var tracker = PettingTracker(), action = CatAction.nap
    var reactions = [CatAction]()
    for (i, p) in samples.enumerated() {
        if let response = tracker.sample(p, at: Double(i) * 0.06, action: action, personality: personality,
                                         buttonDown: dragging, roll: die) {
            reactions.append(response)
            action = response
        }
    }
    return reactions
}
let drowsy = CatPersonality(playful: 0, clingy: 0, sleepy: 1, curious: 0, independent: 0)
let affectionate = CatPersonality(playful: 0, clingy: 1, sleepy: 0, curious: 0, independent: 0)
let alert = CatPersonality(playful: 1, clingy: 0, sleepy: 0, curious: 1, independent: 1)
// 15pt in 0.15s is a single short trackpad stroke on a small visible head.
// No reversal or repeated click should be needed for acknowledgement.
for (state, desired) in [(CatAction.nap, CatAction.sleepMurmur), (.bellyUp, .bellyNuzzle),
                         (.watch, .petRub), (.loaf, .loafNuzzle)] {
    var contact = PettingTracker()
    let replies = (0...18).compactMap { n in
        contact.sample(CGPoint(x: 12 + Double(n) * 15 / 18, y: 20), at: Double(n) / 120,
                       action: state, personality: affectionate, roll: 0.5)
    }
    precondition(replies == [desired])
    var taps = CatTapResponder()
    precondition(taps.tap(at: 0, action: state, personality: affectionate, roll: 0.5) == desired)
    precondition(taps.tap(at: 0.10, action: desired, personality: affectionate, roll: 0.01) == nil)
}
for draw in [0.01, 0.99] {
    var tap = CatTapResponder()
    precondition(tap.tap(at: 0, action: .loaf, personality: affectionate, roll: draw) == .loafNuzzle)
    let warmTap = tap.tap(at: 1.1, action: .loafNuzzle, personality: affectionate, roll: draw)
    precondition(warmTap == (draw < 0.1 ? .bellyUp : nil))
    precondition(tap.tap(at: 2.3, action: .bellyNuzzle, personality: affectionate, roll: draw) == nil)
    precondition(tap.tap(at: 8.2, action: .pounce, personality: affectionate, roll: draw) == nil)
    precondition(tap.tap(at: 11.2, action: .wakeStretch, personality: affectionate, roll: draw) == nil)
}
var returning = PettingTracker(), greetings = [CatAction]()
for i in 0...42 {
    let t = Double(i) * 0.06
    let x: CGFloat? = i < 8 ? CGFloat(4*i) : (i < 28 ? 28 : (i < 37 ? nil : CGFloat((i-37)*4)))
    let state: CatAction = i >= 5 && i < 35 ? .loafNuzzle : .loaf
    if let response = returning.sample(x.map { CGPoint(x: $0, y: 3) }, at: t, action: state,
                                       personality: affectionate, roll: 0.99) { greetings.append(response) }
}
precondition(greetings == [.loafNuzzle, .loafNuzzle])
precondition(sleepTouch(straight) == [.sleepMurmur])
precondition(sleepTouch(pet, personality: drowsy, die: 0.6) == [.sleepMurmur, .sleepMurmur])
precondition(sleepTouch(pet, personality: affectionate, die: 0.6) == [.sleepMurmur, .bellyUp, .bellyNuzzle])
precondition(sleepTouch(pet, personality: alert, die: 0.6) == [.sleepMurmur, .wakeStretch])
precondition(sleepTouch(straight + [nil, nil] + back + forth, personality: alert, die: 0.6) ==
                 [.sleepMurmur, .wakeStretch])
precondition(sleepTouch(straight + Array(repeating: nil, count: 8) + back + forth,
                        personality: alert, die: 0.6) == [.sleepMurmur, .wakeStretch])
precondition(sleepTouch(Array(repeating: origin, count: 90)).isEmpty)
precondition(sleepTouch(pet, dragging: true).isEmpty)
let flyby = (0..<8).map { CGPoint(x: $0 * 13, y: 12) }
precondition(sleepTouch(flyby).isEmpty && sleepTouch(Array(straight.prefix(3))).isEmpty)
precondition(petting(flyby).isEmpty && petting(Array(straight.prefix(3))).isEmpty)
let jitter = (0..<48).map { CGPoint(x: 100 + ($0 % 2), y: 110) }
precondition(sleepTouch(jitter).isEmpty)

func denseContact(_ state: CatAction, frequency: Double = 120, x: (Double) -> Double) -> [CatAction] {
    var tracker = PettingTracker()
    return (0...Int(3 * frequency)).compactMap { n in
        let t = Double(n) / frequency
        return tracker.sample(CGPoint(x: 100 + x(t), y: 110), at: t, action: state,
                              personality: sleepy, roll: 0.5)
    }
}
// 18pt/s at 120Hz is only 0.15pt per event. It should feel like the
// same 54pt stroke sampled by the desktop timer.
for state in [CatAction.watch, .nap] {
    let expected: [CatAction] = state == .nap ? [.sleepMurmur, .sleepMurmur] : [.petRub]
    for hz in [16.0, 120.0, 240.0] {
        precondition(denseContact(state, frequency: hz) { 18 * $0 } == expected)
    }
    precondition(denseContact(state) { _ in 0 }.isEmpty)
    precondition(denseContact(state) { 0.12 * sin($0 * 140) }.isEmpty)
    precondition(denseContact(state) { 0.70 * sin($0 * 125) }.isEmpty)
    precondition(denseContact(state) { $0 < 2.8 ? 0 : 220 * ($0 - 2.8) }.isEmpty)
}
precondition(BehaviorEngine.afterTouch(.sleepMurmur) == .nap && BehaviorEngine.afterTouch(.wakeStretch) == .loaf)
precondition(BehaviorEngine.afterTouch(.bellyUp) == .loaf)
precondition(BehaviorEngine.afterTouch(.loafNuzzle) == .loaf)
precondition(BehaviorEngine.afterTouch(.bellyNuzzle) == .bellyUp)
precondition(BehaviorEngine.afterTouch(.bellyNuzzle, bellyExpired: true) == .loaf)
precondition(BehaviorEngine.afterTouch(.nap) == .wakeStretch)
precondition(BehaviorEngine.afterTouch(.sleepMurmur, napExpired: true) == .wakeStretch)
precondition(BehaviorEngine.afterTouch(.petRub) == .watch && BehaviorEngine.afterTouch(.loaf) == nil)
precondition(BehaviorEngine.hold(.sleepMurmur, personality: sleepy, winter: jan, roll: 0.9) == 2.3)
precondition(BehaviorEngine.hold(.wakeStretch, personality: sleepy, winter: jan, roll: 0.9) == 3.4)
print("Sleeping-touch traces passed: single gentle stroke, three personality responses, brief edge exit, drag and flyby rejection.")

var visits = VisitBudget(at: 0)
precondition(!visits.available(at: 0, stableFor: 10, distance: 170))
precondition(!visits.available(at: 200, stableFor: 0.5, distance: 170))
precondition(visits.available(at: 200, stableFor: 5, distance: 170))
visits.recordVisit(at: 200, roll: 0.5)
precondition(!visits.available(at: 330, stableFor: 50, distance: 180))
precondition(visits.available(at: 475, stableFor: 50, distance: 180))
precondition(!visits.available(at: 475, stableFor: 10, distance: 1200))
precondition(visits.available(at: 475, stableFor: 24, distance: 1200))
let interest = VisitInterest(cursor: origin, arrival: 201)
precondition(interest.response(cursor: origin, touching: false, at: 203) == .stay)
let moved = CGPoint(x: 51, y: 50)
precondition(interest.response(cursor: moved, touching: false, at: 200.1) == .leave)
precondition(interest.response(cursor: origin, touching: false, at: 206) == .leave)
precondition(interest.response(cursor: moved, touching: true, at: 201.2) == .acceptContact)
// User-initiated play and contact need no visit token.
precondition(invitations(paused).contains(.pounce) && petting(pet).contains(.loafNuzzle))

// An awake affectionate cat at the edge can volunteer while the pointer is
// parked in the middle. It gets only one opportunity per 30s, even if drawn
// every frame. Deliberately choose an accepting draw at the second opportunity.
var waiting = CursorStillness(), household = VisitBudget(at: 0)
let lapCat = CatProfile(name: "lap", personality: sleepy)
let otherCat = CatProfile(name: "peer", personality: playful)
var visit: VisitInterest?, events = [String](), active: CatAction = .loaf
var attempts = 0
let invitationDraw = { attempts += 1; return attempts == 1 ? 0.99 : 0.01 }
for sec in 0...240 {
    let t = Double(sec)
    waiting.observe(origin, at: t)
    precondition(!household.invitesFromRest(otherCat, action: .nap, time: t,
           stableFor: waiting.seconds, distance: 290, roll: 0))
    if let interest = visit {
        let response = interest.response(cursor: origin, touching: false, at: t)
        if response == .leave {
            events.append("retreat"); active = .wander; visit = nil
        } else if t >= interest.arrival, active == .approach {
            events.append("cheek rub"); active = .petRub
        }
    } else if household.invitesFromRest(lapCat, action: active, time: t,
                     stableFor: waiting.seconds, distance: 800, roll: invitationDraw()) {
        household.recordVisit(at: t, roll: 0.2)
        events.append("approach"); active = .approach
        visit = VisitInterest(cursor: origin, arrival: t + 5)
        precondition(!household.available(at: t, stableFor: waiting.seconds, distance: 160))
    }
}
precondition(events == ["approach", "cheek rub", "retreat"] && attempts == 2)
print("Parked-pointer trace: one voluntary side approach, cheek rub, then retreat when ignored.")

struct Dice {
    var state = UInt64(56)
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / 9_007_199_254_740_992
    }
}

// Ten minutes of typing pauses, moving from editor to toolbar, vertical
// scrolls and mouse-down selection. Use the same input and ambient policies
// as the overlay for two nearby cats sharing one unsolicited-visit budget.
for mode in CompanionMode.allCases {
    var toy = ToyInvitation(), still = CursorStillness(), budget = VisitBudget(at: 0), dice = Dice()
    var actions = [CatAction.loaf, .loaf], ready = [15.0, 19.0], visitTimes = [Double]()
    var naps = 0
    for n in 0..<10_000 {
        let t = Double(n) * 0.06, k = t.truncatingRemainder(dividingBy: 20)
        let start = CGPoint(x: 180, y: 165), end = CGPoint(x: 400, y: 270)
        let p: CGPoint?
        switch k {
        case 0..<8: p = start
        case 8..<9: p = CGPoint(x: start.x + (end.x-start.x)*(k-8), y: start.y + (end.y-start.y)*(k-8))
        case 9..<12: p = end
        case 12..<14: p = nil  // dragging a selection
        case 14..<15: p = CGPoint(x: 245, y: 120 + (k-14) * 130)
        default: p = start
        }
        still.observe(p, at: t)
        let distance = p.map { hypot($0.x - origin.x, $0.y - origin.y) } ?? .infinity
        let invited = toy.sample(p, distance: distance, awake: actions[0] != .nap, mode: mode,
                                 at: t, personality: playful, roll: dice.next())
        precondition(invited == nil)
        for i in ready.indices {
            let participant = i == 0 ? otherCat : lapCat
            let loafVisit = p != nil && budget.invitesFromRest(participant, action: actions[i], time: t,
                            stableFor: still.seconds, distance: distance, roll: dice.next())
            guard t >= ready[i] || loafVisit else { continue }
            let personality = i == 0 ? playful : sleepy
            let available = p != nil && budget.available(at: t, stableFor: still.seconds, distance: 185)
            let action = loafVisit ? .approach : BehaviorEngine.ambient(personality: personality, mode: mode, winter: 0.7,
                                  visitAvailable: available, roll: dice.next())
            precondition(![CatAction.chase, .pounce, .stalk, .petRub, .bellyUp].contains(action))
            if action == .approach {
                visitTimes.append(t)
                budget.recordVisit(at: t, roll: dice.next())
            }
            if action == .nap { naps += 1 }
            actions[i] = action
            ready[i] = t + BehaviorEngine.hold(action, personality: personality, winter: 0.7, roll: dice.next())
        }
    }
    precondition(visitTimes.count <= 3 && naps > 0 && naps <= 10)
    for (first, second) in zip(visitTimes, visitTimes.dropFirst()) { precondition(second - first >= 210) }
    print("10-minute \(mode.rawValue) trace: 0 toy responses; \(visitTimes.count) unsolicited visits; \(naps) long naps.")
}
print("Behavior checks passed: attention, deliberate contact, play refusals, shared cooldown, seasons and personality.")
checkEncounters()
