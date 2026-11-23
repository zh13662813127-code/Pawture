import CoreGraphics
import DesktopCatsCore
import Foundation

func checkEncounters() {
    let bounds = CGRect(x:90,y:100,width:1200,height:600)
    let friendly = CatPersonality(playful:1,clingy:1,sleepy:0.2,curious:1,independent:0)
    let shy = CatPersonality(playful:0.1,clingy:0,sleepy:1,curious:0,independent:1)
    let alpha = CatProfile(name:"A",personality:friendly), beta = CatProfile(name:"B",personality:shy)
    let c = CatProfile(name:"C")
    let left = CGPoint(x:110,y:675), right = CGPoint(x:1270,y:680)
    func member(_ profile: CatProfile, _ point: CGPoint, _ action: CatAction = .loaf,
                available: Bool = true, waiting: Bool = false) -> EncounterCat {
        EncounterCat(profile:profile,position:point,action:action,available:available,
            contactOffset:profile.id == alpha.id ? CGPoint(x:54,y:-61) : CGPoint(x:71,y:-13),
            waitingForClip:waiting)
    }
    let pair = [member(alpha,left), member(beta,right)]
    func collect(_ world: inout CatEncounters, from t: Double, cats: [EncounterCat],
                 mode: CompanionMode = .companion) -> [(Double, EncounterCue)] {
        var events: [(Double,EncounterCue)] = []
        for i in 1...600 {
            let now = t + Double(i)/10
            let out = world.tick(at:now,cats:cats,bounds:bounds,mode:mode,roll:0.5)
            events += out.map { (now,$0) }
            if world.activeKind == nil { break }
        }
        return events
    }

    var w = CatEncounters()
    let approach = w.preview(.greeting,initiator:alpha.id,partner:beta.id,at:0,cats:pair,bounds:bounds,mode:.companion)
    precondition(approach.count == 2 && w.activeIDs == [alpha.id,beta.id])
    let first = approach[0].target!, second = approach[1].target!
    precondition(abs((second.x-71) - (first.x+54) - 6) < 0.001)
    precondition(abs((second.y-13) - (first.y-61)) < 0.001)
    precondition(first.y > bounds.maxY-90 && second.y > bounds.maxY-90)
    let greeting = collect(&w,from:0,cats:pair)
    let sniffs = greeting.filter { $0.1.action == .greetSniff }
    let rubs = greeting.filter { $0.1.action == .greetRub }
    precondition(sniffs.map { $0.1.catID } == [alpha.id,beta.id] && rubs.map { $0.1.catID } == [alpha.id,beta.id])
    precondition(rubs[1].0 - rubs[0].0 >= 1.4 && sniffs[0].0 >= approach[0].duration)
    precondition(greeting.suffix(2).allSatisfy { $0.1.duration == 0 })
    precondition(w.tick(at:70,cats:pair,bounds:bounds,mode:.companion,roll:0).isEmpty && !w.involves(alpha.id))

    let sleeper = [member(alpha,left), member(beta,right,.nap)]
    var settle = w.preview(.sharedNap,initiator:beta.id,partner:alpha.id,at:71,cats:sleeper,bounds:bounds,mode:.companion)
    precondition(settle.count == 1 && settle[0].catID == alpha.id)
    let bed = settle[0].target!
    let bedDistance = hypot(bed.x-right.x,bed.y-right.y)
    precondition((72...102).contains(bedDistance) && abs(bed.x-right.x) >= 100)
    settle += collect(&w,from:71,cats:sleeper).map(\.1)
    precondition(settle.allSatisfy { $0.catID == alpha.id } && settle.last?.action == .nap && settle.last?.duration == 0)
    let bothAsleep = [member(alpha,bed,.nap),member(beta,right,.nap)]
    precondition(w.preview(.sharedNap,initiator:alpha.id,partner:beta.id,at:100,
                          cats:bothAsleep,bounds:bounds,mode:.companion).isEmpty && w.activeKind == .sharedNap)
    precondition(collect(&w,from:100,cats:bothAsleep).isEmpty && w.activeKind == nil)
    precondition(w.preview(.sharedNap,initiator:alpha.id,partner:beta.id,at:105,
                          cats:[member(alpha,left,.nap),member(beta,right,.nap)],bounds:bounds,mode:.companion).isEmpty && w.activeKind == nil)

    var naps = w.preview(.sharedNap,initiator:alpha.id,partner:beta.id,at:110,cats:pair,bounds:bounds,mode:.companion)
    precondition(!naps.contains { $0.action == .nap })
    naps += collect(&w,from:110,cats:pair).map(\.1)
    precondition(naps.filter { $0.action == .nap }.map(\.catID) == [beta.id,alpha.id])

    precondition(w.preview(.chase,initiator:alpha.id,partner:beta.id,at:150,cats:pair,bounds:bounds,mode:.companion).isEmpty)
    let corner = [member(alpha,CGPoint(x:93,y:678)), member(beta,CGPoint(x:100,y:679))]
    let chaseStart = w.preview(.chase,initiator:alpha.id,partner:beta.id,at:150,cats:corner,bounds:bounds,mode:.mischief)
    precondition(chaseStart.count == 2)
    let chase = collect(&w,from:150,cats:corner,mode:.mischief).map(\.1)
    let runners = chase.filter { $0.action == .zoom || $0.action == .playTogether }
    precondition(runners.map(\.catID) == [alpha.id,beta.id,beta.id,alpha.id])
    var pos = Dictionary(uniqueKeysWithValues: chaseStart.map { ($0.catID,$0.target!) })
    for cue in runners {
        let old = pos[cue.catID]!, end = cue.target!
        precondition(hypot(end.x-old.x,end.y-old.y) > 98 && end.y > bounds.maxY-100)
        precondition(bounds.insetBy(dx:-0.01,dy:-0.01).contains(end))
        pos[cue.catID] = end
    }
    let tiny = CGRect(x:0,y:0,width:190,height:65)
    precondition(w.preview(.chase,initiator:alpha.id,partner:beta.id,at:190,cats:corner,bounds:tiny,mode:.mischief).isEmpty)
    precondition(w.activeKind == nil)

    // A forced scene can be replayed during a cooldown and replaced midway.
    _ = w.preview(.chase,initiator:alpha.id,partner:beta.id,at:200,cats:pair,bounds:bounds,mode:.mischief)
    precondition(!w.involves(c.id) && w.involves(beta.id))
    let replay = w.preview(.greeting,initiator:beta.id,partner:alpha.id,at:201,cats:pair,bounds:bounds,mode:.mischief)
    precondition(w.activeKind == .greeting && replay.first?.catID == beta.id)
    let taken = [pair[0],member(beta,right,available:false)]
    precondition(w.tick(at:202,cats:taken,bounds:bounds,mode:.mischief,roll:0).isEmpty && w.activeKind == nil)
    _ = w.preview(.chase,initiator:alpha.id,partner:beta.id,at:203,cats:pair,bounds:bounds,mode:.mischief)
    precondition(w.tick(at:204,cats:pair,bounds:bounds,mode:.companion,roll:0).isEmpty && w.activeKind == nil)
    _ = w.preview(.greeting,initiator:alpha.id,partner:beta.id,at:205,cats:pair,bounds:bounds,mode:.companion)
    precondition(w.tick(at:206,cats:[pair[0]],bounds:bounds,mode:.companion,roll:0).isEmpty && w.activeKind == nil)

    let cold = [member(alpha,left,waiting:true),pair[1]]
    let warmStart = w.preview(.greeting,initiator:alpha.id,partner:beta.id,at:210,cats:pair,bounds:bounds,mode:.companion)
    let due = 210 + warmStart[0].duration
    precondition(w.tick(at:due,cats:cold,bounds:bounds,mode:.companion,roll:0).isEmpty)
    precondition(w.tick(at:due+0.2,cats:pair,bounds:bounds,mode:.companion,roll:0).isEmpty)
    w.cancel(at:due+0.3)
    precondition(w.activeIDs.isEmpty && w.tick(at:due+9,cats:pair,bounds:bounds,mode:.companion,roll:0).isEmpty)

    // Same random draws: the independent peer refuses; the sociable peer
    // returns the greeting. No room-crossing event is offered on a diagonal.
    func firstGreeting(_ partner: EncounterCat) -> [EncounterCue] {
        var sim = CatEncounters()
        let subjects = [member(alpha,left),partner]
        _ = sim.tick(at:0,cats:subjects,bounds:bounds,mode:.companion,roll:0)
        // Delay, two pair rankings, initiation, kind, acceptance.
        var rolls = [0.0,0.8,0.0,0.0,0.95,0.20].makeIterator()
        let approach = sim.tick(at:37,cats:subjects,bounds:bounds,mode:.companion,roll:rolls.next() ?? 0)
        guard !approach.isEmpty else { return [] }
        return approach + collect(&sim,from:37,cats:subjects).map(\.1)
    }
    precondition(firstGreeting(member(beta,right)).contains { $0.action == .wander })
    precondition(firstGreeting(member(CatProfile(name:"friendly",personality:friendly),right)).contains { $0.action == .greetRub })
    precondition(firstGreeting(member(beta,CGPoint(x:1250,y:112))).isEmpty)
    print("Encounters passed: staged greetings and refusal, real cheek alignment, protected naps, edge chase, cooldown and interruptions.")
}
