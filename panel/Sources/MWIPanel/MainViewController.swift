// code-review-marker
import AppKit
import UniformTypeIdentifiers

// MARK: - 主界面(AppKit)

/// 左对齐流式布局:AppKit 的 NSCollectionViewFlowLayout 会把不足一行的项目撑满整行
/// (如 2 张卡被拉开到整行宽),系统壁纸面板是左对齐紧凑排列 —— 这里重排每行到左起点。
final class LeftAlignedFlowLayout: NSCollectionViewFlowLayout {
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard let collectionView else { return super.layoutAttributesForElements(in: rect) }
        let all = super.layoutAttributesForElements(in: rect)
        // 找出 rect 涉及的行(同 section 同 y);对每行用该 section 全量 item 的原始位置重算左对齐,
        // 避免 rect 裁剪只拿到半行时错位
        var rowKeys: Set<String> = []
        for a in all where a.representedElementCategory == .item {
            rowKeys.insert(rowKey(a))
        }
        guard !rowKeys.isEmpty else { return all }

        var corrected: [NSCollectionViewLayoutAttributes] = []
        var seen = Set<String>()
        for a in all {
            if a.representedElementCategory == .item, let ip = a.indexPath {
                let key = rowKey(a)
                if rowKeys.contains(key), !seen.contains(key) {
                    seen.insert(key)
                    let sectionItems = (0..<collectionView.numberOfItems(inSection: ip.section))
                        .compactMap { super.layoutAttributesForItem(at: IndexPath(item: $0, section: ip.section)) }
                    let row = sectionItems.filter { abs($0.frame.minY - a.frame.minY) < 0.5 }
                        .sorted { ($0.indexPath?.item ?? 0) < ($1.indexPath?.item ?? 0) }
                    if let first = row.first {
                        var x = first.frame.minX
                        for at in row {
                            at.frame.origin.x = x
                            x += at.frame.width + minimumInteritemSpacing
                        }
                    }
                    corrected.append(contentsOf: row)
                }
            } else {
                corrected.append(a)
            }
        }
        return corrected
    }

    private func rowKey(_ a: NSCollectionViewLayoutAttributes) -> String {
        "\(a.indexPath?.section ?? -1)|\(Int(a.frame.minY * 2))"
    }
}

