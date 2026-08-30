import Foundation

// MARK: - Aerial manifest 注入(entries.json)

enum AerialManifest {
    static func loadFallback() -> [String: Any] {
        JSONFile.loadDict(Paths.fallbackEntries)
    }

    static func loadEntries() -> [String: Any] {
        JSONFile.loadDict(Paths.entries)
    }

    /// 注入准备:构造资产 + 新分类(可选),写用户 entries.json,备份,写 STATE
    /// - Returns: 日志文本
    @discardableResult
    static func inject(videoName: String, thumbName: String, port: Int,
                       name: String, assetID: String, newCategory: String?) throws -> String {
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

        // 资产(克隆模板 + 覆盖字段)
        var asset = template
        asset["id"] = assetID
        asset["localizedNameKey"] = name
        asset["accessibilityLabel"] = name
        asset["previewImage"] = "http://127.0.0.1:\(port)/\(thumbName)"
        asset["categories"] = [catID]
        if let newSGID {
            asset["subcategories"] = [newSGID]
        }
        asset["url"] = "http://127.0.0.1:\(port)/\(videoName)"
        asset["url-4K-SDR-240FPS"] = "http://127.0.0.1:\(port)/\(videoName)"

        // 备份用户 entries(仅首次)
        if FileManager.default.fileExists(atPath: Paths.entries.path) {
            let backup = Paths.exp009Baseline.deletingLastPathComponent().appendingPathComponent("inject/entries.json")
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: Paths.entries, to: backup)
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

        // STATE
        let state: [String: Any] = [
            "name": name, "asset_id": assetID, "video": videoName,
            "thumb": thumbName, "port": port,
        ]
        let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted])
        try data.write(to: Paths.state, options: .atomic)
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
            let url = (a["url"] as? String) ?? ""
            let url4k = (a["url-4K-SDR-240FPS"] as? String) ?? ""
            if url.contains("127.0.0.1") || url4k.contains("127.0.0.1") {
                let catNames = (a["categories"] as? [String] ?? []).map { cats[$0] ?? String($0.prefix(8)) }
                let id = (a["id"] as? String) ?? ""
                let vf = Paths.videosDir.appendingPathComponent("\(id).mov")
                injected.append(InjectedAsset(
                    id: id,
                    name: (a["localizedNameKey"] as? String) ?? "",
                    categories: catNames,
                    subcategories: (a["subcategories"] as? [String] ?? []).map { String($0.prefix(8)) },
                    url: url.isEmpty ? url4k : url,
                    downloaded: FileManager.default.fileExists(atPath: vf.path)
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
