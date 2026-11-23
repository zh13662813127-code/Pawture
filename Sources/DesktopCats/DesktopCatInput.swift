import AppKit

struct DesktopCatCommands {
    let pick: (CGPoint) -> UUID?
    let down: (UUID, CGPoint) -> Void
    let move: (UUID, CGPoint) -> Void
    let up: (UUID, Bool) -> Void
    let aside: (UUID) -> Void
}

/// Only a patch of fur under the pointer can own a press. The desktop-sized
/// drawing window remains click-through. AppKit keeps the original drag owner
/// even when the pointer leaves the patch, with no event taps or replayed clicks.
final class DesktopCatInput: NSView {
    var input: DesktopCatCommands?
    var screenFrame = CGRect.zero
    private var globalMoves: Any?
    private var localMoves: Any?
    private var press: (cat: UUID, origin: CGPoint)?
    private var armed: UUID?
    private var dragging = false
    private var menuCat: UUID?
    private var enabled = false

    func enable(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if value {
            globalMoves = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.refresh() }
            localMoves = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.refresh()
                return event
            }
            refresh()
        } else {
            if let globalMoves { NSEvent.removeMonitor(globalMoves) }
            if let localMoves { NSEvent.removeMonitor(localMoves) }
            globalMoves = nil
            localMoves = nil
            if dragging { NSCursor.pop() }
            if let press { input?.up(press.cat, dragging) }
            dragging = false
            press = nil
            disarm()
        }
    }

    private func localPoint(_ screen: CGPoint) -> CGPoint {
        CGPoint(x: screen.x - screenFrame.minX, y: screenFrame.maxY - screen.y)
    }

    func refresh() {
        guard enabled, let window, press == nil, menuCat == nil else { return }
        let screen = NSEvent.mouseLocation
        let p = localPoint(screen)
        guard NSEvent.pressedMouseButtons == 0, screenFrame.contains(screen),
              let pick = input?.pick, let cat = pick(p) else { disarm(); return }
        // Keep the entire input patch inside the outline, including at ears and paws.
        let r: CGFloat = [8.0, 3.0, 0.5].first { radius in
            [-radius, 0, radius].allSatisfy { dx in
                [-radius, 0, radius].allSatisfy { dy in pick(CGPoint(x: p.x+dx, y: p.y+dy)) == cat }
            }
        } ?? 0.5
        let rect = CGRect(x: floor(screen.x - r), y: floor(screen.y - r), width: r*2, height: r*2)
        if rect != window.frame { window.setFrame(rect, display: false) }
        armed = cat
        if !window.isVisible { window.orderFrontRegardless() }
    }

    private func disarm() {
        armed = nil
        if window?.isVisible == true { window?.orderOut(nil) }
    }

    private func point(_ event: NSEvent) -> CGPoint {
        localPoint(window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        guard let cat = input?.pick(p) ?? armed else { return }
        press = (cat, p)
        dragging = false
        input?.down(cat, p)
    }

    private func track(_ event: NSEvent) {
        guard let press else { return }
        let p = point(event)
        if !dragging && hypot(p.x-press.origin.x, p.y-press.origin.y) >= 4 {
            dragging = true
            NSCursor.closedHand.push()
        }
        if dragging { input?.move(press.cat, p) }
    }

    override func mouseDragged(with event: NSEvent) { track(event) }
    override func mouseUp(with event: NSEvent) {
        guard let press else { return }
        track(event)
        self.press = nil
        if dragging { NSCursor.pop() }
        input?.up(press.cat, dragging)
        dragging = false
        refresh()
    }

    override func rightMouseDown(with event: NSEvent) {
        menuCat = input?.pick(point(event)) ?? armed
        guard menuCat != nil else { return }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "让到屏幕另一边", action: #selector(sendAside), keyEquivalent: "")
        item.target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        menuCat = nil
        refresh()
    }

    @objc private func sendAside() {
        if let menuCat { input?.aside(menuCat) }
    }
}
