import Foundation

/// Landmark coordinates use normalized image space: (0, 0) is the top-left,
/// (1, 1) is the bottom-right, x increases rightward, and y increases downward.
public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Names correspond to Vision's animal body pose landmark names where available.
public enum CatJoint: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case nose
    case neck
    case leftEye
    case rightEye
    case leftEarTop
    case leftEarMiddle
    case leftEarBottom
    case rightEarTop
    case rightEarMiddle
    case rightEarBottom
    case leftFrontElbow
    case rightFrontElbow
    case leftFrontKnee
    case rightFrontKnee
    case leftFrontPaw
    case rightFrontPaw
    case leftBackElbow
    case rightBackElbow
    case leftBackKnee
    case rightBackKnee
    case leftBackPaw
    case rightBackPaw
    case tailTop
    case tailMiddle
    case tailBottom
}

/// A photo-derived base pose. Missing or low-confidence landmarks may be omitted.
public struct CatRigBlueprint: Codable, Equatable, Sendable {
    public var joints: [CatJoint: NormalizedPoint]

    public init(joints: [CatJoint: NormalizedPoint]) {
        self.joints = joints
    }

    public var facesLeft: Bool {
        guard let nose = joints[.nose],
              let body = joints[.tailBottom] ?? joints[.neck] else { return false }
        return nose.x < body.x - 0.04
    }
}

public enum CatMotion: String, CaseIterable, Codable, Equatable, Sendable {
    case idle
    case loaf
    case stalk
    case walk
    case run
    case startle
    case pounce
    case curlSleep
    case sleepMurmur
    case wakeStretch
    case loafNuzzle
    case bellyNuzzle
    case bellyUp
    case petRub
    case greetSniff
    case greetRub
}

/// Additive offsets in normalized image space, suitable for applying to rig joints.
public struct CatRigPose: Codable, Equatable, Sendable {
    public var offsets: [CatJoint: NormalizedPoint]

    public init(offsets: [CatJoint: NormalizedPoint] = [:]) {
        self.offsets = offsets
    }
}

public enum CatMotionSampler {
    /// Returns additive offsets in top-left-origin normalized image coordinates.
    /// `phase` is clamped to 0...1, and identical inputs always produce identical output.
    public static func offsets(
        for action: CatMotion,
        phase: Double,
        intensity: Double = 1
    ) -> [CatJoint: NormalizedPoint] {
        pose(for: action, phase: phase, intensity: intensity).offsets
    }

    /// `headTilt` is clockwise radians for a right-facing photo.
    public static func pose(
        for action: CatMotion,
        phase: Double,
        intensity: Double = 1
    ) -> (offsets: [CatJoint: NormalizedPoint], headTilt: Double) {
        let phase = min(max(phase, 0), 1)
        let intensity = min(max(intensity, 0), 1)
        let duration: Double
        switch action {
        case .idle: duration = 1 / 0.28
        case .walk: duration = 1.25
        case .run: duration = 1 / 1.7
        case .startle: duration = 1
        case .pounce: duration = 1.2
        case .stalk, .loaf: duration = 1
        case .curlSleep, .sleepMurmur, .wakeStretch, .loafNuzzle, .bellyNuzzle: duration = 1
        case .bellyUp: duration = 1
        case .petRub, .greetSniff, .greetRub: duration = 1
        }
        let pose = sample(action, at: phase * duration)
        let offsets = pose.offsets.mapValues {
            NormalizedPoint(x: $0.x * intensity, y: $0.y * intensity)
        }
        return (offsets, pose.headTilt * intensity)
    }

