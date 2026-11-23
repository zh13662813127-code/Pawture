import DesktopCatsCore
import ImageIO
import SwiftUI

/// Two views of the same cat (the controls and the desktop) share the same local rig.
struct RiggedCatPhotoView: View {
    let profile: CatProfile
    let action: CatAction
    let elapsed: TimeInterval
    var onVisibleFrame: ((CGImage) -> Void)? = nil
    var onClipReady: ((CatAction) -> Void)? = nil

    @State private var displayed: PuppetClip?
    @State private var previous: PuppetClip?
    @State private var loadedAt: Double = 0
    @State private var skipEntry = false
    private var request: ClipKey? {
        guard let url = profile.photoURL, profile.rigBlueprint != nil else { return nil }
        return ClipKey(url: url, motion: action.motion)
    }
    private enum LoadID: Hashable { case clip(ClipKey), noModel(CatAction) }

    var body: some View {
        Group {
            if let displayed, displayed.key.url == profile.photoURL {
                let age = max(0, ProcessInfo.processInfo.systemUptime - loadedAt)
                let joinsAtRest = previous?.key.motion.joins(displayed.key.motion) == true
                let fade = joinsAtRest ? 1 : min(age / (previous?.key.motion.isRest == true ? 0.48 : 0.22), 1)
                let motion = displayed.key.motion
                let clipClock = !motion.playsOnce || motion.isRest || motion == .greetSniff || motion == .greetRub
                let time = displayed.key != request ? age : (clipClock ? min(max(elapsed,0),age) : max(0,elapsed))
                let currentFrame = displayed.frame(at: time, skipEntry:skipEntry)
                let outgoingFrame = previous.flatMap { clip in
                    clip.key.url == displayed.key.url && fade < 1 ? clip.departure(at:fade) : nil
                }
                let visibleFrame = fade < 0.5 ? (outgoingFrame ?? currentFrame) : currentFrame
                ZStack {
                    if let outgoingFrame { picture(outgoingFrame).opacity(1-fade) }
                    picture(currentFrame).opacity(outgoingFrame == nil ? 1 : fade)
                }
                .onChange(of: ObjectIdentifier(visibleFrame), initial: true) { _, _ in onVisibleFrame?(visibleFrame) }
            } else {
                CatPhotoView(profile: profile)
            }
        }
        .task(id: request.map(LoadID.clip) ?? .noModel(action)) {
            let requestedAction = action
            guard let request, let rig = profile.rigBlueprint else {
                displayed = nil
                previous = nil
                if !Task.isCancelled { onClipReady?(requestedAction) }
                return
            }
            let loaded = await PhotoPuppetLibrary.shared.clip(for: request, rig: rig)
            guard !Task.isCancelled else { return }
            guard let clip = loaded else {
                onClipReady?(requestedAction)
                return
            }
            previous = displayed
            skipEntry = displayed?.key.url == clip.key.url && displayed?.key.motion.joins(clip.key.motion) == true
            displayed = clip
            loadedAt = ProcessInfo.processInfo.systemUptime
            onClipReady?(requestedAction)
        }
    }

    private func picture(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }
}

extension CatProfile {
    var photoURL: URL? {
        if let imagePath { return URL(fileURLWithPath: imagePath) }
        return bundleImageName.flatMap { Bundle.catPhotos.url(forResource: $0, withExtension: "png") }
    }
}

struct ClipKey: Hashable, Sendable {
    let url: URL
    let motion: CatMotion
}

struct PuppetClip: Sendable {
    let key: ClipKey
    let entry: [CGImage]
    let loop: [CGImage]
    let duration: Double

    func frame(at time: Double, skipEntry: Bool = false) -> CGImage {
        let entryDuration = entry.isEmpty || skipEntry ? 0.0 : (key.motion == .bellyUp ? 0.9 : 1.45)
        if time < entryDuration { return entry[Int(max(0, time) / entryDuration * Double(entry.count))] }
        let t = max(0, time - entryDuration) / duration
        let phase = key.motion.playsOnce ? min(t, 0.99999) : t - floor(t)
        return loop[min(loop.count - 1, Int(phase * Double(loop.count)))]
    }

    func departure(at progress: Double) -> CGImage {
        if key.motion.playsOnce { return loop[loop.count-1] }
        guard !entry.isEmpty else { return loop[0] }
        return entry[Int(Double(entry.count - 1) * (1 - min(max(progress, 0), 1)))]
    }
}

