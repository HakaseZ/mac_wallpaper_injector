import AppKit
import Foundation

// MARK: - App 入口(无 SwiftUI 宏,CLT 可编译)

@main
enum MWIPanelMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        _ = delegate // keep alive
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let vc = MainViewController()
        window = NSWindow(contentViewController: vc)
        window.title = "MWI 壁纸管理"
        window.setContentSize(NSSize(width: 860, height: 560))
        window.minSize = NSSize(width: 720, height: 480)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
