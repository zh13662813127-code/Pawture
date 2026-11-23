import AppKit
import DesktopCatsCore
import SwiftUI

private struct OverlayPose {
    var origin: CGPoint
    var destination: CGPoint
    var action: CatAction
    var facing: CGFloat
    var started: Date
    var travel: TimeInterval
    var ready: Date
    var nextAction: CatAction?
    var isPreview = false
    var visit: VisitInterest?
    var napEnd: Date?
    var bellyEnd: Date?
    var waitingForClip = false
    var fromEncounter = false

    func position(at now: Date) -> CGPoint {
        guard travel > 0 else { return destination }
        let t = min(1, max(0, now.timeIntervalSince(started) / travel))
        let k = t * t * (3 - 2 * t)
        return CGPoint(x: origin.x + (destination.x - origin.x) * k,
                       y: origin.y + (destination.y - origin.y) * k)
    }
}

private final class PointerSession {
    var tracker = PettingTracker()
    var touching: UUID?
    var stillness = CursorStillness()
    var toy = ToyInvitation()
    var playing: UUID?
    var quietUntil = 0.0
    var visits = VisitBudget(at: Date.now.timeIntervalSinceReferenceDate)
    var beds: [UUID: CGPoint] = [:]
    var surfaces: [UUID: CatTouchSurface] = [:]
    var taps: [UUID: CatTapResponder] = [:]
    var held: (cat: UUID, offset: CGPoint)?
    var placedUntil: [UUID: Date] = [:]
    var encounters = CatEncounters()
    var contactOffsets: [UUID: CGPoint] = [:]

    func reset() {
        tracker = PettingTracker()
        touching = nil
        stillness = CursorStillness()
        toy = ToyInvitation()
        playing = nil
        held = nil
    }
}

struct DesktopOverlayView: View {
    @ObservedObject var store: CatStore
    let screenFrame: CGRect
    let displayID: UInt32
    let input: DesktopCatInput
    @State private var poses: [UUID: OverlayPose] = [:]
    @State private var pointer = PointerSession()
    private let side: CGFloat = 180

