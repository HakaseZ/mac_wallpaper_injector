import Foundation

// MARK: - AerialManifest 测试(沙箱路径,不触碰真实系统)

func aerialManifestTests(_ r: TestRunner) throws {
    let sandbox = try Sandbox()
    defer { sandbox.teardown() }

    func entries() -> [String: Any] { JSONFile.loadDict(sandbox.paths.entries) }
    func assets() -> [[String: Any]] { (entries()["assets"] as? [[String: Any]]) ?? [] }
    func categories() -> [[String: Any]] { (entries()["categories"] as? [[String: Any]]) ?? [] }

    // 预置初始 entries(真实系统已存在;确保注入备份逻辑被触发)
    try JSONFile.saveDict(["assets": [], "categories": []], to: sandbox.paths.entries)

    // --- 注入:基础字段 ---
    let idA = "11111111-2222-3333-4444-555555555555"
    if r.noThrow("inject A 执行", { try AerialManifest.inject(assetID: idA, name: "Test A", newCategory: "MWI") }) != nil {
        let a = assets().first { ($0["id"] as? String) == idA }
        r.check("inject A 资产存在", a != nil)
        r.equal("A localizedNameKey", a?["localizedNameKey"] as? String ?? "", "Test A")
        r.equal("A accessibilityLabel", a?["accessibilityLabel"] as? String ?? "", "Test A")
        let url = (a?["url"] as? String) ?? ""
        r.check("A url 为 file://", url.hasPrefix("file://"), "url=\(url)")
        r.check("A url 指向沙箱 videos", url.contains(sandbox.paths.videosDir.path), "url=\(url)")
        r.check("A url-4K 同步 file://", (a?["url-4K-SDR-240FPS"] as? String)?.hasPrefix("file://") == true)
        r.check("A previewImage 本地", (a?["previewImage"] as? String)?.hasPrefix("file://") == true)
        r.check("A subcategories 非空", ((a?["subcategories"] as? [String]) ?? []).isEmpty == false)
        r.check("A 分类为 MWI", (a?["categories"] as? [String])?.isEmpty == false)
        // 备份已写入
        r.check("注入前 entries 已备份",
                FileManager.default.fileExists(atPath: sandbox.paths.backupDir.appendingPathComponent("entries.json").path))
    }

    // --- 注入:同名分类复用(不重复创建)---
    let idB = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    _ = try? AerialManifest.inject(assetID: idB, name: "Test B", newCategory: "MWI")
    let mwiCats = categories().filter { ($0["localizedNameKey"] as? String) == "MWI" }
    r.equal("同名分类复用=1", mwiCats.count, 1)
    r.check("A/B 同分类引用", assets().filter { (($0["categories"] as? [String]) ?? []).isEmpty == false }.count >= 2)

    // --- 注入:新分类完全独立(全新 id + 全新子分类)---
    let idC = "cccccccc-dddd-eeee-ffff-000000000000"
    _ = try? AerialManifest.inject(assetID: idC, name: "Test C", newCategory: "独立分类")
    let newCats = categories().filter { ($0["localizedNameKey"] as? String) == "独立分类" }
    r.equal("新分类创建=1", newCats.count, 1)
    if let nc = newCats.first {
        r.check("新分类 id ≠ Landscape", (nc["id"] as? String) != Paths.landscapeCatID)
        let subs = (nc["subcategories"] as? [[String: Any]]) ?? []
        r.equal("新分类子分类数", subs.count, 1)
        r.check("新分类子分类 id ≠ Golden Gate", (subs.first?["id"] as? String) != Paths.goldenGateSubID)
        r.equal("新分类 preferredOrder", (subs.first?["preferredOrder"] as? Int) ?? 0, 99)
        // 独立:注入资产只引用新分类
        let cAsset = assets().first { ($0["id"] as? String) == idC }
        r.equal("C 资产引用新分类", (cAsset?["categories"] as? [String])?.first ?? "", nc["id"] as? String ?? "")
    }

    // --- 注入:多次注入不互相覆盖(entries 含 fallback 模板;list 只数注入资产)---
    let (allInjected, _) = AerialManifest.list()
    r.check("注入后注入资产=3", allInjected.count == 3, "count=\(allInjected.count)")
    let stillThere = assets().contains { ($0["id"] as? String) == idA }
    r.check("A 仍存在(不覆盖)", stillThere)

    // --- list:只列本地注入资产,排除基线残留(subcategories 空)---
    // 伪造一条残留资产(本地 url 但 subcategories 空 → 不显示)
    var d = entries()
    var fakeAssets = d["assets"] as? [[String: Any]] ?? []
    fakeAssets.append([
        "id": "99999999-0000-1111-2222-333333333333",
        "localizedNameKey": "Baseline Residue",
        "url": "file:///tmp/x.mov", "url-4K-SDR-240FPS": "file:///tmp/x.mov",
        "categories": [], "subcategories": [],
    ])
    d["assets"] = fakeAssets
    try JSONFile.saveDict(d, to: sandbox.paths.entries)
    let (list, _) = AerialManifest.list()
    r.check("list 排除基线残留", list.count == 3, "count=\(list.count)")
    r.check("list 无残留名", !list.contains { $0.name == "Baseline Residue" })

    // --- list:缩略图解析(thumbnails 目录命中)---
    let thumbDir = sandbox.paths.thumbnailsDir
    try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
    try? Data([0x89, 0x50]).write(to: thumbDir.appendingPathComponent("\(idA).png"))
    let (list2, _) = AerialManifest.list()
    r.check("list 缩略图路径解析", list2.first { $0.id == idA }?.thumb.hasSuffix("\(idA).png") == true,
            "thumb=\(list2.first { $0.id == idA }?.thumb ?? "nil")")

    // --- renameAsset ---
    if r.noThrow("renameAsset 执行", { try AerialManifest.renameAsset(id: idA, newName: "Test A2") }) != nil {
        let a = assets().first { ($0["id"] as? String) == idA }
        r.equal("renameAsset 落盘", a?["localizedNameKey"] as? String ?? "", "Test A2")
        r.equal("renameAsset 同步 accessibilityLabel", a?["accessibilityLabel"] as? String ?? "", "Test A2")
    }
    r.throwsError("renameAsset 不存在抛错") { try AerialManifest.renameAsset(id: "nope", newName: "x") }

    // --- renameCategory ---
    if r.noThrow("renameCategory 执行", { try AerialManifest.renameCategory(oldName: "MWI", newName: "MWI-Renamed") }) != nil {
        r.equal("renameCategory 落盘", categories().contains { ($0["localizedNameKey"] as? String) == "MWI-Renamed" }, true)
    }
    r.throwsError("renameCategory 系统分类拒绝") { try AerialManifest.renameCategory(oldName: "Landscape", newName: "Hack") }
    r.throwsError("renameCategory 不存在抛错") { try AerialManifest.renameCategory(oldName: "Nope", newName: "X") }

    // MWI-Renamed 仍被 B 引用 → 保留;删 B 后变空 → 清理
    let removed = try? AerialManifest.remove(id: idA)
    r.check("remove 返回资产名", removed?.name == "Test A2")
    let (afterRemove, _) = AerialManifest.list()
    r.check("remove 后注入资产=2", afterRemove.count == 2, "count=\(afterRemove.count)")
    r.check("被引用分类保留(MWI-Renamed)",
            categories().contains { ($0["localizedNameKey"] as? String) == "MWI-Renamed" },
            "cats=\(categories().map { $0["localizedNameKey"] as? String ?? "" })")
    if let b = afterRemove.first(where: { $0.name == "Test B" }) {
        _ = try? AerialManifest.remove(id: b.id)
        r.check("空分类清理(MWI-Renamed)",
                !categories().contains { ($0["localizedNameKey"] as? String) == "MWI-Renamed" },
                "cats=\(categories().map { $0["localizedNameKey"] as? String ?? "" })")
    }
    r.throwsError("remove 不存在抛错") { try AerialManifest.remove(id: "nope") }
    // 独立分类仍被 C 引用 → 保留
    r.check("被引用分类保留(独立分类)", categories().contains { ($0["localizedNameKey"] as? String) == "独立分类" })

    // --- inject 与 remove 幂等:删后重注入同 id 恢复 ---
    _ = try? AerialManifest.inject(assetID: idA, name: "Test A3", newCategory: "MWI")
    r.equal("删后重注入恢复", assets().contains { ($0["id"] as? String) == idA }, true)
}
