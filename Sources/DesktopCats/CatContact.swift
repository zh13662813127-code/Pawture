import AppKit
import DesktopCatsCore
import ImageIO
import SwiftUI

extension CatAction {
    var waitsForTouchClip: Bool { [.sleepMurmur, .wakeStretch, .loafNuzzle, .bellyNuzzle].contains(self) }
}

private struct FurMask {
    let size: CGSize
    let alpha: [UInt8]
    static let edge = 64

    init?(_ image: CGImage) {
        size = CGSize(width: image.width, height: image.height)
        let n = Self.edge
        var buffer = [UInt8](repeating: 0, count: 4 * n * n)
        let ok = buffer.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: n, height: n,
                    bitsPerComponent: 8, bytesPerRow: 4 * n, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        alpha = stride(from: 3, to: buffer.count, by: 4).map { buffer[$0] }
    }

    func contains(_ p: CGPoint, in bounds: CGRect, facing: CGFloat) -> Bool {
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let u = (p.x - bounds.midX) * facing / (size.width * scale) + 0.5
        let v = (p.y - bounds.midY) / (size.height * scale) + 0.5
        guard (0..<1).contains(u), (0..<1).contains(v) else { return false }
        return alpha[Int(v * CGFloat(Self.edge)) * Self.edge + Int(u * CGFloat(Self.edge))] > 40
    }

    func cheekOffset(profile: CatProfile, facingRight: Bool, side: CGFloat) -> CGPoint {
        let nose = profile.rigBlueprint?.joints[.nose] ?? NormalizedPoint(x: 0.65, y: 0.35)
        let n = Self.edge
        let row = min(n - 1, max(0, Int(nose.y * CGFloat(n))))
        let sourceFacesRight = nose.x >= (profile.rigBlueprint?.joints[.tailBottom]?.x ?? 0.36)
        let opaque = (0..<n).filter { alpha[row * n + $0] > 40 }
        let edge = sourceFacesRight ? opaque.last : opaque.first
        let x = edge.map { (CGFloat($0) + 0.5) / CGFloat(n) } ?? nose.x
        let scale = side / max(size.width, size.height)
        return CGPoint(x: (x - 0.5) * size.width * scale * (facingRight == sourceFacesRight ? 1 : -1),
                       y: (nose.y - 0.5) * size.height * scale)
    }
}

/// Only sample alpha while the pointer is inside this cat's picture. The view supplies
/// the frame actually on screen, including during a turn, a crossfade or a cold render.
final class CatTouchSurface {
    private var frame: CGImage?
    private var frameURL: URL?
    private var frameMask: FurMask?
    private var portraitURL: URL?
    private var portrait: FurMask?

    func present(_ image: CGImage, for url: URL?) {
        guard frame !== image || frameURL != url else { return }
        frame = image
        frameURL = url
        frameMask = nil
    }

    private func original(_ url: URL?) -> FurMask? {
        if portraitURL != url {
            portraitURL = url
            portrait = nil
            if let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 128
               ] as CFDictionary) {
                portrait = FurMask(image)
            }
        }
        return portrait
    }

    func contains(_ point: CGPoint, in bounds: CGRect, facing: CGFloat = 1, url: URL?) -> Bool {
        guard bounds.contains(point), let url else { return false }
        if let frame, frameURL == url {
            if frameMask == nil { frameMask = FurMask(frame) }
            return frameMask?.contains(point, in: bounds, facing: facing) == true
        }
        return original(url)?.contains(point, in: bounds, facing: facing) == true
    }

    func cheekOffset(profile: CatProfile, url: URL?, facingRight: Bool, side: CGFloat) -> CGPoint? {
        original(url)?.cheekOffset(profile: profile, facingRight: facingRight, side: side)
    }
}

/// A pressed stroke pets the cat in the preview; on the desktop it picks the cat up.
struct PreviewPettingInput: NSViewRepresentable {
    var sample: (CGPoint?, CGRect) -> Void
    var tap: (CGPoint, CGRect) -> Void

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.sample = sample
        view.tap = tap
    }

    final class InputView: NSView {
        private static let visibleInputs = NSHashTable<InputView>.weakObjects()
        var sample: ((CGPoint?, CGRect) -> Void)?
        var tap: ((CGPoint, CGRect) -> Void)?
        private var pressOrigin: CGPoint?
        private var hoverTimer: Timer?
        private var wasOver = false
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            hoverTimer?.invalidate()
            hoverTimer = nil
            if window != nil {
                Self.visibleInputs.add(self)
                let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                    guard let self else { timer.invalidate(); return }
                    MainActor.assumeIsolated { self.pollHover() }
                }
                RunLoop.main.add(timer, forMode: .common)
                hoverTimer = timer
            } else {
                Self.visibleInputs.remove(self)
            }
        }

        static func ownsPointer(_ screenPoint: CGPoint) -> Bool {
            visibleInputs.allObjects.contains { $0.exposedPoint(screenPoint) != nil }
        }

        // Ask AppKit which window a click would actually reach. This also works for
        // a visible, unfocused preview without touching the window or stealing focus.
        private func exposedPoint(_ screen: CGPoint) -> CGPoint? {
            guard let window, window.isVisible, !window.isMiniaturized, !isHiddenOrHasHiddenAncestor else { return nil }
            let p = convert(window.convertPoint(fromScreen: screen), from: nil)
            guard visibleRect.contains(p),
                  NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0) == window.windowNumber else { return nil }
            return p
        }

        private func pollHover() {
            if NSEvent.pressedMouseButtons != 0 { return }
            if let p = exposedPoint(NSEvent.mouseLocation) {
                sample?(p, bounds)
                wasOver = true
            } else if wasOver {
                sample?(nil, bounds)
                wasOver = false
            }
        }

        private func feed(_ event: NSEvent) { sample?(convert(event.locationInWindow, from: nil), bounds) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            pressOrigin = convert(event.locationInWindow, from: nil)
            feed(event)
        }
        override func mouseDragged(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            if let o = pressOrigin, hypot(p.x-o.x, p.y-o.y) > 4 { pressOrigin = nil }
            feed(event)
        }
        override func mouseUp(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            if let o = pressOrigin, hypot(p.x-o.x, p.y-o.y) <= 4 { tap?(o, bounds) }
            pressOrigin = nil
            sample?(nil, bounds)
        }
    }
}
