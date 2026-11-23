import AppKit
import Combine
import CoreImage
import ImageIO
import Vision
import DesktopCatsCore

struct PoseRequest {
    let id = UUID()
    let catID: UUID
    let action: CatAction
}

struct EncounterRequest {
    let id = UUID()
    let kind: EncounterKind
    let initiator: UUID
    let partner: UUID
}

@MainActor
final class CatStore: ObservableObject {
    @Published var cats: [CatProfile]
    @Published var mode: CompanionMode = .companion
    @Published var seasonSetting: SeasonSetting {
        didSet { UserDefaults.standard.set(seasonSetting.rawValue, forKey: "seasonSetting") }
    }
    @Published var overlayVisible = true
    @Published var clickThrough = UserDefaults.standard.bool(forKey: "desktopCatClickThrough") {
        didSet { UserDefaults.standard.set(clickThrough, forKey: "desktopCatClickThrough") }
    }
    @Published var soundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundEnabled, forKey: "petSounds")
            if !soundEnabled { PetVoice.shared.stop() }
        }
    }
    @Published var poseRequest: PoseRequest?
    @Published var encounterRequest: EncounterRequest?
    @Published var latestEvent = "咪咪和宝宝正在看看这里。"

    private let profilesURL: URL

    init() {
        soundEnabled = UserDefaults.standard.object(forKey: "petSounds") as? Bool ?? true
        seasonSetting = UserDefaults.standard.string(forKey: "seasonSetting")
            .flatMap(SeasonSetting.init(rawValue:)) ?? .northern
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DesktopCats", isDirectory: true)
        profilesURL = support.appendingPathComponent("cats.json")

        if let data = try? Data(contentsOf: profilesURL),
           let profiles = try? JSONDecoder().decode([CatProfile].self, from: data),
           !profiles.isEmpty {
            cats = profiles
        } else {
            cats = CatProfile.sampleCats
        }

        Task { await prepareMissingRigBlueprints() }
    }

    func update(_ profile: CatProfile) {
        guard let index = cats.firstIndex(where: { $0.id == profile.id }) else { return }
        cats[index] = profile
        persist()
    }

    func addCat() -> UUID {
        let profile = CatProfile(name: "新猫咪")
        cats.append(profile)
        persist()
        return profile.id
    }

    private func prepareMissingRigBlueprints() async {
        let missing = cats.filter { $0.rigBlueprint == nil }
        for profile in missing {
            guard let url = imageURL(for: profile),
                  let blueprint = try? await CatPoseAnalyzer.analyze(url),
                  let index = cats.firstIndex(where: { $0.id == profile.id }),
                  imageURL(for: cats[index]) == url, cats[index].rigBlueprint == nil else { continue }
            var updated = cats[index]
            updated.rigBlueprint = blueprint
            update(updated)
        }
    }

    func preview(_ action: CatAction, for cat: CatProfile) {
        overlayVisible = true
        poseRequest = PoseRequest(catID: cat.id, action: action)
    }

    func preview(_ kind: EncounterKind, between first: CatProfile, and second: CatProfile) {
        guard first.id != second.id, kind != .chase || mode == .mischief else { return }
        overlayVisible = true
        encounterRequest = EncounterRequest(kind: kind, initiator: first.id, partner: second.id)
    }

    func restingSpot(for id: UUID, display: UInt32, size: CGSize) -> CGPoint? {
        let key = "catBed.\(display).\(id.uuidString)"
        guard let xy = UserDefaults.standard.array(forKey: key) as? [Double], xy.count == 2,
              xy.allSatisfy({ (0...1).contains($0) }) else { return nil }
        return CGPoint(x: xy[0] * size.width, y: xy[1] * size.height)
    }

    func rememberSpot(_ point: CGPoint, for id: UUID, display: UInt32, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        UserDefaults.standard.set([point.x / size.width, point.y / size.height],
                                  forKey: "catBed.\(display).\(id.uuidString)")
    }

    func voice(for action: CatAction, from previous: CatAction) {
        guard soundEnabled else { return }
        switch action {
        case .sleepMurmur: PetVoice.shared.play(previous == .nap ? .murmur : .purr)
        case .petRub, .bellyUp, .loafNuzzle, .bellyNuzzle: PetVoice.shared.play(.purr)
        default: break
        }
    }

    private func imageURL(for profile: CatProfile) -> URL? {
        if let imagePath = profile.imagePath {
            return URL(fileURLWithPath: imagePath)
        }
        guard let name = profile.bundleImageName else { return nil }
        return Bundle.catPhotos.url(forResource: name, withExtension: "png")
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: profilesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(cats)
            try data.write(to: profilesURL, options: .atomic)
        } catch {
            latestEvent = "本机保存失败：\(error.localizedDescription)"
        }
    }
}

enum CatPhotoError: LocalizedError {
    case unreadableImage
    case noForeground
    case cannotRender
    case cannotEncode

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "无法读取这张图片。"
        case .noForeground: "没有识别到清晰的主体，请换一张照片试试。"
        case .cannotRender: "无法生成透明剪影。"
        case .cannotEncode: "无法保存剪影。"
        }
    }
}

enum CatPhotoProcessor {
    static func makeLocalCutout(from sourceURL: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try process(sourceURL: sourceURL)
        }.value
    }

    private static func process(sourceURL: URL) throws -> URL {
        let gainedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if gainedAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let sourceImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800
              ] as CFDictionary) else {
            throw CatPhotoError.unreadableImage
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: sourceImage, orientation: .up)
        try handler.perform([request])
        guard let observation = request.results?.first else { throw CatPhotoError.noForeground }

        let mask = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )
        let original = CIImage(cgImage: sourceImage)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: original.extent)
        let result = original.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: CIImage(cvPixelBuffer: mask)
            ]
        )
        let context = CIContext()
        guard let rendered = context.createCGImage(result, from: original.extent) else {
            throw CatPhotoError.cannotRender
        }
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CatPhotoError.cannotEncode
        }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DesktopCats/Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let destination = support.appendingPathComponent("\(UUID().uuidString).png")
        try data.write(to: destination, options: .atomic)
        return destination
    }
}