@MainActor
final class MainViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private var assets: [InjectedAsset] = []
    private var groups: [(name: String, items: [InjectedAsset])] = []
    private var selectedID: String?
    private var transcodingProgress: [String: Double] = [:]  // 资产名 → 转码进度(支持并发)
    private var transcodingItems: [String: AssetCardItem] = [:]  // 资产名 → 卡片(各自更新进度)
    private var pendingAssets: [String: InjectedAsset] = [:]  // 转码中资产(刷新/完成 reload 时保留)

    // 视图
    private let collectionView = NSCollectionView()

    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let injectButton = NSButton(title: "添加壁纸", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除选中", target: nil, action: nil)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 560))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        reload()
    }

    // MARK: UI 布局

    private func setupUI() {
        // 工具栏按钮
        let toolbar = NSStackView(views: [])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        configure(injectButton, #selector(doInject), "plus")
        configure(deleteButton, #selector(doDelete), "trash")
        configure(refreshButton, #selector(doRefresh), "arrow.clockwise")
        toolbar.addArrangedSubview(injectButton)
        toolbar.addArrangedSubview(deleteButton)
        toolbar.addArrangedSubview(NSView())
        toolbar.addArrangedSubview(refreshButton)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        // 左:缩略图网格(壁纸面板式排列:分类分组,左对齐,卡片完整缩略图)
        let listScroll = NSScrollView()
        let layout = LeftAlignedFlowLayout()
        layout.itemSize = NSSize(width: 160, height: 144)
        layout.sectionInset = NSEdgeInsets(top: 4, left: 8, bottom: 7, right: 8)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 8
        layout.headerReferenceSize = NSSize(width: 0, height: 14)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(AssetCardItem.self, forItemWithIdentifier: .init("AssetCard"))
        collectionView.register(AssetHeaderView.self,
                                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: .init("Header"))
        listScroll.documentView = collectionView
        listScroll.hasVerticalScroller = true

        listScroll.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(toolbar)
        view.addSubview(listScroll)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            listScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            listScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            listScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            listScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
    }

    private func configure(_ button: NSButton, _ action: Selector, _ symbol: String) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
    }

    // MARK: 数据

    private func reload() {
        setBusy()
        Task {
            let svc = WallpaperService.shared
            let (list, st) = await (svc.list(), svc.status())
            // 合并转码中资产(刷新/其他注入完成时保留进行中的卡片)
            var merged = list
            for (_, pa) in self.pendingAssets where !merged.contains(where: { $0.id == pa.id }) {
                merged.append(pa)
            }
            self.assets = merged
            self.rebuildGroups()
                self.collectionView.reloadData()
                        self.appendLog("已加载 \(list.count) 个注入资产")
            if !st.assetID.isEmpty {
                self.appendLog("当前: \(st.name)(\(st.assetID.prefix(8))) \(st.playing ? "PLAYING" : "")")
            }
            // 启动自查:注入资产完整性 + choice 一致性
            let (_, choice) = AerialManifest.list()
            let choiceID = choice["assetID"] ?? ""
            for a in list where !a.downloaded {
                self.appendLog("⚠ \(a.name): 视频未下载(在壁纸面板选择一次触发下载)")
            }
            if let a = list.first(where: { $0.id == choiceID }) {
                self.appendLog("choice 指向注入资产 \(a.name)(\(a.downloaded ? "已下载" : "未下载"))")
            } else if !choiceID.isEmpty {
                self.appendLog("choice 指向非注入资产或已失效资产")
            }
            self.setBusy()
        }
    }

    private func setBusy() {
        // 转码在后台并行执行:全部按钮可用(可并发注入多个)
        injectButton.isEnabled = true
        deleteButton.isEnabled = selectedID != nil
        refreshButton.isEnabled = true
    }

    /// 日志仅落盘(菜单「导出日志」读取),不在界面显示
    private func appendLog(_ s: String) {
        guard let h = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first,
              let d = (s + "\n").data(using: .utf8) else { return }
        let logFile = h.appendingPathComponent("Logs/mwi_panel.log")
        if let fh = try? FileHandle(forWritingTo: logFile) {
            fh.seekToEndOfFile()
            fh.write(d)
            try? fh.close()
        } else {
            try? d.write(to: logFile)
        }
    }

    // MARK: 操作

    @objc private func doRefresh() { reload() }

    @objc private func doInject() {
        let sheet = InjectSheetController { [weak self] video, name, thumb, newCat in
            guard let self, let video else { return }
            self.runPrepare(video: video, name: name, thumb: thumb, newCat: newCat)
        }
        presentAsSheet(sheet)
    }

    private func runPrepare(video: URL, name: String, thumb: URL?, newCat: String?) {
        setBusy()
        transcodingProgress[name] = 0
        // 立即快速抽帧(原视频)→ 列表先显示缩略图 + 转码中状态
        Task {
            var thumbPath = ""
            if let t = thumb {
                thumbPath = t.path
            } else if let p = try? ThumbnailExtractor.extractFrame(from: video).path {
                thumbPath = p
            }
            let pending = InjectedAsset(id: "pending-\(UUID().uuidString)", name: name,
                                        categories: [newCat ?? "注入中"], subcategories: [],
                                        url: "", downloaded: false, thumb: thumbPath)
            await MainActor.run {
                self.pendingAssets[name] = pending
                self.assets = [pending] + self.assets
                self.rebuildGroups()
                self.collectionView.reloadData()
            }
        }
        Task {
            let stream = await WallpaperService.shared.prepareStream(
                videoURL: video, name: name, thumbnailURL: thumb, newCategory: newCat)
            var finalLog = ""
            for await ev in stream {
                switch ev {
                case .stage(let s):
                    _ = s  // 阶段提示由卡片进度条承载
                case .progress(let p):
                    self.transcodingProgress[name] = p
                    if let item = self.transcodingItems[name] {
                        item.progressRing.strokeEnd = p
                        item.pctLabel.stringValue = "\(Int(p * 100))%"
                    }
                case .log(let s):
                    self.appendLog(s)
                case .done(let s):
                    finalLog = s
                case .error(let e):
                    self.appendLog("ERROR(prepare): \(e)")
                    self.showError(e)
                }
            }
            self.transcodingProgress.removeValue(forKey: name)
            self.transcodingItems.removeValue(forKey: name)
            self.pendingAssets.removeValue(forKey: name)
            self.appendLog("prepare \(name):\n\(finalLog)")
            self.appendLog("refresh: 重查面板模型...")
            do {
                let r = try await WallpaperService.shared.refresh()
                self.appendLog(r)
                self.assets = await WallpaperService.shared.list()
                self.rebuildGroups()
                self.collectionView.reloadData()
            } catch {
                self.appendLog("ERROR(refresh): \(error.localizedDescription)")
                self.showError(error.localizedDescription)
            }
            self.setBusy()
        }
    }

    @objc private func doDelete() {
        guard let id = selectedID else { return }
        guard let asset = assets.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "删除资产?"
        alert.informativeText = "将从 entries 移除 \(asset.name),并删除其视频/缩略图。若它是当前壁纸,choice 恢复系统默认壁纸。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setBusy()
        Task {
            do {
                let out = try await WallpaperService.shared.delete(id: id)
                self.appendLog("delete:\(out)")
                self.appendLog("refresh: 同步面板模型...")
                let r = try await WallpaperService.shared.refresh()
                self.appendLog(r)
                let svc = WallpaperService.shared
                self.assets = await svc.list()
                self.rebuildGroups()
                self.collectionView.reloadData()
                            } catch {
                self.appendLog("ERROR(delete): \(error.localizedDescription)")
                self.showError(error.localizedDescription)
            }
            self.setBusy()
        }
    }

    private func showError(_ msg: String) {
        let alert = NSAlert()
        alert.messageText = "错误"
        alert.informativeText = msg
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
    // MARK: 重命名(右键菜单)

    private func promptRenameAsset(id: String, currentName: String) {
        let newName = promptRename("重命名壁纸", current: currentName)
        guard let newName else { return }
        setBusy()
        Task {
            do {
                let out = try await WallpaperService.shared.renameAsset(id: id, newName: newName)
                self.appendLog(out)
                self.assets = await WallpaperService.shared.list()
                self.rebuildGroups()
                self.collectionView.reloadData()
            } catch {
                self.appendLog("ERROR(rename): \(error.localizedDescription)")
                self.showError(error.localizedDescription)
            }
            self.setBusy()
        }
    }

    private func promptRenameCategory(currentName: String) {
        let newName = promptRename("重命名分类", current: currentName)
        guard let newName else { return }
        setBusy()
        Task {
            do {
                let out = try await WallpaperService.shared.renameCategory(oldName: currentName, newName: newName)
                self.appendLog(out)
                self.assets = await WallpaperService.shared.list()
                self.rebuildGroups()
                self.collectionView.reloadData()
            } catch {
                self.appendLog("ERROR(rename): \(error.localizedDescription)")
                self.showError(error.localizedDescription)
            }
            self.setBusy()
        }
    }

    /// 弹出重命名输入框,返回新名字(取消/未修改 → nil)
    private func promptRename(_ title: String, current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != current else { return nil }
        return name
    }

    // MARK: 导出日志(菜单)

    @objc func exportLogs() {
        let h = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let logFile = h.appendingPathComponent("Logs/mwi_panel.log")
        guard FileManager.default.fileExists(atPath: logFile.path) else {
            showError("暂无日志(应用运行后才会产生)")
            return
        }
        let panel = NSSavePanel()
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "MWI日志-\(df.string(from: Date())).log"
        panel.allowedContentTypes = [.log]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try FileManager.default.copyItem(at: logFile, to: dest)
            appendLog("日志已导出: \(dest.path)")
        } catch {
            showError("导出失败: \(error.localizedDescription)")
        }
    }

    // MARK: 分组 + 选择

    private func rebuildGroups() {
        var map: [String: [InjectedAsset]] = [:]
        for a in assets {
            let key = a.categories.first ?? "未分类"
            map[key, default: []].append(a)
        }
        groups = map.map { (name: $0.key, items: $0.value) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: NSCollectionViewDataSource / Delegate

    func numberOfSections(in collectionView: NSCollectionView) -> Int { groups.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        groups[section].items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: .init("AssetCard"), for: indexPath) as! AssetCardItem
        let asset = groups[indexPath.section].items[indexPath.item]
        let prog = transcodingProgress[asset.name]
        item.configure(asset: asset, progress: prog)
        item.renameHandler = { [weak self] in
            self?.promptRenameAsset(id: asset.id, currentName: asset.name)
        }
        if prog != nil {
            transcodingItems[asset.name] = item
        } else {
            transcodingItems.removeValue(forKey: asset.name)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView,
                        viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(
            ofKind: kind, withIdentifier: .init("Header"), for: indexPath) as! AssetHeaderView
        let groupName = groups[indexPath.section].name
        header.titleLabel.stringValue = groupName
        header.renameHandler = { [weak self] in
            self?.promptRenameCategory(currentName: groupName)
        }
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let ip = indexPaths.first, ip.section < groups.count, ip.item < groups[ip.section].items.count else {
            selectedID = nil
            return
        }
        selectedID = groups[ip.section].items[ip.item].id
        deleteButton.isEnabled = true
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectedID = nil
        deleteButton.isEnabled = false
    }
}

// MARK: - 资产卡片(壁纸面板式缩略图)

/// 卡片根视图:拦截右键弹出重命名菜单
final class CardView: NSView {
    var onRightClick: ((NSEvent) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}

final class AssetCardItem: NSCollectionViewItem {
    let imgView = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let pctLabel = NSTextField(labelWithString: "")  // 缩略图右下:百分比
    private let ringContainer = NSView()             // 缩略图右上:环形进度(仿 wallpaper 下载蓝圈)
    private let ringLayer = CAShapeLayer()           // 背景环
    let progressRing = CAShapeLayer()                // 蓝色进度环(外部更新 strokeEnd)
    private let imgContainer = NSView()              // 缩略图容器(选中蓝框只画在此,不超卡片)
    var renameHandler: (() -> Void)?                 // 重命名回调(configure 时由控制器设置)

    override var isSelected: Bool {
        didSet {
            imgContainer.wantsLayer = true
            imgContainer.layer?.borderWidth = isSelected ? 2 : 0
            imgContainer.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : nil
            imgContainer.layer?.cornerRadius = 6
        }
    }

    override func loadView() {
        view = CardView(frame: NSRect(x: 0, y: 0, width: 160, height: 144))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 方形缩略图(configure 里裁剪居中方形,等比显示不变形)
        imgView.imageScaling = .scaleProportionallyUpOrDown
        imgView.wantsLayer = true
        imgView.layer?.cornerRadius = 6
        imgView.layer?.masksToBounds = true
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.font = .systemFont(ofSize: 12)

        // 环形进度:深色背景环 + 系统蓝进度环(仿 wallpaper 下载;强化对比)
        let ringFrame = CGRect(x: 0, y: 0, width: 16, height: 16)
        let circle = NSBezierPath(ovalIn: CGRect(x: 1.5, y: 1.5, width: 13, height: 13)).cgPath
        ringLayer.frame = ringFrame  // 设置 frame:保证旋转中心正确、与进度环对齐
        ringLayer.path = circle
        ringLayer.strokeColor = NSColor.black.withAlphaComponent(0.6).cgColor  // 深色底,对比明显
        ringLayer.fillColor = nil
        ringLayer.lineWidth = 3
        progressRing.frame = ringFrame
        progressRing.path = circle
        progressRing.strokeColor = NSColor.systemBlue.cgColor
        progressRing.fillColor = nil
        progressRing.lineWidth = 3
        progressRing.lineCap = .round
        progressRing.strokeEnd = 0
        progressRing.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)  // 从 12 点方向开始
        ringContainer.wantsLayer = true
        ringContainer.layer?.addSublayer(ringLayer)
        ringContainer.layer?.addSublayer(progressRing)
        ringContainer.isHidden = true

        pctLabel.font = .systemFont(ofSize: 9, weight: .bold)
        pctLabel.textColor = .white
        pctLabel.alignment = .right
        pctLabel.wantsLayer = true
        pctLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        pctLabel.layer?.cornerRadius = 3
        pctLabel.isHidden = true

        // 缩略图容器(叠加环/百分比)
        imgContainer.wantsLayer = true
        imgContainer.layer?.cornerRadius = 6
        imgContainer.layer?.masksToBounds = true
        imgContainer.addSubview(imgView)
        imgContainer.addSubview(ringContainer)
        imgContainer.addSubview(pctLabel)
        imgView.translatesAutoresizingMaskIntoConstraints = false
        ringContainer.translatesAutoresizingMaskIntoConstraints = false
        pctLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imgView.leadingAnchor.constraint(equalTo: imgContainer.leadingAnchor),
            imgView.trailingAnchor.constraint(equalTo: imgContainer.trailingAnchor),
            imgView.topAnchor.constraint(equalTo: imgContainer.topAnchor),
            imgView.bottomAnchor.constraint(equalTo: imgContainer.bottomAnchor),
            // 右上角环形进度
            ringContainer.trailingAnchor.constraint(equalTo: imgContainer.trailingAnchor, constant: -6),
            ringContainer.topAnchor.constraint(equalTo: imgContainer.topAnchor, constant: 6),
            ringContainer.widthAnchor.constraint(equalToConstant: 16),
            ringContainer.heightAnchor.constraint(equalToConstant: 16),
            // 右下角百分比
            pctLabel.trailingAnchor.constraint(equalTo: imgContainer.trailingAnchor, constant: -5),
            pctLabel.bottomAnchor.constraint(equalTo: imgContainer.bottomAnchor, constant: -5),
            pctLabel.widthAnchor.constraint(equalToConstant: 30),
        ])

        let stack = NSStackView(views: [imgContainer, nameLabel])
        stack.orientation = .vertical
        stack.spacing = 3
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            imgContainer.widthAnchor.constraint(equalToConstant: 160),
            imgContainer.heightAnchor.constraint(equalToConstant: 100),  // 16:10 壁纸比例
            nameLabel.widthAnchor.constraint(equalToConstant: 160),
        ])

        // 右键 → 重命名菜单
        (view as? CardView)?.onRightClick = { [weak self] event in
            self?.showRenameMenu(event: event)
        }
    }

    private func showRenameMenu(event: NSEvent) {
        let menu = NSMenu()
        let item = NSMenuItem(title: "重命名…", action: #selector(menuRename(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func menuRename(_ sender: Any?) {
        renameHandler?()
    }

    func configure(asset: InjectedAsset, progress: Double?) {
        nameLabel.stringValue = asset.name
        if let p = progress {
            progressRing.strokeEnd = p
            ringContainer.isHidden = false
            pctLabel.stringValue = "\(Int(p * 100))%"
            pctLabel.isHidden = false
        } else {
            progressRing.strokeEnd = 0
            ringContainer.isHidden = true
            pctLabel.isHidden = true
        }
        if !asset.thumb.isEmpty {
            Task {
                let img = NSImage(contentsOfFile: asset.thumb)
                await MainActor.run { self.imgView.image = img.map { Self.cropSquare($0) } }
            }
        } else {
            imgView.image = NSImage(systemSymbolName: asset.downloaded ? "arrow.down.circle.fill" : "photo",
                                    accessibilityDescription: nil)
        }
    }

    /// 按 16:10 壁纸面板比例重绘:从原图居中裁剪与 target 同比例区域(像素空间计算,scale 无关),缩放无变形。
    /// 卡片用 160×100;添加壁纸面板预览用 198.4×124(同比例,精确填满不缩放)
    static func cropSquare(_ img: NSImage, target: NSSize = NSSize(width: 160, height: 100)) -> NSImage {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return img }
        let pw = CGFloat(cg.width)   // 像素尺寸:裁剪/绘制必须用同一坐标系
        let ph = CGFloat(cg.height)
        guard pw > 0, ph > 0, target.width > 0, target.height > 0 else { return img }
        let targetRatio = target.width / target.height
        // 从原图裁剪 targetRatio 区域(居中),保证缩放不变形
        var cropRect: CGRect
        if pw / ph > targetRatio {
            // 原图更宽 → 裁宽
            let w = ph * targetRatio
            cropRect = CGRect(x: (pw - w) / 2, y: 0, width: w, height: ph)
        } else {
            // 原图更高 → 裁高
            let h = pw / targetRatio
            cropRect = CGRect(x: 0, y: (ph - h) / 2, width: pw, height: h)
        }
        guard let cropped = cg.cropping(to: cropRect) else { return img }
        let out = NSImage(size: target)
        out.lockFocus()
        NSImage(cgImage: cropped, size: NSSize(width: cropRect.width, height: cropRect.height))
            .draw(in: NSRect(origin: .zero, size: target))
        out.unlockFocus()
        return out
    }
}

