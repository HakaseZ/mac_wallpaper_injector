import Foundation

// MARK: - Aerial manifest 注入(entries.json)

enum AerialManifest {
    static func loadFallback() -> [String: Any] {
        JSONFile.loadDict(Paths.fallbackEntries)
    }

    static func loadEntries() -> [String: Any] {
        JSONFile.loadDict(Paths.entries)
    }

    /// 注入准备:构造资产 + 新分类(可选),写用户 entries.json,备份
    /// 下载源 = file://(视频/缩略图已预置到 aerials/videos|thumbnails,不依赖 http/代理)
    /// - Returns: 日志文本
    @discardableResult
    static func inject(assetID: String, name: String, newCategory: String?) throws -> String {
        var fb = loadFallback()
        guard let landscape = (fb["categories"] as? [[String: Any]])?.first(where: { $0["id"] as? String == Paths.landscapeCatID }),
              let template = (fb["assets"] as? [[String: Any]])?.first(where: { $0["id"] as? String == Paths.templateAssetID }) else {
            throw ServiceError.msg("fallback 缺 Landscape 分类或模板资产")
        }

        var log = ""
        var catID: String = Paths.landscapeCatID
        var newSGID: String?

        // 新分类(克隆 Landscape + 全新子分类)
        if let newCategory, !newCategory.isEmpty {
            var newCat = landscape
            newCat["id"] = UUID().uuidString.uppercased()
            newCat["localizedNameKey"] = newCategory
            // 全新子分类(克隆 Golden Gate 结构)→ 分类完全独立
            let sgList = landscape["subcategories"] as? [[String: Any]] ?? []
            guard let goldenGate = sgList.first(where: { $0["id"] as? String == Paths.goldenGateSubID }) else {
                throw ServiceError.msg("fallback 缺 Golden Gate 子分类")
            }
            var newSG = goldenGate
            newSG["id"] = UUID().uuidString.uppercased()
            newSG["localizedNameKey"] = "\(newCategory) 子分类"
            newSG["preferredOrder"] = 99
            newSGID = newSG["id"] as? String
            newCat["subcategories"] = [newSG]
            // 替换/追加分类
            var cats = fb["categories"] as? [[String: Any]] ?? []
            cats.removeAll { ($0["id"] as? String) == newCat["id"] as? String }
            cats.append(newCat)
            fb["categories"] = cats
            catID = newCat["id"] as! String
            log += "new category: \(newCategory) = \(catID.prefix(12))(独立,全新子分类)\n"
        }

        // 资产(克隆模板 + 覆盖字段);下载源 = file:// 本地(避开系统代理干扰)
        let videoFile = Paths.videosDir.appendingPathComponent("\(assetID).mov").absoluteString
        let thumbFile = Paths.thumbnailsDir.appendingPathComponent("\(assetID).png").absoluteString
        var asset = template
        asset["id"] = assetID
        asset["localizedNameKey"] = name
        asset["accessibilityLabel"] = name
        asset["previewImage"] = thumbFile
        asset["categories"] = [catID]
        if let newSGID {
            asset["subcategories"] = [newSGID]
        }
        asset["url"] = videoFile
        asset["url-4K-SDR-240FPS"] = videoFile

        // 备份用户 entries(仅首次)
        if FileManager.default.fileExists(atPath: Paths.entries.path) {
            let backupDir = Paths.exp009Baseline.deletingLastPathComponent().appendingPathComponent("inject")
            let backup = backupDir.appendingPathComponent("entries.json")
            log += "backupDir: \(backupDir.path)\n"
            do {
                try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            } catch {
                throw ServiceError.msg("备份目录创建失败 \(backupDir.path): \(error.localizedDescription)")
            }
            if !FileManager.default.fileExists(atPath: backup.path) {
                do {
                    try FileManager.default.copyItem(at: Paths.entries, to: backup)
                } catch {
                    throw ServiceError.msg("备份复制失败 \(backup.path): \(error.localizedDescription)")
                }
                log += "entries.json backed up\n"
            }
        }

        // 写 entries(完整 fallback + 资产)
        var assets = fb["assets"] as? [[String: Any]] ?? []
        assets.removeAll { ($0["id"] as? String) == assetID }
        assets.append(asset)
        fb["assets"] = assets
        try JSONFile.saveDict(fb, to: Paths.entries)
        log += "entries.json: \(assets.count) assets (injected \(name) = \(assetID.prefix(12)))\n"

        return log
    }

