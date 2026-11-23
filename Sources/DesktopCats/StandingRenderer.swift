import CoreGraphics
import DesktopCatsCore
import Foundation

struct StandingRenderer: Sendable {
    private struct Influence: Sendable {
        let index: Int
        let weight: Float
    }

    private struct GridPosition: Sendable {
        let index: Int
        let fraction: Float
    }

    private struct FaceInfluence: Sendable {
        let relative: SIMD2<Float>
        let weight: Float
    }

    private static let gridWidth = 25
    private static let gridHeight = 25
    private static let textureInset = 0.045
    private static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
    ).union(.byteOrder32Big)
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private let original: CGImage
    private let width: Int
    private let height: Int
    private let pixels: Data
    private let joints: [CatJoint]
    private let influences: [[Influence]]
    private let faceInfluences: [FaceInfluence]
    private let faceReference: CatJoint?
    private let columns: [GridPosition]
    private let rows: [GridPosition]
    private let direction: Float

    init(image: CGImage, blueprint: CatRigBlueprint) {
        original = image
        let scale = min(1, 320 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        self.width = width
        self.height = height

        var pixels = Data(count: width * height * 4)
        let decoded = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: Self.colorSpace,
                bitmapInfo: Self.bitmapInfo.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let rect = bounds.insetBy(
                dx: bounds.width * Self.textureInset,
                dy: bounds.height * Self.textureInset
            )
            context.draw(image, in: rect)
            return true
        }
        self.pixels = decoded ? pixels : Data()

        let landmarks = CatJoint.allCases.compactMap { joint -> (CatJoint, NormalizedPoint)? in
            guard let point = blueprint.joints[joint], (0...1).contains(point.x), (0...1).contains(point.y) else {
                return nil
            }
            let scale = 1 - 2 * Self.textureInset
            return (joint, NormalizedPoint(
                x: Self.textureInset + point.x * scale,
                y: Self.textureInset + point.y * scale
            ))
        }
        joints = landmarks.map(\.0)
        direction = blueprint.facesLeft ? -1 : 1

        let edge = Float(max(width, height))
        let aspect = SIMD2(Float(width) / edge, Float(height) / edge)
        let faceLandmarks = landmarks.filter { [.nose, .leftEye, .rightEye].contains($0.0) }
        faceReference = faceLandmarks.first?.0
        let faceCenter = faceLandmarks.reduce(SIMD2<Float>.zero) { sum, landmark in
            sum + SIMD2(Float(landmark.1.x), Float(landmark.1.y))
        } / Float(max(1, faceLandmarks.count))
        var influences: [[Influence]] = []
        var faceInfluences: [FaceInfluence] = []
        for row in 0..<Self.gridHeight {
            for column in 0..<Self.gridWidth {
                let center = SIMD2(
                    Float(column) / Float(Self.gridWidth - 1),
                    Float(row) / Float(Self.gridHeight - 1)
                )
                var weights: [Influence] = []
                var total: Float = 0
                for (index, (joint, point)) in landmarks.enumerated() {
                    let delta = (center - SIMD2(Float(point.x), Float(point.y))) * aspect
                    let radius = Self.radius(for: joint)
                    let falloff = max(0, 1 - (delta.x * delta.x + delta.y * delta.y) / (radius * radius))
                    let weight = falloff * falloff * falloff
                    if weight > 0 {
                        total += weight
                        weights.append(Influence(index: index, weight: weight))
                    }
                }
                let divisor = max(0.7, total)
                influences.append(weights.map { Influence(index: $0.index, weight: $0.weight / divisor) })
                let relative = (center - faceCenter) * SIMD2(Float(width - 1), Float(height - 1))
                let distance = hypot(relative.x, relative.y) / edge
                let p = min(1, max(0, (distance - 0.108) / 0.100))
                let weight: Float = faceLandmarks.count < 2 ? 0 : (1 - p * p * (3 - 2 * p))
                faceInfluences.append(FaceInfluence(relative: relative, weight: weight))
            }
        }
        self.influences = influences
        self.faceInfluences = faceInfluences
        columns = Self.gridPositions(pixels: width, vertices: Self.gridWidth)
        rows = Self.gridPositions(pixels: height, vertices: Self.gridHeight)
    }

    func frame(for motion: CatMotion, phase: Double) -> CGImage {
        guard !pixels.isEmpty else { return original }
        let pose = CatMotionSampler.pose(for: motion, phase: phase)
        func displacement(for joint: CatJoint) -> SIMD2<Float> {
            guard let offset = pose.offsets[joint], offset.x.isFinite, offset.y.isFinite else { return .zero }
            return SIMD2(Float(offset.x) * Float(width) * direction, Float(offset.y) * Float(height))
        }
        let jointOffsets = joints.map(displacement)
        let faceTranslation = faceReference.map(displacement) ?? .zero
        let angle = pose.headTilt.isFinite ? Float(pose.headTilt) * direction : 0
        let rotation = SIMD2(cos(angle) - 1, sin(angle))

        let forwardField = influences.enumerated().map { index, weights in
            let local = weights.reduce(SIMD2<Float>.zero) { result, influence in
                result + jointOffsets[influence.index] * influence.weight
            }
            switch motion {
            case .petRub, .idle, .stalk, .greetSniff, .greetRub: break
            default: return local
            }
            let face = faceInfluences[index]
            guard face.weight > 0 else { return local }
            // Keep the eyes and muzzle on the same rigid transform; blend it into the surrounding fur.
            let deltaX = rotation.x * face.relative.x - rotation.y * face.relative.y
            let deltaY = rotation.y * face.relative.x + rotation.x * face.relative.y
            return Self.mix(local, faceTranslation + SIMD2(deltaX, deltaY), face.weight)
        }
        let inverseField = Self.inverse(forwardField, width: width, height: height)

        var output = Data(count: pixels.count)
        pixels.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                let input = source.bindMemory(to: UInt32.self)
                let result = target.bindMemory(to: UInt32.self)
                for (y, row) in rows.enumerated() {
                    let gridRow = row.index * Self.gridWidth
                    let rowOffset = y * width
                    let horizontal = (gridRow..<(gridRow + Self.gridWidth)).map { index in
                        Self.mix(inverseField[index], inverseField[index + Self.gridWidth], row.fraction)
                    }
                    for (x, column) in columns.enumerated() {
                        let left = horizontal[column.index]
                        let right = horizontal[column.index + 1]
                        if left == .zero && right == .zero {
                            result[rowOffset + x] = input[rowOffset + x]
                            continue
                        }
                        let delta = Self.mix(left, right, column.fraction)
                        result[rowOffset + x] = sample(input, x: Float(x) - delta.x, y: Float(y) - delta.y)
                    }
                }
            }
        }

        guard let provider = CGDataProvider(data: output as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: Self.colorSpace,
                  bitmapInfo: Self.bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else { return original }
        return image
    }

    // Work backward from each output point so the deformed texture stays continuous.
    private static func inverse(_ forward: [SIMD2<Float>], width: Int, height: Int) -> [SIMD2<Float>] {
        let step = SIMD2(
            Float(max(1, width - 1)) / Float(gridWidth - 1),
            Float(max(1, height - 1)) / Float(gridHeight - 1)
        )
        return forward.enumerated().map { index, initial in
            let point = SIMD2(Float(index % gridWidth), Float(index / gridWidth))
            var delta = initial
            for _ in 0..<5 {
                let source = point - delta / step
                let x = coordinate(source.x, vertices: gridWidth)
                let y = coordinate(source.y, vertices: gridHeight)
                let index = y.index * gridWidth + x.index
                let top = mix(forward[index], forward[index + 1], x.fraction)
                let bottom = mix(forward[index + gridWidth], forward[index + gridWidth + 1], x.fraction)
                delta = mix(delta, mix(top, bottom, y.fraction), 0.55)
            }
            return delta
        }
    }

    private static func gridPositions(pixels: Int, vertices: Int) -> [GridPosition] {
        (0..<pixels).map {
            coordinate(Float($0) * Float(vertices - 1) / Float(max(1, pixels - 1)), vertices: vertices)
        }
    }

    private static func coordinate(_ value: Float, vertices: Int) -> GridPosition {
        let value = min(max(0, value), Float(vertices - 1))
        let index = min(Int(value), vertices - 2)
        return GridPosition(index: index, fraction: value - Float(index))
    }

    private static func mix(_ first: SIMD2<Float>, _ second: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
        first + (second - first) * t
    }

    private func sample(_ input: UnsafeBufferPointer<UInt32>, x: Float, y: Float) -> UInt32 {
        guard x > -1, y > -1, x < Float(width), y < Float(height) else { return 0 }
        let x0 = Int(x.rounded(.down))
        let y0 = Int(y.rounded(.down))
        let fx = UInt32(((x - Float(x0)) * 256).rounded())
        let fy = UInt32(((y - Float(y0)) * 256).rounded())
        let index = y0 * width + x0
        let a: UInt32
        let b: UInt32
        let c: UInt32
        let d: UInt32
        if x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height {
            a = input[index]
            b = input[index + 1]
            c = input[index + width]
            d = input[index + width + 1]
        } else {
            a = x0 >= 0 && y0 >= 0 ? input[index] : 0
            b = x0 + 1 < width && y0 >= 0 ? input[index + 1] : 0
            c = x0 >= 0 && y0 + 1 < height ? input[index + width] : 0
            d = x0 + 1 < width && y0 + 1 < height ? input[index + width + 1] : 0
        }
        if (a | b | c | d) == 0 { return 0 }
        return Self.mixRGBA(Self.mixRGBA(a, b, fx), Self.mixRGBA(c, d, fx), fy)
    }

    // Mix two channels at a time, using the alternate bytes for fixed-point precision.
    private static func mixRGBA(_ a: UInt32, _ b: UInt32, _ fraction: UInt32) -> UInt32 {
        let mask: UInt32 = 0x00FF00FF
        let inverse = 256 - fraction
        let rb = ((a & mask) * inverse + (b & mask) * fraction + 0x00800080) >> 8
        let ga = (((a >> 8) & mask) * inverse + ((b >> 8) & mask) * fraction + 0x00800080) >> 8
        return (rb & mask) | ((ga & mask) << 8)
    }

    private static func radius(for joint: CatJoint) -> Float {
        switch joint {
        case .nose, .leftEye, .rightEye: 0.16
        case .neck: 0.14
        case .leftEarTop, .rightEarTop: 0.085
        case .leftEarMiddle, .rightEarMiddle, .leftEarBottom, .rightEarBottom: 0.074
        case .leftFrontPaw, .rightFrontPaw, .leftBackPaw, .rightBackPaw: 0.105
        case .tailTop, .tailMiddle, .tailBottom: 0.105
        default: 0.105
        }
    }
}