// MARK: - 分类标题

final class AssetHeaderView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    var renameHandler: (() -> Void)?  // 重命名回调(控制器设置)

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func rightMouseDown(with event: NSEvent) {
        guard renameHandler != nil else { return }
        let menu = NSMenu()
        let item = NSMenuItem(title: "重命名分类…", action: #selector(menuRename(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuRename(_ sender: Any?) {
        renameHandler?()
    }
}

// MARK: - 添加壁纸面板(AppKit sheet)

/// 视频选择区:点击选择或拖入视频;选中后显示预览缩略图 + 文件名。
/// 空态与选中态均为居中构图,切换只换内容,位置与边框不变(不跳变)
final class DropZoneView: NSView {
    var onPick: (() -> Void)?
    var onDrop: ((URL) -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "点击选择或拖入视频文件")
    private let hintLabel = NSTextField(labelWithString: "MOV · MP4 · MKV · WebM 等,自动转码为动态壁纸")
    private let thumbView = NSImageView()
    private let captionLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()          // 缩略图未就绪时的占位转圈
    private let emptyStack = NSStackView(views: [])      // 空态:图标 + 提示(居中)
    private let selectedStack = NSStackView(views: [])   // 选中态:预览 + 文件名(居中)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        registerForDraggedTypes([.fileURL])

