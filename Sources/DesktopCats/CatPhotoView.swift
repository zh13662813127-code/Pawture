import AppKit
import DesktopCatsCore
import SwiftUI

extension Bundle {
    static var catPhotos: Bundle {
        #if PAWTURE_APP_BUNDLE
        return .main
        #else
        return .module
        #endif
    }
}

struct CatPhotoView: View {
    let profile: CatProfile

    private var photo: NSImage? {
        if let imagePath = profile.imagePath, let image = NSImage(contentsOfFile: imagePath) {
            return image
        }
        guard let name = profile.bundleImageName,
              let url = Bundle.catPhotos.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        Group {
            if let photo {
                Image(nsImage: photo)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "cat.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Palette.terracotta.opacity(0.7))
                    .padding(34)
            }
        }
        .shadow(color: .black.opacity(0.17), radius: 9, x: 0, y: 7)
    }
}

enum Palette {
    static let paper = Color(hex: 0xF3F4F0)
    static let sidebar = Color(hex: 0xE7EAE5)
    static let ink = Color(hex: 0x293330)
    static let muted = Color(hex: 0x78817B)
    static let line = Color(hex: 0xD7DDD6)
    static let stageSky = Color(hex: 0xDCE9E7)
    static let stageGround = Color(hex: 0xAFC3B7)
    static let terracotta = Color(hex: 0xC66E49)
    static let leaf = Color(hex: 0x527D69)
    static let butter = Color(hex: 0xE9BD64)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
