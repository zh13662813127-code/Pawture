import CoreGraphics
import Foundation

func checkVisibleFur() throws {
    let surface = CatTouchSurface(), url = URL(fileURLWithPath: "/fixture/cat.png")
    let bounds = CGRect(x: 20, y: 40, width: 180, height: 180)
    func image(top: Bool) -> CGImage {
        var rgba = [UInt8](repeating: 0, count: 80 * 40 * 4)
        for y in (top ? 0..<20 : 20..<40) {
            for x in 0..<40 { rgba[(y * 80 + x) * 4 + 3] = 255 }
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(width: 80, height: 40, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    func hit(_ x: Int, _ y: Int, facing: CGFloat = 1) -> Bool {
        surface.contains(CGPoint(x: x, y: y), in: bounds, facing: facing, url: url)
    }
    surface.present(image(top: true), for: url)
    precondition(hit(60, 105))
    precondition(!hit(60, 70)) // Transparent padding above the fitted landscape frame.
    precondition(!hit(60, 155))
    precondition(!hit(160, 105))
    precondition(hit(160, 105, facing: -1))
    surface.present(image(top: false), for: url)
    precondition(!hit(60, 105))
    precondition(hit(60, 155))
    print("Visible fur follows frame, aspect fit, vertical orientation and mirroring.")
}