        iconView.image = NSImage(systemSymbolName: "film.stack", accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.alignment = .center
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center

        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 8
        thumbView.layer?.masksToBounds = true

        captionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        captionLabel.alignment = .center
        captionLabel.lineBreakMode = .byTruncatingMiddle
        captionLabel.textColor = .labelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true

        emptyStack.addArrangedSubview(iconView)
        emptyStack.addArrangedSubview(titleLabel)
        emptyStack.addArrangedSubview(hintLabel)
        emptyStack.orientation = .vertical
        emptyStack.spacing = 6
        emptyStack.alignment = .centerX

        selectedStack.addArrangedSubview(thumbView)
        selectedStack.addArrangedSubview(captionLabel)
        selectedStack.orientation = .vertical
        selectedStack.spacing = 8
        selectedStack.alignment = .centerX
        selectedStack.detachesHiddenViews = false  // 隐藏缩略图时保留占位,文件名位置不变
        selectedStack.isHidden = true

        let click = NSClickGestureRecognizer(target: self, action: #selector(zoneClicked))
        addGestureRecognizer(click)

        for v in [emptyStack, selectedStack, spinner] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            emptyStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            selectedStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            selectedStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            thumbView.widthAnchor.constraint(equalToConstant: 200),  // 精确 16:10(200×125),与主界面一致
            thumbView.heightAnchor.constraint(equalToConstant: 125),

            captionLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),

            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 状态

    /// 空态:图标 + 提示(未选视频)
    func showEmpty() {
        emptyStack.isHidden = false
        selectedStack.isHidden = true
        spinner.isHidden = true
        spinner.stopAnimation(nil)
    }

    /// 选中态:文件名常显;缩略图未就绪时转圈占位(位置与边框均不变)
    func showSelected(name: String, image: NSImage?) {
        emptyStack.isHidden = true
        selectedStack.isHidden = false
        thumbView.image = image
        thumbView.isHidden = image == nil
        captionLabel.stringValue = name
        if image == nil {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.isHidden = true
            spinner.stopAnimation(nil)
        }
    }

    // MARK: 点击 / 拖放

    @objc private func zoneClicked() {
        onPick?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedURL(sender) != nil else { return [] }
        setHighlighted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHighlighted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHighlighted(false)
        guard let url = draggedURL(sender) else { return false }
        onDrop?(url)
        return true
    }

    private func draggedURL(_ sender: NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first
    }

    private func setHighlighted(_ h: Bool) {
        layer?.borderColor = (h ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = (h
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.5)).cgColor
    }
}

@MainActor
final class InjectSheetController: NSViewController {
    private let onSubmit: (URL?, String, URL?, String?) -> Void
    private var videoURL: URL?
    private var previewURL: URL?          // 已生成的缩略图文件(注入复用,避免重复抽帧)
    private let nameField = NSTextField()
    private let catField = NSTextField()
    private let addButton = NSButton(title: "添加壁纸", target: nil, action: nil)
    private let dropZone = DropZoneView(frame: .zero)

