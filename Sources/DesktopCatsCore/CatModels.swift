import Foundation

public enum CatTrait: String, CaseIterable, Codable, Identifiable, Sendable {
    case playful
    case clingy
    case sleepy
    case curious
    case independent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .playful: "淘气"
        case .clingy: "粘人"
        case .sleepy: "爱睡"
        case .curious: "好奇"
        case .independent: "独立"
        }
    }
}

public struct CatPersonality: Codable, Equatable, Sendable {
    public var playful: Double
    public var clingy: Double
    public var sleepy: Double
    public var curious: Double
    public var independent: Double

    public init(
        playful: Double = 0.5,
        clingy: Double = 0.5,
        sleepy: Double = 0.5,
        curious: Double = 0.5,
        independent: Double = 0.5
    ) {
        self.playful = playful
        self.clingy = clingy
        self.sleepy = sleepy
        self.curious = curious
        self.independent = independent
    }

    public func value(for trait: CatTrait) -> Double {
        switch trait {
        case .playful: playful
        case .clingy: clingy
        case .sleepy: sleepy
        case .curious: curious
        case .independent: independent
        }
    }

    public mutating func set(_ value: Double, for trait: CatTrait) {
        let value = min(max(value, 0), 1)
        switch trait {
        case .playful: playful = value
        case .clingy: clingy = value
        case .sleepy: sleepy = value
        case .curious: curious = value
        case .independent: independent = value
        }
    }
}

public struct CatProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var bundleImageName: String?
    public var imagePath: String?
    public var personality: CatPersonality
    public var rigBlueprint: CatRigBlueprint?

    public init(
        id: UUID = UUID(),
        name: String,
        bundleImageName: String? = nil,
        imagePath: String? = nil,
        personality: CatPersonality = CatPersonality(),
        rigBlueprint: CatRigBlueprint? = nil
    ) {
        self.id = id
        self.name = name
        self.bundleImageName = bundleImageName
        self.imagePath = imagePath
        self.personality = personality
        self.rigBlueprint = rigBlueprint
    }

    public static let sampleCats = [
        CatProfile(
            name: "咪咪",
            bundleImageName: "cat-sitting",
            personality: CatPersonality(playful: 0.42, clingy: 0.78, sleepy: 0.68, curious: 0.56, independent: 0.24)
        ),
        CatProfile(
            name: "宝宝",
            bundleImageName: "cat-walking",
            personality: CatPersonality(playful: 0.86, clingy: 0.38, sleepy: 0.3, curious: 0.74, independent: 0.62)
        )
    ]
}

public enum CompanionMode: String, CaseIterable, Identifiable, Sendable {
    case companion
    case mischief

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .companion: "陪伴"
        case .mischief: "捣乱"
        }
    }
}

public enum CatAction: String, CaseIterable, Identifiable, Sendable {
    case nap
    case loaf
    case groom
    case watch
    case wander
    case approach
    case chase
    case stalk
    case pounce
    case zoom
    case playTogether
    case greetSniff
    case greetRub
    case startle
    case petRub
    case bellyUp
    case sleepMurmur
    case wakeStretch
    case loafNuzzle
    case bellyNuzzle

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .nap: "蜷着睡觉"
        case .loaf: "趴着歇会儿"
        case .groom: "舔舔爪子"
        case .watch: "抬头张望"
        case .wander: "四处看看"
        case .approach: "凑过来"
        case .chase: "追上去了"
        case .stalk: "压低身子"
        case .pounce: "扑了一下"
        case .zoom: "突然乱跑"
        case .playTogether: "互相追逐"
        case .greetSniff: "碰碰鼻子"
        case .greetRub: "蹭蹭脸颊"
        case .startle: "吓了一跳"
        case .petRub: "蹭蹭你的手"
        case .bellyUp: "翻出肚皮"
        case .sleepMurmur: "睡梦中呼噜了一下"
        case .wakeStretch: "睡醒伸了个懒腰"
        case .loafNuzzle: "趴着把脸靠了过来"
        case .bellyNuzzle: "仰着轻轻蜷了蜷爪"
        }
    }
}

