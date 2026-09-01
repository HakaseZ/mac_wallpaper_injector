// code-review-marker
import Foundation
import AppKit

// MARK: - 16:10 缩略图裁切测试(纯数学,无 UI 实例)

func thumbnailTests(_ r: TestRunner) throws {
    // 构造纯色测试图(避免磁盘 IO)
    func makeImage(_ w: Int, _ h: Int, _ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        img.unlockFocus()
        return img
    }

    let target = NSSize(width: 160, height: 100)

    // 宽图(16:9)→ 160x100,无变形
    let wide = AssetCardItem.cropSquare(makeImage(1920, 1080, .red), target: target)
    r.equal("宽图输出尺寸", wide.size, target)

    // 高图(4:3)→ 160x100
    let tall = AssetCardItem.cropSquare(makeImage(800, 600, .blue), target: target)
    r.equal("高图输出尺寸", tall.size, target)

    // 超宽(21:9)→ 160x100
    let ultra = AssetCardItem.cropSquare(makeImage(2560, 1080, .green), target: target)
    r.equal("超宽图输出尺寸", ultra.size, target)

    // 方形图 → 160x100
    let square = AssetCardItem.cropSquare(makeImage(1000, 1000, .yellow), target: target)
    r.equal("方形图输出尺寸", square.size, target)

    // 16:10 原比例 → 不裁剪,尺寸不变
    let exact = AssetCardItem.cropSquare(makeImage(1600, 1000, .orange), target: target)
    r.equal("16:10 原比例输出尺寸", exact.size, target)

    // 极小输入(2x2)→ 不崩溃,输出目标尺寸
    let tiny = AssetCardItem.cropSquare(makeImage(2, 2, .black), target: target)
    r.equal("2x2 输入输出尺寸", tiny.size, target)

    // 目标比例 200x125(添加面板预览尺寸)
    let preview = AssetCardItem.cropSquare(makeImage(1920, 1080, .purple),
                                           target: NSSize(width: 200, height: 125))
    r.equal("200x125 目标尺寸", preview.size, NSSize(width: 200, height: 125))
}