    init(onSubmit: @escaping (URL?, String, URL?, String?) -> Void) {
        self.onSubmit = onSubmit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 448))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // 标题 + 副标题
        let titleLabel = NSTextField(labelWithString: "添加壁纸")
        titleLabel.font = .boldSystemFont(ofSize: 20)
        let subtitle = NSTextField(labelWithString: "选择视频并命名,自动转码为 macOS 动态壁纸")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        // 视频选择区(点击 / 拖入)
        dropZone.onPick = { [weak self] in self?.pickVideo() }
        dropZone.onDrop = { [weak self] url in self?.acceptVideo(url) }
        dropZone.translatesAutoresizingMaskIntoConstraints = false

        // 名称 / 分类
        let nameRow = fieldRow("名称", nameField)
        nameField.placeholderString = "壁纸显示名称"
        let catRow = fieldRow("分类", catField)
        catField.stringValue = "MWI"
        catField.placeholderString = "默认 MWI;输入新名称创建独立分类"
        let catHint = NSTextField(labelWithString: "留空或保持默认归入 MWI 分类;输入新名称会创建独立分类")
        catHint.font = .systemFont(ofSize: 11)
        catHint.textColor = .secondaryLabelColor

        // 按钮
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(okTapped)
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.isEnabled = false
        let buttons = NSStackView(views: [NSView(), cancel, addButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [titleLabel, subtitle, dropZone, nameRow, catRow, catHint, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(18, after: subtitle)
        stack.setCustomSpacing(16, after: dropZone)
        stack.setCustomSpacing(16, after: catHint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),

            dropZone.heightAnchor.constraint(equalToConstant: 160),
            nameRow.heightAnchor.constraint(equalToConstant: 26),
            catRow.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func fieldRow(_ label: String, _ field: NSTextField) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 13)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 56).isActive = true
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        let stack = NSStackView(views: [l, field])
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
    }

