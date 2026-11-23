import AppKit
import Combine
import SwiftUI

@MainActor
final class DesktopOverlayController {
    static let shared = DesktopOverlayController()

    private var panel: NSPanel?
    private var touchPanel: NSPanel?
    private var input: DesktopCatInput?
    private var displayID: NSNumber?
    private var visibilityObserver: AnyCancellable?
    private var passthroughObserver: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private weak var store: CatStore?

    func install(store: CatStore) {
        guard self.store == nil else { return }
        self.store = store
        rebuildPanel()
        visibilityObserver = store.$overlayVisible.sink { [weak self] visible in
            self?.setVisible(visible)
        }
        passthroughObserver = store.$clickThrough.sink { [weak self] enabled in
            self?.input?.enable(!enabled && self?.store?.overlayVisible == true)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildPanel() }
        }
    }

    func bringToPointerScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else { return }
        if displayID != id(of: screen) {
            displayID = id(of: screen)
            rebuildPanel()
        }
        store?.overlayVisible = true
    }

    private func id(of screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    private func rebuildPanel() {
        input?.enable(false)
        touchPanel?.orderOut(nil)
        touchPanel = nil
        panel?.orderOut(nil)
        panel = nil
        guard let store, let screen = NSScreen.screens.first(where: { id(of: $0) == displayID })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        displayID = id(of: screen)
        let frame = screen.visibleFrame
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.title = "桌面上的猫咪"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        let handle = CGRect(x: frame.midX, y: frame.midY, width: 1, height: 1)
        let touch = NSPanel(contentRect: handle, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        touch.isOpaque = false
        touch.backgroundColor = .white.withAlphaComponent(0.015)
        touch.hasShadow = false
        touch.level = window.level
        touch.collectionBehavior = window.collectionBehavior
        touch.animationBehavior = .none
        touch.isMovable = false
        touch.becomesKeyOnlyIfNeeded = true
        touch.hidesOnDeactivate = false
        let input = DesktopCatInput(frame: CGRect(origin: .zero, size: handle.size))
        self.input = input
        input.screenFrame = frame
        input.setAccessibilityElement(false)
        touch.contentView = input
        touchPanel = touch
        window.contentView = NSHostingView(rootView: DesktopOverlayView(store: store, screenFrame: frame,
                                                    displayID: displayID?.uint32Value ?? 0, input: input))
        window.setFrame(frame, display: false)
        panel = window
        setVisible(store.overlayVisible)
    }

    private func setVisible(_ visible: Bool) {
        if visible {
            panel?.orderFrontRegardless()
            input?.enable(store?.clickThrough == false)
        } else {
            input?.enable(false)
            panel?.orderOut(nil)
        }
    }
}
