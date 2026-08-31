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
        setupMainMenu(exportTarget: vc)
        window = NSWindow(contentViewController: vc)
        window.title = "MWI 壁纸管理"
        window.setContentSize(NSSize(width: 860, height: 560))
        window.minSize = NSSize(width: 720, height: 480)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 主菜单:App 菜单 + 日志菜单(导出日志;日志不再放界面)
    private func setupMainMenu(exportTarget: MainViewController) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 MWI 壁纸管理",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 MWI 壁纸管理",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        let logItem = NSMenuItem()
        mainMenu.addItem(logItem)
        let logMenu = NSMenu(title: "日志")
        let export = NSMenuItem(title: "导出日志…",
                                action: #selector(MainViewController.exportLogs),
                                keyEquivalent: "")
        export.target = exportTarget
        logMenu.addItem(export)
        logItem.submenu = logMenu

        NSApp.mainMenu = mainMenu
    }
}
