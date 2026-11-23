import Foundation
import ImageIO
import Vision
import DesktopCatsCore

enum CatPoseAnalyzer {
    private static let jointMap: [(CatJoint, VNAnimalBodyPoseObservation.JointName)] = [
        (.nose, .nose),
        (.neck, .neck),
        (.leftEye, .leftEye),
        (.rightEye, .rightEye),
        (.leftEarTop, .leftEarTop),
        (.leftEarMiddle, .leftEarMiddle),
        (.leftEarBottom, .leftEarBottom),
        (.rightEarTop, .rightEarTop),
        (.rightEarMiddle, .rightEarMiddle),
        (.rightEarBottom, .rightEarBottom),
        (.leftFrontElbow, .leftFrontElbow),
        (.rightFrontElbow, .rightFrontElbow),
        (.leftFrontKnee, .leftFrontKnee),
        (.rightFrontKnee, .rightFrontKnee),
        (.leftFrontPaw, .leftFrontPaw),
        (.rightFrontPaw, .rightFrontPaw),
        (.leftBackElbow, .leftBackElbow),
        (.rightBackElbow, .rightBackElbow),
        (.leftBackKnee, .leftBackKnee),
        (.rightBackKnee, .rightBackKnee),
        (.leftBackPaw, .leftBackPaw),
        (.rightBackPaw, .rightBackPaw),
        (.tailTop, .tailTop),
        (.tailMiddle, .tailMiddle),
        (.tailBottom, .tailBottom)
    ]

    static func analyze(_ imageURL: URL) async throws -> CatRigBlueprint {
        try await Task.detached(priority: .userInitiated) {
            try analyzeSynchronously(imageURL)
        }.value
    }

    static func analyzeSynchronously(_ imageURL: URL) throws -> CatRigBlueprint {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CatPoseError.unreadableImage
        }

        let request = VNDetectAnimalBodyPoseRequest()
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        guard let observation = request.results?.max(by: { $0.confidence < $1.confidence }) else {
            throw CatPoseError.noPoseFound
        }

        var joints: [CatJoint: DesktopCatsCore.NormalizedPoint] = [:]
        for (joint, visionName) in jointMap {
            guard let point = try? observation.recognizedPoint(visionName), point.confidence >= 0.12 else { continue }
            joints[joint] = DesktopCatsCore.NormalizedPoint(
                x: Double(point.location.x),
                y: 1 - Double(point.location.y)
            )
        }
        guard joints.count >= 8 else { throw CatPoseError.tooFewLandmarks }
        return CatRigBlueprint(joints: joints)
    }
}

enum CatPoseError: LocalizedError {
    case unreadableImage
    case noPoseFound
    case tooFewLandmarks

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "无法读取猫咪图片。"
        case .noPoseFound: "没有从这张图片识别到猫咪姿势。"
        case .tooFewLandmarks: "图片中的猫咪姿势不够清晰，暂时无法建立动作骨架。"
        }
    }
}
