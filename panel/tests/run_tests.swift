import Foundation

// MWI 面板自动化测试:全链路断言,退出码 0=全过
// 用法: swiftc 编译后运行(见 tests.sh)

@main
struct RunTests {
    static var passed = 0
    static var failed = 0

    static func check(_ name: String, _ cond: Bool, _ detail: String = "") {
        if cond {
            passed += 1
            print("  ✅ \(name)")
        } else {
            failed += 1
            print("  ❌ \(name) \(detail)")
        }
    }

    static func runSystem(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
    }

    static func main() async {
        let svc = WallpaperService.shared
        // 工程根由源码位置推导(不硬编码本地路径)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // tests/
            .deletingLastPathComponent()  // panel
            .deletingLastPathComponent()  // 根
        let v3 = root.appendingPathComponent("test_videos/mwi_test3_patched.mov")
        let thumb = root.appendingPathComponent("test_videos/mwi_test4.png")
        print("== MWI 面板自动化测试 ==")
        do {
            // 0. 基线
            print("[0] 基线")
            _ = try await svc.restore()
            var (list, _) = AerialManifest.list()
            check("基线无注入资产", list.isEmpty, "count=\(list.count)")

            // 1. 注入 A(HEVC 小视频,跳过转码)
            print("[1] 注入 A(MWI 分类)")
            _ = try await svc.prepare(videoURL: v3, name: "AutoTest A",
                                      thumbnailURL: thumb, newCategory: "MWI")
            (list, _) = AerialManifest.list()
            check("注入 A 后 list=1", list.count == 1, "count=\(list.count)")
            check("A 下载源 file://", list.first?.url.hasPrefix("file://") == true)
            check("A 缩略图已生成", list.first?.thumb.isEmpty == false)
            check("A 分类 MWI", list.first?.categories.first == "MWI")

            // 2. 注入 B(同分类复用)
            print("[2] 注入 B(同分类复用)")
            _ = try await svc.prepare(videoURL: v3, name: "AutoTest B",
                                      thumbnailURL: thumb, newCategory: "MWI")
            (list, _) = AerialManifest.list()
            check("注入 B 后 list=2", list.count == 2, "count=\(list.count)")
            let d = JSONFile.loadDict(Paths.entries)
            let mwiCats = (d["categories"] as? [[String: Any]] ?? []).filter { ($0["localizedNameKey"] as? String) == "MWI" }
            check("MWI 分类复用=1(不重复创建)", mwiCats.count == 1, "count=\(mwiCats.count)")

            // 3. 注入 C(新分类)
            print("[3] 注入 C(新分类 AutoTestCat)")
            _ = try await svc.prepare(videoURL: v3, name: "AutoTest C",
                                      thumbnailURL: thumb, newCategory: "AutoTestCat")
            (list, _) = AerialManifest.list()
            check("注入 C 后 list=3", list.count == 3, "count=\(list.count)")
            check("C 分类 AutoTestCat", list.contains { $0.name == "AutoTest C" && $0.categories.first == "AutoTestCat" })

            // 4. refresh + select + 下载播放
            print("[4] select + 下载 + 播放")
            _ = try await svc.refresh()
            guard let target = list.first(where: { $0.name == "AutoTest A" }) else {
                check("找到 AutoTest A", false); throw ServiceError.msg("AutoTest A 不在列表")
            }
            print("DEBUG target.id:", target.id)
            print("DEBUG all ids:", list.map { $0.id })
            let sel = try await svc.select(id: target.id)
            check("select CLICKED", sel.contains("CLICKED"))
            try await Task.sleep(nanoseconds: 20_000_000_000)
            let st = await svc.status()
            check("选择后已下载", st.downloaded, "dl=\(st.downloaded)")
            check("选择后播放(startReading)", st.startReading, "sr=\(st.startReading)")
            let (_, choice) = AerialManifest.list()
            check("choice = AutoTest A", choice["assetID"] == target.id, "choice=\(choice["assetID"] ?? "nil") target=\(target.id)")
            // 4.5 重命名(右键菜单底层:资产 + 分类)
            print("[4.5] 重命名资产/分类")
            _ = try await svc.renameAsset(id: target.id, newName: "AutoTest A-Renamed")
            _ = try await svc.renameCategory(oldName: "MWI", newName: "MWI-Renamed")
            (list, _) = AerialManifest.list()
            check("重命名资产生效", list.contains { $0.name == "AutoTest A-Renamed" },
                  "names=\(list.map { $0.name })")
            check("重命名分类生效", list.first(where: { $0.name == "AutoTest A-Renamed" })?.categories.first == "MWI-Renamed",
                  "cats=\(list.map { $0.categories.first ?? "" })")
            let mwiCats2 = (JSONFile.loadDict(Paths.entries)["categories"] as? [[String: Any]] ?? [])
                .filter { ($0["localizedNameKey"] as? String) == "MWI-Renamed" }
            check("分类名落盘(不重复)", mwiCats2.count == 1, "count=\(mwiCats2.count)")

            // 5. 持久性:重启扩展 + agent → 播放自动恢复
            print("[5] 持久性(扩展重启后自动恢复)")
            try? runSystem("/usr/bin/killall", ["WallpaperAerialsExtension"])
            try? runSystem("/usr/bin/killall", ["WallpaperAgent"])
            sleep(10)
            let st2 = await svc.status()
            check("扩展重启后播放恢复", st2.startReading, "sr=\(st2.startReading)")

            // 6. delete
            print("[6] 删除")
            guard let b = list.first(where: { $0.name == "AutoTest B" }) else {
                check("找到 AutoTest B", false); throw ServiceError.msg("AutoTest B 不在列表")
            }
            let delOut = try await svc.delete(id: b.id)
            (list, _) = AerialManifest.list()
            check("删除 B 后 list=2", list.count == 2, "count=\(list.count)")
            check("B 视频已删", !FileManager.default.fileExists(
                atPath: Paths.videosDir.appendingPathComponent("\(b.id).mov").path))

            // 7. restore
            print("[7] 恢复基线")
            _ = try await svc.restore()
            (list, _) = AerialManifest.list()
            check("restore 后 list=0", list.isEmpty, "count=\(list.count)")
            let (_, choice2) = AerialManifest.list()
            check("restore 后 choice 非注入资产", (choice2["assetID"] ?? "").isEmpty,
                  "choice=\(choice2["assetID"] ?? "nil")")

            print("\n===== \(passed) passed, \(failed) failed =====")
            exit(failed == 0 ? 0 : 1)
        } catch {
            print("ERROR: \(error.localizedDescription)")
            _ = try? await svc.restore()
            exit(1)
        }
    }
}
