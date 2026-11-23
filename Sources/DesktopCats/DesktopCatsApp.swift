import SwiftUI
import AppKit
import DesktopCatsCore

@main
struct DesktopCatsApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var appLifecycle
    private var store: CatStore { appLifecycle.store }

    var body: some Scene {
        WindowGroup("爪影 Pawture", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 1060, minHeight: 700)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 790)

        MenuBarExtra {
            MenuBarCommands(store: store)
        } label: {
            Image(systemName: "pawprint.fill")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    let store = CatStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DesktopOverlayController.shared.install(store: store)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private struct MenuBarCommands: View {
    @ObservedObject var store: CatStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("显示桌面猫咪", isOn: $store.overlayVisible)
        Toggle("点击穿透桌面猫咪", isOn: $store.clickThrough)
        Toggle("猫咪声音", isOn: $store.soundEnabled)
        if NSScreen.screens.count > 1 {
            Button("把猫咪叫到这块屏幕") { DesktopOverlayController.shared.bringToPointerScreen() }
        }
        Picker("互动模式", selection: $store.mode) {
            ForEach(CompanionMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        Divider()
        Button("打开控制面板") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("退出爪影") {
            NSApplication.shared.terminate(nil)
        }
    }
}