public enum SeasonSetting: String, CaseIterable, Identifiable, Sendable {
    case northern, southern, off
    public var id: Self { self }
    public var title: String {
        switch self {
        case .northern: "北半球"
        case .southern: "南半球"
        case .off: "关闭"
        }
    }

    public func winterBias(month: Int) -> Double {
        guard self != .off, (1...12).contains(month) else { return 0 }
        let cycle = 2 * Double.pi * Double(month - 1) / 12
        return cos(cycle) * (self == .northern ? 1 : -1)
    }
}

public enum BehaviorEngine {
    // Pointer gestures and visits are separate state machines. A basic movement
    // or a scattered sequence of clicks cannot start pointer play here.
    public static func ambient(personality p: CatPersonality, mode: CompanionMode,
                               winter: Double, visitAvailable: Bool, roll: Double) -> CatAction {
        let climate = min(1, max(-1, winter))
        var choices: [(CatAction, Double)] = [
            (.nap, (0.18 + 0.60 * p.sleepy) * (1 + climate * 0.12)),
            (.loaf, (0.28 + 0.22 * p.sleepy) * (1 + climate * 0.05)),
            (.watch, 0.23 + 0.23 * p.curious),
            (.groom, 0.10 + 0.10 * p.independent),
            (.wander, 0.12 + 0.27 * p.playful + 0.11 * p.independent)
        ]
        if visitAvailable {
            choices.append((.approach, 0.05 + 0.27 * p.clingy * (1 - 0.5 * p.independent)))
        }
        if mode == .mischief {
            choices.append((.zoom, 0.008 + 0.06 * p.playful))
        }
        let total = choices.reduce(0) { $0 + $1.1 }
        var draw = min(0.9999999, max(0, roll)) * total
        for (action, weight) in choices {
            draw -= weight
            if draw < 0 { return action }
        }
        return .loaf
    }

    public static func hold(_ action: CatAction, personality p: CatPersonality,
                            winter: Double, roll: Double) -> TimeInterval {
        let r = max(0, min(1, roll))
        switch action {
        case .nap: return (132 + 162 * p.sleepy + 144 * r) * (1 + winter * 0.09)
        case .loaf: return 27 + 36 * p.sleepy + 54 * r
        case .watch: return 14 + 26 * r
        case .groom: return 8 + 14 * r
        case .bellyUp: return 8 + 5 * r
        case .petRub: return 4 + 2 * r
        case .sleepMurmur: return 2.3
        case .wakeStretch: return 3.4
        case .loafNuzzle, .bellyNuzzle: return 1.8
        default: return 2 + 4 * r
        }
    }

    public static func afterTouch(_ action: CatAction, napExpired: Bool = false, bellyExpired: Bool = false) -> CatAction? {
        switch action {
        case .nap: .wakeStretch
        case .sleepMurmur: napExpired ? .wakeStretch : .nap
        case .wakeStretch, .bellyUp, .loafNuzzle: .loaf
        case .bellyNuzzle: bellyExpired ? .loaf : .bellyUp
        case .petRub: .watch
        default: nil
        }
    }

    static func offersBelly(_ p: CatPersonality, roll: Double) -> Bool {
        roll < 0.07 + 0.20 * p.clingy + 0.08 * p.playful - 0.04 * p.independent
    }

    /// The first gentle touch always leaves the cat asleep. Only sustained
    /// petting draws one of these responses for the session.
    public static func sustainedSleepResponse(personality p: CatPersonality, roll: Double) -> CatAction {
        let stay = 0.46 + 1.28 * p.sleepy
        let rollOver = 0.14 + 0.76 * p.clingy + 0.17 * p.playful
        let wake = 0.20 + 0.68 * p.curious + 0.38 * p.independent + 0.18 * p.playful
        let draw = min(1, max(0, roll)) * (stay + rollOver + wake)
        if draw < stay { return .sleepMurmur }
        return draw < stay + rollOver ? .bellyUp : .wakeStretch
    }
}