private actor PhotoPuppetLibrary {
    static let shared = PhotoPuppetLibrary()
    private final class Model {
        let image: CGImage
        let rig: CatRigBlueprint
        let standing: StandingRenderer
        lazy var rest = CatRestRenderer(image: image, blueprint: rig)

        init(image: CGImage, rig: CatRigBlueprint) {
            self.image = image
            self.rig = rig
            standing = StandingRenderer(image: image, blueprint: rig)
        }
    }
    private var models: [URL: Model] = [:]
    private let clips = NSCache<NSString, ClipBox>()
    private var rendering: [ClipKey: Task<PuppetClip,Never>] = [:]

    init() { clips.totalCostLimit = 96 * 1_024 * 1_024 }

    func clip(for key: ClipKey, rig: CatRigBlueprint) async -> PuppetClip? {
        let cacheKey = (key.url.path + "|" + key.motion.rawValue) as NSString
        if let cached = clips.object(forKey: cacheKey) { return cached.clip }
        if let pending = rendering[key] { return await pending.value }
        guard let model = model(at: key.url, rig: rig) else { return nil }
        let rest = key.motion.isRest ? model.rest : nil
        let standing = model.standing
        let task = Task.detached(priority: Task.currentPriority) {
            Self.render(key:key,rest:rest,standing:standing)
        }
        rendering[key] = task
        let clip = await task.value
        rendering[key] = nil
        let bytes = (clip.entry + clip.loop).reduce(0) { $0 + $1.height * $1.bytesPerRow }
        clips.setObject(ClipBox(clip), forKey: cacheKey, cost: bytes)
        if key.motion == .curlSleep {
            Task(priority:.low) {
                _ = await self.clip(for:ClipKey(url:key.url,motion:.sleepMurmur), rig:rig)
            }
        }
        return clip
    }

    private static func render(key: ClipKey, rest: CatRestRenderer?, standing: StandingRenderer) -> PuppetClip {
        let motion = key.motion
        var entry = [CGImage]()
        var loop = [CGImage]()
        let count = motion == .wakeStretch || motion == .petRub || motion == .greetRub ? 30 :
            (motion.isRest || motion == .greetSniff ? 18 : 16)
        if let rest {
            if !motion.playsOnce {
                entry = (0..<20).compactMap {
                    rest.frame(for: motion, phase: 0, unfold: 1 - Double($0) / 19)
                }
            }
            loop = (0..<count).compactMap {
                rest.frame(for: motion, phase: Double($0) / Double(motion.playsOnce ? count-1 : count))
            }
        }
        if loop.isEmpty {
            let intervals = motion.playsOnce ? count - 1 : count
            loop = (0..<count).map { standing.frame(for: motion, phase: Double($0) / Double(intervals)) }
        }
        return PuppetClip(key: key, entry: entry, loop: loop, duration: motion.seconds)
    }

    private func model(at url: URL, rig: CatRigBlueprint) -> Model? {
        if let cached = models[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 960
              ] as CFDictionary) else { return nil }
        let result = Model(image: image, rig: rig)
        if models.count >= 6, let first = models.keys.first { models.removeValue(forKey: first) }
        models[url] = result
        return result
    }

    private final class ClipBox: NSObject {
        let clip: PuppetClip
        init(_ clip: PuppetClip) { self.clip = clip }
    }
}

extension CatAction {
    var motion: CatMotion {
        switch self {
        case .nap: .curlSleep
        case .sleepMurmur: .sleepMurmur
        case .wakeStretch: .wakeStretch
        case .loaf: .loaf
        case .loafNuzzle: .loafNuzzle
        case .bellyNuzzle: .bellyNuzzle
        case .petRub: .petRub
        case .greetSniff: .greetSniff
        case .greetRub: .greetRub
        case .watch, .groom: .idle
        case .stalk: .stalk
        case .wander, .approach: .walk
        case .chase, .zoom, .playTogether: .run
        case .pounce: .pounce
        case .startle: .startle
        case .bellyUp: .bellyUp
        }
    }
}

private extension CatMotion {
    var isRest: Bool { [.curlSleep, .sleepMurmur, .wakeStretch, .loaf, .loafNuzzle, .bellyUp, .bellyNuzzle].contains(self) }
    var playsOnce: Bool {
        [.startle, .pounce, .stalk, .sleepMurmur, .wakeStretch, .loafNuzzle, .bellyNuzzle, .greetSniff, .greetRub].contains(self)
    }

    func joins(_ next: CatMotion) -> Bool {
        if self == .greetSniff { return next == .greetRub }
        if self == .wakeStretch { return next == .loaf }
        if self == .loaf { return next == .loafNuzzle }
        if self == .loafNuzzle { return next == .loaf }
        if self == .bellyUp { return next == .bellyNuzzle }
        if self == .bellyNuzzle { return next == .bellyUp }
        return (self == .curlSleep || self == .sleepMurmur) &&
            (next == .curlSleep || next == .sleepMurmur || next == .wakeStretch)
    }
}

extension CatMotion {
    var seconds: Double {
        switch self {
        case .idle, .curlSleep, .loaf: 4.2
        case .sleepMurmur: 2.3
        case .wakeStretch: 3.4
        case .loafNuzzle, .bellyNuzzle: 1.8
        case .stalk: 0.85
        case .walk: 0.85
        case .run: 0.55
        case .startle: 0.8
        case .pounce: 1.0
        case .bellyUp: 2.8
        case .petRub: 2.5
        case .greetSniff: 0.95
        case .greetRub: 1.45
        }
    }
}