    private static func sample(
        _ motion: CatMotion, at time: Double
    ) -> (offsets: [CatJoint: NormalizedPoint], headTilt: Double) {
        let t = max(0, time)
        let cycle = t * 2 * .pi
        var offsets: [CatJoint: NormalizedPoint] = [:]
        var headTilt = 0.0

        func ease(_ start: Double, _ end: Double, _ value: Double) -> Double {
            let p = min(1, max(0, (value - start) / (end - start)))
            return p * p * (3 - 2 * p)
        }

        func put(_ joints: [CatJoint], x: Double = 0, y: Double = 0) {
            for joint in joints { offsets[joint] = NormalizedPoint(x: x, y: y) }
        }

        func head(x: Double = 0, y: Double = 0, earLift: Double = 0) {
            put([.nose, .leftEye, .rightEye, .leftEarBottom, .rightEarBottom], x: x, y: y)
            put([.leftEarMiddle, .rightEarMiddle], x: x, y: y - earLift * 0.5)
            put([.leftEarTop, .rightEarTop], x: x, y: y - earLift)
            put([.neck], x: x * 0.42, y: y * 0.62)
        }

        func gait(stride: Double, swing: Double, reach: Double, lift: Double) {
            let leadingLift = -lift * max(0, swing)
            let trailingLift = -lift * max(0, -swing)
            put([.leftFrontPaw, .rightBackPaw], x: reach * stride, y: leadingLift)
            put([.rightFrontPaw, .leftBackPaw], x: -reach * stride, y: trailingLift)
            put([.leftFrontKnee, .rightBackKnee], x: reach * stride * 0.55, y: leadingLift * 0.45)
            put([.rightFrontKnee, .leftBackKnee], x: -reach * stride * 0.55, y: trailingLift * 0.45)
            put([.leftFrontElbow, .rightBackElbow], x: reach * stride * 0.22, y: leadingLift * 0.16)
            put([.rightFrontElbow, .leftBackElbow], x: -reach * stride * 0.22, y: trailingLift * 0.16)
        }

        func tail(sway: Double, lift: Double) {
            put([.tailBottom], x: sway * 0.15, y: -lift * 0.16)
            put([.tailMiddle], x: sway * 0.60, y: -lift * 0.56)
            put([.tailTop], x: sway, y: -lift)
        }

        switch motion {
        case .idle:
            let breath = sin(cycle * 0.28)
            let phase = t * 0.28
            let listen = ease(0.38, 0.48, phase) - ease(0.58, 0.78, phase)
            head(x: 0.007 * listen, y: -0.003 * breath, earLift: 0.003 * breath)
            put([.neck, .leftFrontElbow, .rightFrontElbow], y: -0.006 * breath)
            put([.rightEarTop], x: -0.012 * listen, y: -0.008 * listen - 0.006 * breath)
            headTilt = -0.035 * listen
            tail(sway: 0.004 * breath, lift: 0.010 * breath)
        case .walk:
            let step = cycle * 0.8
            gait(stride: sin(step), swing: -cos(step), reach: 0.040, lift: 0.030)
            head(y: 0.009 * abs(sin(step)))
            tail(sway: 0.022 * cos(step), lift: 0.016 * sin(step))
        case .run:
            let step = cycle * 1.7
            gait(stride: sin(step), swing: -cos(step), reach: 0.062, lift: 0.051)
            head(x: 0.009 * abs(sin(step)), y: -0.017 * abs(sin(step)), earLift: 0.004 * sin(step))
            tail(sway: 0.035 * cos(step), lift: 0.031 * sin(step))
        case .startle:
            let jolt = min(1, t / 0.08) * exp(-pow((t - 0.18) * 8, 2))
            head(x: -0.018 * jolt, y: -0.043 * jolt, earLift: 0.019 * jolt)
            tail(sway: -0.026 * jolt, lift: 0.061 * jolt)
            put([.leftFrontPaw, .rightFrontPaw], x: -0.019 * jolt, y: -0.025 * jolt)
        case .pounce:
            let crouch = min(1, t / 0.16) * exp(-pow((t - 0.24) * 8, 2))
            let launch = exp(-pow((t - 0.57) * 6, 2))
            head(x: 0.035 * launch, y: 0.066 * crouch - 0.048 * launch, earLift: -0.008 * crouch)
            put([.leftFrontElbow, .rightFrontElbow], x: 0.021 * launch, y: 0.027 * crouch - 0.027 * launch)
            put([.leftFrontKnee, .rightFrontKnee], x: 0.040 * launch, y: -0.045 * launch)
            put([.leftFrontPaw, .rightFrontPaw], x: 0.064 * launch, y: -0.069 * launch)
            put([.leftBackPaw, .rightBackPaw], x: -0.033 * launch, y: 0.022 * launch)
            tail(sway: -0.028 * launch, lift: 0.045 * launch + 0.016 * crouch)
        case .stalk:
            let lower = ease(0, 0.62, t)
            let focus = ease(0.61, 0.82, t)
            head(x: 0.023 * lower + 0.006 * focus, y: 0.046 * lower, earLift: -0.006 * lower)
            headTilt = 0.16 * lower - 0.045 * focus
            put([.neck], x: 0.015 * lower, y: 0.038 * lower)
            put([.leftFrontElbow, .rightFrontElbow], x: -0.013 * lower, y: 0.024 * lower)
            put([.leftFrontKnee, .rightFrontKnee], x: 0.009 * lower, y: 0.012 * lower)
            put([.rightEarTop], x: 0.010 * focus, y: 0.018 * lower - 0.009 * focus)
            tail(sway: 0.008 * lower, lift: -0.014 * lower)
        case .loaf:
            let breathe = 1 - cos(cycle)
            head(y: -0.0015 * breathe)
            put([.neck, .leftFrontElbow, .rightFrontElbow], y: -0.0025 * breathe)
        case .curlSleep:
            let curl = 1 - exp(-t * 2.4)
            put([.nose, .leftEye, .rightEye], x: -0.018 * curl, y: 0.025 * curl)
            put([.leftFrontPaw, .rightFrontPaw, .leftBackPaw, .rightBackPaw], x: -0.018 * curl, y: 0.018 * curl)
            put([.tailTop, .tailMiddle, .tailBottom], x: -0.025 * curl, y: 0.015 * curl)
            let breath = sin(cycle * 0.2)
            put([.neck, .leftFrontElbow, .rightFrontElbow], y: -0.004 * breath)
        case .sleepMurmur:
            let tilt = ease(0.12, 0.36, t) - ease(0.58, 0.95, t)
            let ear = ease(0.01, 0.13, t) - ease(0.16, 0.34, t)
            head(x:0.006*tilt,y:-0.008*tilt)
            put([.rightEarTop],x:-0.030*ear,y:0.018*ear)
            headTilt = -0.084*tilt
        case .wakeStretch:
            let first = ease(0.07,0.43,t)-ease(0.76,1,t)
            let second = ease(0.28,0.60,t)-ease(0.66,0.89,t)
            let settle = ease(0.20,0.56,t)-ease(0.70,0.95,t)
            head(x:0.010*settle,y:0.009*settle)
            put([.rightFrontElbow],x:0.016*first,y:0.010*first)
            put([.rightFrontPaw],x:0.052*first,y:0.002*first)
            put([.leftFrontElbow],x:0.010*second,y:0.006*second)
            put([.leftFrontPaw],x:0.034*second,y:0.003*second)
            tail(sway:-0.015*settle,lift:0.003*settle)
        case .loafNuzzle, .bellyNuzzle:
            let turn = ease(0.04,0.43,t)-ease(0.60,1,t)
            head(x:0.020*turn,y:-0.012*turn)
            headTilt = -0.13*turn
            if motion == .bellyNuzzle {
                put([.rightFrontKnee,.leftFrontKnee],x:-0.012*turn)
                put([.rightFrontPaw,.leftFrontPaw],x:-0.024*turn,y:0.018*turn)
            }
        case .bellyUp:
            let roll = min(1, t / 0.45)
            put([.neck, .nose], y: 0.025 * roll)
            put([.leftFrontPaw, .rightFrontPaw], x: 0.025 * sin(cycle * 0.35), y: -0.028 * roll)
            put([.leftBackPaw, .rightBackPaw], x: -0.018 * roll, y: -0.014 * roll)
            put([.tailTop, .tailMiddle], y: 0.018 * sin(cycle * 0.3))
        case .petRub:
            // Lead with the lower cheek; slide up against contact before releasing.
            let reach = ease(0.04, 0.31, t) - ease(0.69, 0.94, t)
            let glide = ease(0.32, 0.61, t) - ease(0.67, 0.93, t)
            let shoulder = ease(0.27, 0.55, t) - ease(0.72, 0.98, t)
            let tailFollow = ease(0.38, 0.64, t) - ease(0.76, 1, t)
            head(x: 0.047 * reach + 0.009 * glide, y: 0.011 * reach - 0.035 * glide)
            headTilt = -0.30 * reach + 0.095 * glide
            put([.neck], x: 0.018 * shoulder, y: -0.010 * shoulder)
            put([.leftFrontElbow, .rightFrontElbow], x: 0.015 * shoulder, y: -0.007 * shoulder)
            tail(sway: -0.017 * tailFollow, lift: 0.020 * tailFollow)
        case .greetSniff:
            let reach = ease(0.05, 0.43, t)
            let breathWindow = ease(0.44, 0.56, t) - ease(0.74, 0.88, t)
            let sniff = sin(4 * cycle) * breathWindow
            head(x: 0.041 * reach + 0.0033 * sniff, y: -0.012 * reach - 0.0034 * sniff)
            headTilt = 0.075 * reach
        case .greetRub:
            let lower = ease(0.02, 0.31, t)
            let brush = ease(0.29, 0.65, t)
            let release = 1 - ease(0.67, 0.98, t)
            let shoulder = ease(0.26, 0.58, t) - ease(0.66, 1, t)
            head(
                x: (0.041 + 0.017 * lower - 0.011 * brush) * release,
                y: (-0.012 + 0.043 * lower - 0.015 * brush) * release,
                earLift: -0.012 * lower * release
            )
            headTilt = (0.075 - 0.36 * lower + 0.09 * brush) * release
            put([.neck], x: 0.041 * 0.42 * release + 0.012 * shoulder,
                y: -0.012 * 0.62 * release + 0.020 * shoulder)
            put([.leftFrontElbow, .rightFrontElbow], x: 0.010 * shoulder, y: 0.010 * shoulder)
            tail(sway: -0.012 * shoulder, lift: 0.016 * shoulder)
        }
        return (offsets, headTilt)
    }
}