    private var cursorPoint: CGPoint? {
        let p = NSEvent.mouseLocation
        guard screenFrame.contains(p) else { return nil }
        return CGPoint(x: p.x - screenFrame.minX, y: screenFrame.maxY - p.y)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !store.overlayVisible)) { frame in
            ZStack {
                Color.clear
                ForEach(store.cats) { cat in
                    if let pose = poses[cat.id] {
                        RiggedCatPhotoView(profile: cat, action: pose.action,
                                           elapsed: max(0, frame.date.timeIntervalSince(pose.started)),
                                           onVisibleFrame: {
                                               pointer.surfaces[cat.id]?.present($0, for: cat.photoURL)
                                           },
                                           onClipReady: { acknowledgeClip($0, cat: cat) })
                            .frame(width: side, height: side)
                            .scaleEffect(x: pose.facing, y: 1)
                            .overlay(alignment: .bottom) {
                                Text(cat.name)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Palette.ink)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.white.opacity(0.8), in: Capsule())
                                    .offset(y: 9)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isImage)
                            .accessibilityLabel(cat.name)
                            .accessibilityValue(pose.action.title)
                            .accessibilityIdentifier("desktop-cat-\(cat.id)")
                            .position(pose.position(at: frame.date))
                    }
                }
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .allowsHitTesting(false)
        .onAppear { input.input = DesktopCatCommands(pick: pick, down: grab, move: carry, up: release, aside: sendAside) }
        .onDisappear { input.input = nil }
        .task(id: store.overlayVisible) {
            cancelEncounter(at: .now)
            pointer.reset()
            guard store.overlayVisible else { return }
            seed()
            while !Task.isCancelled {
                tick(.now)
                do { try await Task.sleep(for: .milliseconds(60)) } catch { break }
            }
        }
        .onChange(of: store.cats) { _, _ in seed() }
        .onChange(of: store.poseRequest?.id) { _, _ in preview() }
        .onChange(of: store.encounterRequest?.id) { _, _ in previewEncounter() }
        .onChange(of: store.mode) { _, mode in
            if mode == .companion && pointer.encounters.activeKind == .chase { cancelEncounter(at: .now) }
            pointer.playing = nil
            pointer.toy = ToyInvitation()
            for cat in store.cats where !(poses[cat.id]?.action.allowed(in: mode) ?? true) {
                begin(.watch, for: cat, at: .now)
            }
        }
    }

    private func seed() {
        let ids = Set(store.cats.map(\.id))
        poses = poses.filter { ids.contains($0.key) }
        pointer.surfaces = pointer.surfaces.filter { ids.contains($0.key) }
        for cat in store.cats where pointer.surfaces[cat.id] == nil {
            pointer.surfaces[cat.id] = CatTouchSurface()
        }
        pointer.contactOffsets = Dictionary(uniqueKeysWithValues: store.cats.compactMap { cat in
            pointer.surfaces[cat.id]?.cheekOffset(profile: cat, url: cat.photoURL, facingRight: true, side: side)
                .map { (cat.id, $0) }
        })
        for (i, cat) in store.cats.enumerated() where poses[cat.id] == nil {
            // Alternate two spots along each bottom edge before using the upper corners.
            let inset = side * (0.60 + 0.8 * CGFloat((i / 2) % 2))
            let initial = CGPoint(x: i.isMultiple(of: 2) ? inset : screenFrame.width - inset,
                                  y: (i / 4).isMultiple(of: 2) ? screenFrame.height - side * 0.65 : side * 0.65)
            let point = clamp(store.restingSpot(for: cat.id, display: displayID, size: screenFrame.size) ?? initial)
            pointer.beds[cat.id] = point
            let now = Date.now
            poses[cat.id] = OverlayPose(origin: point, destination: point, action: .loaf, facing: 1,
                                       started: now, travel: 0, ready: now.addingTimeInterval(15 + Double(i) * 4))
        }
    }

    private func tick(_ now: Date) {
        let t = now.timeIntervalSinceReferenceDate
        defer { input.refresh() }
        let blocked = NSEvent.pressedMouseButtons != 0 || PreviewPettingInput.InputView.ownsPointer(NSEvent.mouseLocation)
        let cursor = blocked ? nil : cursorPoint
        pointer.stillness.observe(cursor, at: t)
        let hit = cursor.flatMap { p in store.cats.reversed().first { hitTest(cat: $0, at: p, time: now) } }
        if let hit, pointer.touching != hit.id {
            pointer.tracker = PettingTracker()
            pointer.touching = hit.id
        }
        if let cat = store.cats.first(where: { $0.id == pointer.touching }), let pose = poses[cat.id],
           let action = pointer.tracker.sample(hit == nil ? nil : cursor, at: t,
                       action: [.greetRub, .greetSniff].contains(pose.action) ? .watch : pose.action,
                       personality: cat.personality, buttonDown: blocked, roll: Double.random(in: 0..<1)) {
            cancelEncounter(involving: cat.id, at: now)
            pointer.playing = nil
            pointer.toy = ToyInvitation()
            store.voice(for: action, from: pose.action)
            begin(action, for: cat, at: now)
        }
        if hit == nil && !pointer.tracker.retainsContact { pointer.touching = nil }

        trackInvitation(cursor: hit == nil ? cursor : nil, at: now)
        tickEncounters(at: now, blocked: NSEvent.pressedMouseButtons != 0)
        for cat in store.cats {
            guard pointer.held?.cat != cat.id, !pointer.encounters.involves(cat.id), let pose = poses[cat.id] else { continue }
            if let visit = pose.visit {
                switch visit.response(cursor: cursor, touching: hit?.id == cat.id, at: t) {
                case .leave:
                    let bed = pointer.beds[cat.id]
                    begin(.wander, for: cat, at: now, target: bed, next: .loaf)
                case .acceptContact:
                    begin(.petRub, for: cat, at: now, hold: 4.2, next: nil)
                case .stay where t >= visit.arrival && pose.action == .approach:
                    begin(.petRub, for: cat, at: now, hold: 4.2, visit: visit)
                case .stay: break
                }
                continue
            }
            let justPlaced = (pointer.placedUntil[cat.id] ?? .distantPast) > now
            if !justPlaced, !pose.isPreview, pose.nextAction == nil, !pointer.toy.hasAttention, let cursor,
               pointer.visits.invitesFromRest(cat, action: pose.action, time: t, stableFor: pointer.stillness.seconds,
                    distance: cursor.distance(to: pose.position(at: now)), roll: Double.random(in: 0..<1)),
               startVisit(for: cat, cursor: cursor, at: now) { continue }
            guard pose.ready <= now, !(pointer.playing == cat.id && pointer.toy.hasAttention) else { continue }
            if let next = pose.nextAction, next.allowed(in: store.mode) {
                begin(next, for: cat, at: now, target: next == .zoom ? randomPoint() : nil)
                continue
            }
            if let next = BehaviorEngine.afterTouch(pose.action, napExpired: pose.napEnd.map { $0 <= now } ?? false,
                                                    bellyExpired: pose.bellyEnd.map { $0 <= now } ?? false) {
                let remaining = next == .nap ? pose.napEnd?.timeIntervalSince(now)
                    : (next == .bellyUp ? pose.bellyEnd?.timeIntervalSince(now) : nil)
                begin(next, for: cat, at: now, hold: remaining)
                continue
            }
            if justPlaced { continue }
            let origin = pose.position(at: now)
            let available = cursor.map { pointer.visits.available(at: t, stableFor: pointer.stillness.seconds,
                                                      distance: origin.distance(to: $0)) } ?? false
            let action = BehaviorEngine.ambient(personality: cat.personality, mode: store.mode,
                winter: winter(at: now),
                visitAvailable: available && !pointer.toy.hasAttention,
                roll: Double.random(in: 0..<1))
            if action == .nap || action == .loaf, let home = pointer.beds[cat.id], home.distance(to: origin) > 24 {
                begin(.wander, for: cat, at: now, target: home, next: action)
            } else if action == .approach, let cursor {
                if !startVisit(for: cat, cursor: cursor, at: now) { begin(.watch, for: cat, at: now) }
            } else if action == .zoom {
                begin(.startle, for: cat, at: now, hold: 0.48, next: .zoom)
            } else {
                let target = destination(for: action, from: origin, cursor: cursor)
                begin(action, for: cat, at: now, target: target)
            }
        }
    }

    private var encounterBounds: CGRect {
        let min = clamp(.zero), max = clamp(CGPoint(x: screenFrame.width, y: screenFrame.height))
        return CGRect(x: min.x, y: min.y, width: max.x - min.x, height: max.y - min.y)
    }

    private func encounterCats(at now: Date, blocked: Bool = false) -> [EncounterCat] {
        store.cats.compactMap { cat in
            guard cat.rigBlueprint != nil, let pose = poses[cat.id] else { return nil }
            let active = pointer.encounters.involves(cat.id)
            // A sleeper with only a moment left should wake on its original clock.
            let waking = pose.action == .nap && pose.ready.timeIntervalSince(now) < 12
            let available = pointer.held?.cat != cat.id && pose.visit == nil &&
                (active || (!blocked && pointer.touching != cat.id && !pose.isPreview &&
                    pose.nextAction == nil && pose.travel <= now.timeIntervalSince(pose.started) &&
                    (pointer.placedUntil[cat.id] ?? .distantPast) <= now)) &&
                !(pointer.playing == cat.id && pointer.toy.hasAttention) && !waking
            return EncounterCat(profile: cat, position: pose.position(at: now), action: pose.action,
                                available: available, contactOffset: pointer.contactOffsets[cat.id],
                                waitingForClip: pose.waitingForClip)
        }
    }

    private func tickEncounters(at now: Date, blocked: Bool) {
        guard store.cats.count >= 2 || pointer.encounters.activeKind != nil else { return }
        let before = pointer.encounters.activeIDs
        let cats = encounterCats(at: now, blocked: blocked)
        let cues = pointer.encounters.tick(at: now.timeIntervalSinceReferenceDate, cats: cats,
                                           bounds: encounterBounds, mode: store.mode, roll: .random(in: 0..<1))
        applyEncounter(cues, at: now)
        if !before.isEmpty && pointer.encounters.activeKind == nil {
            if cues.isEmpty { releaseEncounter(before, at: now) }
            let names = store.cats.filter { before.contains($0.id) }.map(\.name).joined(separator: "和")
            if !names.isEmpty {
                store.latestEvent = before.allSatisfy { poses[$0]?.action == .nap }
                    ? names + "挨着睡着了。" : names + "又各自歇下了。"
            }
        }
    }

    private func previewEncounter() {
        guard let request = store.encounterRequest, store.overlayVisible, pointer.held == nil,
              request.kind != .chase || store.mode == .mischief else { return }
        let now = Date.now
        cancelEncounter(at: now)
        pointer.reset()
        seed()
        let cats = encounterCats(at: now)
        let cues = pointer.encounters.preview(request.kind, initiator: request.initiator, partner: request.partner,
                                at: now.timeIntervalSinceReferenceDate, cats: cats, bounds: encounterBounds, mode: store.mode)
        if cues.isEmpty {
            let pair = cats.filter { $0.profile.id == request.initiator || $0.profile.id == request.partner }
            if pointer.encounters.activeKind == .sharedNap { store.latestEvent = "两只猫已经挨着睡了。" }
            else if request.kind == .sharedNap && pair.count == 2 && pair.allSatisfy({ $0.action == .nap }) {
                store.latestEvent = "两只猫都已经睡着了。"
            } else { store.latestEvent = "这里没有足够的空间让两只猫互动。" }
        }
        applyEncounter(cues, at: now)
    }

    private func applyEncounter(_ cues: [EncounterCue], at now: Date) {
        guard !cues.isEmpty else { return }
        for cue in cues {
            guard let cat = store.cats.first(where: { $0.id == cue.catID }) else { continue }
            // Duration zero deliberately starts a normal, full-length rest.
            begin(cue.action, for: cat, at: now, target: cue.target,
                  hold: cue.duration > 0 ? cue.duration : nil, lookingAt: cue.lookAt,
                  encounter: true, movementTime: cue.duration > 0 ? cue.duration : nil)
        }
        let actors = store.cats.filter { pointer.encounters.involves($0.id) }
        if actors.count == 2, let kind = pointer.encounters.activeKind {
            let line = actors.map(\.name).joined(separator: "和") + " · " + kind.title
            if store.latestEvent != line { store.latestEvent = line }
        }
    }

    private func cancelEncounter(involving id: UUID? = nil, at now: Date) {
        if let id, !pointer.encounters.involves(id) { return }
        let participants = pointer.encounters.activeIDs
        guard !participants.isEmpty else { return }
        pointer.encounters.cancel(at: now.timeIntervalSinceReferenceDate)
        releaseEncounter(participants, at: now)
    }

    private func releaseEncounter(_ ids: Set<UUID>, at now: Date) {
        for cat in store.cats where ids.contains(cat.id) {
            guard let pose = poses[cat.id], pose.fromEncounter else { continue }
            // A sleeping partner did not volunteer to wake up when the visitor left.
            if pose.action != .nap { begin(.watch, for: cat, at: now) }
        }
    }

    private func pick(_ p: CGPoint) -> UUID? {
        let now = Date.now
        for cat in store.cats.reversed() {
            guard let pose = poses[cat.id] else { continue }
            let center = pose.position(at: now)
            let bounds = CGRect(x: center.x-side/2, y: center.y-side/2, width: side, height: side)
            guard bounds.insetBy(dx: -1, dy: -12).contains(p) else { continue }
            if pointer.surfaces[cat.id]?.contains(p, in: bounds, facing: pose.facing, url: cat.photoURL) == true { return cat.id }
            // The visible name is also a handle, including before a photo has a rig.
            let labelWidth = (cat.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]).width + 14
            if abs(p.x - center.x) <= labelWidth / 2, (side/2-10...side/2+10).contains(p.y-center.y) { return cat.id }
        }
        return nil
    }

    private func grab(_ id: UUID, at p: CGPoint) {
        cancelEncounter(involving: id, at: .now)
        guard var pose = poses[id] else { return }
        let c = pose.position(at: .now)
        pointer.reset()
        pointer.held = (id, CGPoint(x: c.x - p.x, y: c.y - p.y))
        pose.origin = c
        pose.destination = c
        pose.travel = 0
        pose.visit = nil
        poses[id] = pose
    }

    private func carry(_ id: UUID, to p: CGPoint) {
        guard let held = pointer.held, held.cat == id, var pose = poses[id] else { return }
        let c = clamp(CGPoint(x: p.x + held.offset.x, y: p.y + held.offset.y))
        pose.origin = c
        pose.destination = c
        poses[id] = pose
    }

    private func release(_ id: UUID, moved: Bool) {
        guard pointer.held?.cat == id else { return }
        pointer.held = nil
        guard let cat = store.cats.first(where: { $0.id == id }), let pose = poses[id] else { return }
        let now = Date.now
        if moved {
            remember(pose.destination, for: id, at: now)
            let sleeping = pose.action == .nap || pose.action == .sleepMurmur
            if pose.action == .nap {
                var rest = pose
                rest.ready = max(rest.ready, now.addingTimeInterval(120))
                rest.nextAction = nil
                poses[id] = rest
            } else {
                begin(sleeping ? .nap : .loaf, for: cat, at: now, hold: 120)
            }
        } else if cat.rigBlueprint != nil, let response = pointer.taps[id, default: CatTapResponder()]
                    .tap(at: ProcessInfo.processInfo.systemUptime, action: pose.action, personality: cat.personality,
                         roll: .random(in: 0..<1)) {
            store.voice(for: response, from: pose.action)
            begin(response, for: cat, at: now)
        }
    }

    private func remember(_ point: CGPoint, for id: UUID, at now: Date) {
        pointer.beds[id] = point
        pointer.placedUntil[id] = now.addingTimeInterval(120)
        store.rememberSpot(point, for: id, display: displayID, size: screenFrame.size)
    }

    private func sendAside(_ id: UUID) {
        cancelEncounter(involving: id, at: .now)
        guard let cat = store.cats.first(where: { $0.id == id }), let pose = poses[id] else { return }
        let now = Date.now, c = pose.position(at: now)
        let edge: CGFloat = c.x < screenFrame.width/2 ? screenFrame.width : 0
        let occupied = poses.compactMap { $0.key == id ? nil : $0.value.position(at: now) }
        let options = [c.y] + stride(from: side/2, through: screenFrame.height, by: side/2).map { $0 }
        let spots = options.map { clamp(CGPoint(x: edge, y: $0)) }
        let clear = spots.filter { p in occupied.allSatisfy { $0.distance(to: p) >= side * 0.85 } }
        let goal = clear.min { abs($0.y - c.y) < abs($1.y - c.y) } ?? spots[0]
        remember(goal, for: id, at: now)
        pointer.reset()
        begin(.wander, for: cat, at: now, target: goal, next: .loaf)
    }

    private func startVisit(for cat: CatProfile, cursor: CGPoint, at now: Date) -> Bool {
        guard let origin = poses[cat.id]?.position(at: now),
              let goal = cheekPosition(for: cat, origin: origin, cursor: cursor) else { return false }
        let t = now.timeIntervalSinceReferenceDate
        pointer.visits.recordVisit(at: t, roll: .random(in: 0..<1))
        let visit = VisitInterest(cursor: cursor, arrival: t + travelDuration(origin.distance(to: goal), for: .approach))
        begin(.approach, for: cat, at: now, target: goal, visit: visit, lookingAt: cursor)
        return true
    }

    private func trackInvitation(cursor: CGPoint?, at now: Date) {
        let t = now.timeIntervalSinceReferenceDate
        guard t >= pointer.quietUntil else { return }
        func eligible(_ cat: CatProfile) -> Bool {
            guard !pointer.encounters.involves(cat.id), let pose = poses[cat.id], !pose.isPreview,
                  pose.nextAction == nil, pose.visit == nil else { return false }
            return pose.action.isAvailableForPlay || (pose.action == .stalk && pointer.playing == cat.id)
        }
        // One toy gesture belongs to a single cat; an attentive cat can lose
        // the toy, but another cat cannot inherit half of its gesture.
        let current = store.cats.first { $0.id == pointer.playing && eligible($0) }
        let nearest = cursor.flatMap { p in
            store.cats.filter(eligible).min {
                (poses[$0.id]?.position(at: now).distance(to: p) ?? .infinity) <
                (poses[$1.id]?.position(at: now).distance(to: p) ?? .infinity)
            }
        }
        let cat = pointer.toy.hasAttention ? current : nearest
        guard let cat, let pose = poses[cat.id] else {
            pointer.playing = nil
            pointer.toy = ToyInvitation()
            return
        }
        if pointer.playing != cat.id { pointer.toy = ToyInvitation() }
        pointer.playing = cat.id
        let distance = cursor.map { pose.position(at: now).distance(to: $0) } ?? .infinity
        guard let response = pointer.toy.sample(cursor, distance: distance, awake: eligible(cat), mode: store.mode,
                    at: t, personality: cat.personality, roll: Double.random(in: 0..<1)) else { return }
        switch response {
        case .watch, .stalk:
            begin(response, for: cat, at: now, hold: 3, lookingAt: cursor)
        case .pounce:
            let goal = cursor.map { p in CGPoint(x: p.x + (pose.position(at: now).x < p.x ? -42 : 42), y: p.y + 14) }
            begin(.pounce, for: cat, at: now, target: goal, hold: 1.2, lookingAt: cursor)
            pointer.quietUntil = t + 11
        default:
            begin(.watch, for: cat, at: now, hold: 7.5)
            pointer.quietUntil = t + 7
        }
    }

    private func cheekPosition(for cat: CatProfile, origin: CGPoint, cursor: CGPoint) -> CGPoint? {
        let candidates = [true, false].compactMap { faceRight -> CGPoint? in
            let sign: CGFloat = faceRight ? 1 : -1
            let cheek = pointer.surfaces[cat.id]?.cheekOffset(profile: cat, url: cat.photoURL, facingRight: faceRight, side: side)
                ?? CGPoint(x: sign * side * 0.38, y: -side * 0.14)
            let center = clamp(CGPoint(x: cursor.x - cheek.x - sign * 12, y: cursor.y - cheek.y))
            let gap = sign * (cursor.x - center.x - cheek.x)
            guard (7...21).contains(gap), abs(center.y + cheek.y - cursor.y) < 23,
                  (cursor.x >= origin.x) == faceRight else { return nil }
            return center
        }
        return candidates.min { $0.distance(to: origin) < $1.distance(to: origin) }
    }

    private func winter(at date: Date) -> Double {
        store.seasonSetting.winterBias(month: Calendar.current.component(.month, from: date))
    }

    private func travelDuration(_ distance: CGFloat, for action: CatAction) -> Double {
        distance < 1 ? 0 : min(6.5, max(0.25, distance / action.speed))
    }

    private func hitTest(cat: CatProfile, at p: CGPoint, time: Date) -> Bool {
        guard cat.rigBlueprint != nil, let pose = poses[cat.id] else { return false }
        let center = pose.position(at: time)
        let bounds = CGRect(x: center.x - side/2, y: center.y - side/2, width: side, height: side)
        return pointer.surfaces[cat.id]?.contains(p, in: bounds, facing: pose.facing, url: cat.photoURL) == true
    }

    private func preview() {
        guard store.overlayVisible, let request = store.poseRequest, request.action.allowed(in: store.mode),
              let cat = store.cats.first(where: { $0.id == request.catID }) else { return }
        seed()
        let now = Date.now
        cancelEncounter(involving: cat.id, at: now)
        let origin = poses[cat.id]?.position(at: now) ?? .zero
        let target = destination(for: request.action, from: origin, cursor: cursorPoint)
        if pointer.touching == cat.id { pointer.tracker = PettingTracker(); pointer.touching = nil }
        begin(request.action, for: cat, at: now, target: target, preview: true)
    }

    private func begin(_ action: CatAction, for cat: CatProfile, at now: Date, target: CGPoint? = nil,
                       hold: TimeInterval? = nil, next: CatAction? = nil, preview: Bool = false,
                       visit: VisitInterest? = nil, lookingAt: CGPoint? = nil,
                       encounter: Bool = false, movementTime: TimeInterval? = nil) {
        guard let previous = poses[cat.id] else { return }
        let origin = previous.position(at: now)
        let dest = clamp(target ?? origin)
        let dx = (lookingAt?.x ?? dest.x) - origin.x
        let sourceFacesLeft = (cat.rigBlueprint?.joints[.nose]?.x ?? 0.7) < (cat.rigBlueprint?.joints[.tailBottom]?.x ?? 0.3)
        let facing: CGFloat = abs(dx) < 6 ? previous.facing : ((dx < 0) == sourceFacesLeft ? 1 : -1)
        let distance = dest.distance(to: origin)
        let travel = distance < 1 ? 0 : (movementTime ?? travelDuration(distance, for: action))
        let duration = hold ?? (travel > 0 ? travel : BehaviorEngine.hold(action, personality: cat.personality,
                                                         winter: winter(at: now), roll: .random(in: 0..<1)))
        let socialGesture = encounter && (action == .greetSniff || action == .greetRub)
        let waiting = cat.rigBlueprint != nil && (action.waitsForTouchClip || socialGesture)
            && (action != previous.action || previous.waitingForClip)
        poses[cat.id] = OverlayPose(origin: origin, destination: dest, action: action, facing: facing,
                                   started: now, travel: travel, ready: waiting ? .distantFuture : now.addingTimeInterval(max(duration, travel)),
                                   nextAction: next, isPreview: preview, visit: visit,
                                   napEnd: action == .sleepMurmur ? (previous.action == .nap ? previous.ready : previous.napEnd) : nil,
                                   bellyEnd: action == .bellyNuzzle ? (previous.action == .bellyUp ? previous.ready : previous.bellyEnd) : nil,
                                   waitingForClip: waiting, fromEncounter: encounter)
        if !encounter && pointer.encounters.activeKind == nil { store.latestEvent = cat.name + action.title + "。" }
    }

    private func acknowledgeClip(_ action: CatAction, cat: CatProfile) {
        guard var pose = poses[cat.id], pose.waitingForClip, pose.action == action else { return }
        let now = Date.now
        let seconds = pose.fromEncounter ? action.motion.seconds :
            BehaviorEngine.hold(action, personality: cat.personality, winter: winter(at: now), roll: 0)
        pose.ready = now.addingTimeInterval(seconds)
        pose.waitingForClip = false
        poses[cat.id] = pose
    }

    private func destination(for action: CatAction, from p: CGPoint, cursor: CGPoint?) -> CGPoint? {
        switch action {
        case .chase, .pounce: return cursor ?? randomPoint()
        case .wander, .zoom: return randomPoint()
        case .approach, .stalk:
            guard let cursor else { return action == .approach ? randomPoint() : nil }
            let dx = p.x < cursor.x ? -1.0 : 1.0
            return CGPoint(x: cursor.x + dx * (action == .stalk ? 100 : 58), y: cursor.y + 14)
        default: return nil
        }
    }

    private func randomPoint() -> CGPoint {
        let a = clamp(.zero)
        let b = clamp(CGPoint(x: screenFrame.width, y: screenFrame.height))
        return CGPoint(x: .random(in: a.x...b.x), y: .random(in: a.y...b.y))
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        let mx = min(screenFrame.width / 2, side / 2)
        let my = min(screenFrame.height / 2, side / 2 + 10)
        return CGPoint(x: min(max(mx, p.x), screenFrame.width - mx),
                       y: min(max(my, p.y), screenFrame.height - my))
    }
}

private extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
}

private extension CatAction {
    func allowed(in mode: CompanionMode) -> Bool {
        switch self {
        case .chase, .stalk, .pounce, .zoom, .playTogether, .startle: mode == .mischief
        default: true
        }
    }

    var speed: CGFloat {
        switch self {
        case .zoom, .chase, .pounce: 720
        case .playTogether: 350
        case .stalk: 105
        default: 175
        }
    }

    var isAvailableForPlay: Bool { [.watch, .loaf, .wander, .groom].contains(self) }
}
