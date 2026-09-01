// code-review-marker
// ax_select.swift — 在系统设置壁纸面板中定位并合成点击资产按钮。
// 用法: swift ax_select.swift "<名称关键字>"
// 逻辑: 全树递归找 description 含关键字的 AXButton;找不到则对内容区各
//       AXScrollArea 逐页右滚(最多 12 轮);找到后 AXScrollToVisible + 合成点击中心。
import ApplicationServices
import CoreGraphics
import Foundation

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, name as CFString, &v)
    return err == .success ? v : nil
}
func str(_ el: AXUIElement, _ name: String) -> String { (attr(el, name) as? String) ?? "" }
func isButton(_ el: AXUIElement) -> Bool { str(el, kAXRoleAttribute) == "AXButton" }
func isScrollArea(_ el: AXUIElement) -> Bool { str(el, kAXRoleAttribute) == "AXScrollArea" }

func findButton(_ el: AXUIElement, _ kw: String, _ depth: Int, _ found: inout [AXUIElement]) {
    if depth > 16 { return }
    if isButton(el) && str(el, kAXDescriptionAttribute).lowercased().contains(kw.lowercased()) {
        found.append(el)
    }
    if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
        for k in kids { findButton(k, kw, depth + 1, &found) }
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: ax_select.swift <name-keyword>")
    exit(1)
}
let keyword = args[1].lowercased()

let task = Process()
task.executableURL = URL(fileURLWithPath: "/bin/sh")
task.arguments = ["-c", "pgrep -x 'System Settings'"]
let pipe = Pipe(); task.standardOutput = pipe
try? task.run(); task.waitUntilExit()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
guard let pidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
      let pid = pid_t(pidStr), pid > 0 else {
    print("System Settings not running")
    exit(1)
}
let appEl = AXUIElementCreateApplication(pid)
AXUIElementPerformAction(appEl, kAXRaiseAction as CFString)
usleep(400_000)

var found: [AXUIElement] = []
if let windows = attr(appEl, kAXWindowsAttribute) as? [AXUIElement] {
    for w in windows { findButton(w, keyword, 0, &found) }
}

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
    if let windows = attr(appEl, kAXWindowsAttribute) as? [AXUIElement] {
        for w in windows { collectScroll(w, 0) }
    }
    // 排除侧边栏(第一个, x 最小)和顶部预览区
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
        if let windows = attr(appEl, kAXWindowsAttribute) as? [AXUIElement] {
            for w in windows { findButton(w, keyword, 0, &found) }
        }
        if !found.isEmpty { break outer }
    }
}

guard let target = found.first else {
    print("NOT FOUND: \(keyword)")
    exit(2)
}
AXUIElementPerformAction(target, "AXScrollToVisible" as CFString)
usleep(400_000)

var pt = CGPoint.zero
var sz = CGSize.zero
if let p = attr(target, kAXPositionAttribute) as! AXValue? { AXValueGetValue(p, .cgPoint, &pt) }
if let s = attr(target, kAXSizeAttribute) as! AXValue? { AXValueGetValue(s, .cgSize, &sz) }
let cp = CGPoint(x: pt.x + sz.width / 2, y: pt.y + sz.height / 2)

let src = CGEventSource(stateID: .hidSystemState)
let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: cp, mouseButton: .left)
move?.post(tap: .cghidEventTap)
usleep(150_000)
let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: cp, mouseButton: .left)
let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: cp, mouseButton: .left)
down?.post(tap: .cghidEventTap)
usleep(150_000)
up?.post(tap: .cghidEventTap)
print("CLICKED at (\(cp.x),\(cp.y))")
