import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - AX 定位 + 合成点击(移植 scripts/ax_select.swift)

enum AXSelection {
    private static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, name as CFString, &v)
        return err == .success ? v : nil
    }

    private static func str(_ el: AXUIElement, _ name: String) -> String {
        (attr(el, name) as? String) ?? ""
    }

    private static func isButton(_ el: AXUIElement) -> Bool {
        str(el, kAXRoleAttribute) == "AXButton"
    }

    private static func isScrollArea(_ el: AXUIElement) -> Bool {
        str(el, kAXRoleAttribute) == "AXScrollArea"
    }

    private static func systemSettingsPid() -> pid_t? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "pgrep -x 'System Settings'"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let pid = pid_t(out), pid > 0 else { return nil }
        return pid
    }

    private static func findButton(_ el: AXUIElement, _ kw: String, _ depth: Int, _ found: inout [AXUIElement]) {
        if depth > 16 { return }
        if isButton(el) && str(el, kAXDescriptionAttribute).lowercased().contains(kw.lowercased()) {
            found.append(el)
        }
        if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
            for k in kids { findButton(k, kw, depth + 1, &found) }
        }
    }

    private static func appWindows(_ app: AXUIElement) -> [AXUIElement] {
        (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    /// 在壁纸面板定位资产按钮并合成点击。返回是否点击成功。
    static func clickAsset(named keyword: String) -> Bool {
        guard let pid = systemSettingsPid() else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementPerformAction(app, kAXRaiseAction as CFString)
        usleep(400_000)

        var found: [AXUIElement] = []
        for w in appWindows(app) { findButton(w, keyword.lowercased(), 0, &found) }

        // 未找到 → 内容区各横向滚动区逐页右滚,最多 12 轮
        if found.isEmpty {
            var scrollAreas: [AXUIElement] = []
            func collectScroll(_ el: AXUIElement, _ depth: Int) {
                if depth > 16 { return }
                if isScrollArea(el) { scrollAreas.append(el) }
                if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
                    for k in kids { collectScroll(k, depth + 1) }
                }
            }
            for w in appWindows(app) { collectScroll(w, 0) }
            scrollAreas.sort { a, b in
                var pa = CGPoint.zero, pb = CGPoint.zero
                if let p = attr(a, kAXPositionAttribute) as! AXValue? { AXValueGetValue(p, .cgPoint, &pa) }
                if let p = attr(b, kAXPositionAttribute) as! AXValue? { AXValueGetValue(p, .cgPoint, &pb) }
                return pa.y < pb.y
            }
            outer: for _ in 0..<12 {
                for sa in scrollAreas {
                    AXUIElementPerformAction(sa, "AXScrollRightByPage" as CFString)
                }
                usleep(250_000)
                found.removeAll()
                for w in appWindows(app) { findButton(w, keyword.lowercased(), 0, &found) }
                if !found.isEmpty { break outer }
            }
        }

        guard let target = found.first else { return false }
        AXUIElementPerformAction(target, "AXScrollToVisible" as CFString)
        usleep(400_000)

        var pt = CGPoint.zero
        var sz = CGSize.zero
        if let p = attr(target, kAXPositionAttribute) as! AXValue? { AXValueGetValue(p, .cgPoint, &pt) }
        if let s = attr(target, kAXSizeAttribute) as! AXValue? { AXValueGetValue(s, .cgSize, &sz) }
        let cp = CGPoint(x: pt.x + sz.width / 2, y: pt.y + sz.height / 2)

        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: cp, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(150_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: cp, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(150_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: cp, mouseButton: .left)?.post(tap: .cghidEventTap)
        return true
    }
}