    /// 列出注入资产(url 指向本地 127.0.0.1)+ 当前 choice
    static func list() -> ([InjectedAsset], [String: String]) {
        let d = loadEntries()
        let assets = d["assets"] as? [[String: Any]] ?? []
        let cats: [String: String] = Dictionary(uniqueKeysWithValues: (d["categories"] as? [[String: Any]] ?? []).compactMap { c -> (String, String)? in
            guard let id = c["id"] as? String else { return nil }
            return (id, (c["localizedNameKey"] as? String) ?? id)
        })
        var injected: [InjectedAsset] = []
        for a in assets {
            let id = (a["id"] as? String) ?? ""
            let url = (a["url"] as? String) ?? ""
            let url4k = (a["url-4K-SDR-240FPS"] as? String) ?? ""
            // 注入资产 = 本地 url(127.0.0.1/file://)+ 非空 subcategories(真实注入特征;
            // 基线残留 MWI Test4 subcategories=[] 不显示)
            let localURL = url.contains("127.0.0.1") || url4k.contains("127.0.0.1")
                || url.hasPrefix("file://") || url4k.hasPrefix("file://")
            if localURL && !((a["subcategories"] as? [String]) ?? []).isEmpty {
                let catNames = (a["categories"] as? [String] ?? []).map { cats[$0] ?? String($0.prefix(8)) }
                let id = (a["id"] as? String) ?? ""
                let vf = Paths.videosDir.appendingPathComponent("\(id).mov")
                // 缩略图:previewImage 文件名 → httpDir(旧)或 thumbnails(新)找本地文件
                var thumb = ""
                let preview = (a["previewImage"] as? String) ?? ""
                if let tn = preview.components(separatedBy: "/").last, !tn.isEmpty {
                    for dir in [Paths.httpDir, Paths.thumbnailsDir] {
                        let tp = dir.appendingPathComponent(tn).path
                        if FileManager.default.fileExists(atPath: tp) {
                            thumb = tp
                            break
                        }
                    }
                }
                injected.append(InjectedAsset(
                    id: id,
                    name: (a["localizedNameKey"] as? String) ?? "",
                    categories: catNames,
                    subcategories: (a["subcategories"] as? [String] ?? []).map { String($0.prefix(8)) },
                    url: url.isEmpty ? url4k : url,
                    downloaded: FileManager.default.fileExists(atPath: vf.path),
                    thumb: thumb
                ))
            }
        }
        // choice
        var choice: [String: String] = [:]
        let idx = PList.loadDict(Paths.index)
        if let ch = ((idx["AllSpacesAndDisplays"] as? [String: Any])?["Desktop"] as? [String: Any])?["Content"] as? [String: Any],
           let choices = ch["Choices"] as? [[String: Any]], let first = choices.first {
            let cfg = first["Configuration"] as? Data
            if let cfg, let c = try? PropertyListSerialization.propertyList(from: cfg, options: [], format: nil) as? [String: Any] {
                choice = c.compactMapValues { String(describing: $0) }
            } else if let p = first["Provider"] as? String {
                choice = ["provider": p]
            }
        }
        return (injected, choice)
    }

    static func assetName(id: String) -> String? {
        let d = loadEntries()
        return (d["assets"] as? [[String: Any]] ?? []).first { ($0["id"] as? String) == id }?["localizedNameKey"] as? String
    }
}

enum ServiceError: LocalizedError {
    case msg(String)
    var errorDescription: String? {
        switch self { case .msg(let s): return s }
    }
}