    // MARK: 选择视频

    @objc private func pickVideo() {
        let p = NSOpenPanel()
        // 全种类视频可选:MKV/WebM/AVI 等未注册 UTType 也能选(.item 兜底);ffmpeg 负责转码
        p.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie, .audiovisualContent, .item]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url {
            acceptVideo(url)
        }
    }

    /// 选中/拖入视频:立即更新界面,后台抽帧生成预览与注入缩略图
    private func acceptVideo(_ url: URL) {
        videoURL = url
        previewURL = nil
        nameField.stringValue = url.deletingPathExtension().lastPathComponent
        addButton.isEnabled = true
        dropZone.showSelected(name: url.lastPathComponent, image: nil)
        Task {
            let thumb = try? await Task.detached(priority: .utility) {
                try ThumbnailExtractor.extractFrame(from: url)
            }.value
            // 预览按主界面 16:10 裁切填充,输出尺寸 = 显示帧尺寸(精确填满,不再二次缩放)
            let img = thumb.flatMap { NSImage(contentsOfFile: $0.path) }
                .map { AssetCardItem.cropSquare($0, target: NSSize(width: 200, height: 125)) }
            await MainActor.run {
                guard self.videoURL == url else { return }  // 期间又换了视频 → 丢弃过期预览
                self.previewURL = thumb
                self.dropZone.showSelected(name: url.lastPathComponent, image: img)
            }
        }
    }

    @objc private func cancelTapped() {
        dismiss(self)
    }

    @objc private func okTapped() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard videoURL != nil, !name.isEmpty else { return }
        let cat = catField.stringValue.trimmingCharacters(in: .whitespaces)
        onSubmit(videoURL, name, previewURL, cat.isEmpty ? nil : cat)
        dismiss(self)
    }
}
