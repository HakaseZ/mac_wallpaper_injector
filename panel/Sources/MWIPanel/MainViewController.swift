import AppKit
import UniformTypeIdentifiers

// MARK: - 主界面(AppKit)

@MainActor
final class MainViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private var assets: [InjectedAsset] = []
    private var groups: [(name: String, items: [InjectedAsset])] = []
    private var status: StatusInfo?
    private var selectedID: String?
    private var busy = false
    private var progressRowVisible = false
    private var transcodingProgress: [String: Double] = [:]  // 资产名 → 转码进度(支持并发)
    private var transcodingItems: [String: AssetCardItem] = [:]  // 资产名 → 卡片(各自更新进度)
    private var pendingAssets: [String: InjectedAsset] = [:]  // 转码中资产(刷新/完成 reload 时保留)

    // 视图
    private let collectionView = NSCollectionView()
    private let logView = NSTextView()


    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let selectButton = NSButton(title: "设为壁纸", target: nil, action: nil)
    private let injectButton = NSButton(title: "注入新壁纸", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除选中", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复基线", target: nil, action: nil)

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
        configure(selectButton, #selector(doSelect), "desktopcomputer")
        configure(injectButton, #selector(doInject), "plus")
        configure(restoreButton, #selector(doRestore), "arrow.counterclockwise")
        configure(deleteButton, #selector(doDelete), "trash")
        configure(refreshButton, #selector(doRefresh), "arrow.clockwise")
        toolbar.addArrangedSubview(selectButton)
        toolbar.addArrangedSubview(injectButton)
        toolbar.addArrangedSubview(deleteButton)
        toolbar.addArrangedSubview(restoreButton)
        toolbar.addArrangedSubview(NSView())
        toolbar.addArrangedSubview(refreshButton)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        // 左:缩略图网格(壁纸面板式排列:分类分组,左对齐,卡片完整缩略图)
        let listScroll = NSScrollView()
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 168, height: 102)
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

        let leftStack = NSStackView(views: [listScroll])
        leftStack.orientation = .vertical
        leftStack.spacing = 6
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        let leftContainer = NSStackView(views: [leftStack])
        leftContainer.orientation = .vertical
        leftContainer.spacing = 8
        leftContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            leftContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])

        // 右:日志
        let logTitle = NSTextField(labelWithString: "操作日志")
        logTitle.font = .boldSystemFont(ofSize: 14)
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.backgroundColor = .textBackgroundColor
        let logScroll = NSScrollView()
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder

        let rightStack = NSStackView(views: [logTitle, logScroll])
        rightStack.orientation = .vertical
        rightStack.spacing = 6
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])

        // 整体 split
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(leftContainer)
        split.addArrangedSubview(rightStack)
        split.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(toolbar)
        view.addSubview(split)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            split.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            split.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
        split.setPosition(430, ofDividerAt: 0)
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
        setBusy(true)
        Task {
            let svc = WallpaperService.shared
            let (list, st) = await (svc.list(), svc.status())
            // 合并转码中资产(刷新/其他注入完成时保留进行中的卡片)
            var merged = list
            for (_, pa) in self.pendingAssets where !merged.contains(where: { $0.id == pa.id }) {
                merged.append(pa)
            }
            self.assets = merged
            self.status = st
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
            self.setBusy(false)
        }
    }

    private func setBusy(_ b: Bool) {
        busy = b
        // 转码在后台并行执行:全部按钮可用(可并发注入多个)
        injectButton.isEnabled = true
        deleteButton.isEnabled = selectedID != nil
        selectButton.isEnabled = selectedID != nil
        restoreButton.isEnabled = true
        refreshButton.isEnabled = true
    }

    private func appendLog(_ s: String) {
        logView.textStorage?.append(NSAttributedString(string: s + "\n"))
        logView.scrollToEndOfDocument(nil)
        // 落盘便于诊断
        if let h = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let logFile = h.appendingPathComponent("Logs/mwi_panel.log")
            if let d = (s + "\n").data(using: .utf8) {
                if let fh = try? FileHandle(forWritingTo: logFile) {
                    fh.seekToEndOfFile()
                    fh.write(d)
                    try? fh.close()
                } else {
                    try? d.write(to: logFile)
                }
            }
        }
    }

    // MARK: 操作

    @objc private func doRefresh() { reload() }

    @objc private func doSelect() {
        guard let id = selectedID else { return }
        setBusy(true)
        Task {
            do {
                let out = try await WallpaperService.shared.select(id: id)
                self.appendLog("select \(id.prefix(8)):\n\(out)")
                try await Task.sleep(nanoseconds: 2_000_000_000)
                self.status = await WallpaperService.shared.status()
                            } catch {

                self.appendLog("ERROR(select): \(error.localizedDescription)")
                self.showError(error.localizedDescription)
            }
            self.setBusy(false)
        }
    }

    @objc private func doInject() {
        let sheet = InjectSheetController { [weak self] video, name, thumb, newCat in
            guard let self, let video else { return }
            self.runPrepare(video: video, name: name, thumb: thumb, newCat: newCat)
        }
        presentAsSheet(sheet)
    }

    private func runPrepare(video: URL, name: String, thumb: URL?, newCat: String?) {
        setBusy(true)
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
            self.setBusy(false)
        }
    }

    @objc private func doDelete() {
        guard let id = selectedID else { return }
        guard let asset = assets.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "删除资产?"
        alert.informativeText = "将从 entries 移除 \(asset.name),并删除其视频/缩略图。若它是当前壁纸,choice 恢复 用户壁纸。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setBusy(true)
        Task {
            do {
                let out = try await WallpaperService.shared.delete(id: id)
                self.appendLog("delete:\(out)")
                self.appendLog("refresh: 同步面板模型...")
                let r = try await WallpaperService.shared.refresh()
                self.appendLog(r)
                let svc = WallpaperService.shared
                self.assets = await svc.list()
                self.status = await svc.status()
                self.rebuildGroups()
                self.collectionView.reloadData()
                            } catch {
                self.appendLog("ERROR(delete): \(error.localizedDescription)")
                self.showError(error.localizedDescription)
            }
            self.setBusy(false)
        }
    }

    @objc private func doRestore() {
        let alert = NSAlert()
        alert.messageText = "恢复基线?"
        alert.informativeText = "将清理注入资产(entries/Index/视频/缩略图)并恢复 用户壁纸 壁纸。"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setBusy(true)
        Task {
            do {
                let out = try await WallpaperService.shared.restore()
                self.appendLog("restore:\n\(out)")
                let svc = WallpaperService.shared
                self.assets = await svc.list()
                self.status = await svc.status()
                self.rebuildGroups()
                self.pendingAssets.removeAll()
                self.transcodingProgress.removeAll()
                self.transcodingItems.removeAll()
                self.collectionView.reloadData()
                            } catch {

                self.appendLog("ERROR(restore): \(error.localizedDescription)")
                self.showError(error.localizedDescription)
            }
            self.setBusy(false)
        }
    }

    private func showError(_ msg: String) {
        let alert = NSAlert()
        alert.messageText = "错误"
        alert.informativeText = msg
        alert.addButton(withTitle: "好")
        alert.runModal()
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
        header.titleLabel.stringValue = groups[indexPath.section].name
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let ip = indexPaths.first, ip.section < groups.count, ip.item < groups[ip.section].items.count else {
            selectedID = nil
            return
        }
        selectedID = groups[ip.section].items[ip.item].id
        selectButton.isEnabled = selectedID != nil
        deleteButton.isEnabled = selectedID != nil
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectedID = nil
        selectButton.isEnabled = false
        deleteButton.isEnabled = false
    }
}

// MARK: - 资产卡片(壁纸面板式缩略图)

final class AssetCardItem: NSCollectionViewItem {
    let imgView = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let pctLabel = NSTextField(labelWithString: "")  // 缩略图右下:百分比
    private let ringContainer = NSView()             // 缩略图右上:环形进度(仿 wallpaper 下载蓝圈)
    private let ringLayer = CAShapeLayer()           // 背景环
    let progressRing = CAShapeLayer()                // 蓝色进度环(外部更新 strokeEnd)
    private let imgContainer = NSView()              // 缩略图容器(选中蓝框只画在此,不超卡片)

    override var isSelected: Bool {
        didSet {
            imgContainer.wantsLayer = true
            imgContainer.layer?.borderWidth = isSelected ? 2 : 0
            imgContainer.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : nil
            imgContainer.layer?.cornerRadius = 6
        }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 168, height: 100))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 裁切填充(aspect fill),无黑边
        imgView.imageScaling = .scaleAxesIndependently
        imgView.wantsLayer = true
        imgView.layer?.contentsGravity = .resizeAspectFill
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
            imgContainer.widthAnchor.constraint(equalToConstant: 168),
            imgContainer.heightAnchor.constraint(equalToConstant: 78),  // 16:9 紧凑显示
            nameLabel.widthAnchor.constraint(equalToConstant: 168),
        ])
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
                await MainActor.run { self.imgView.image = img }
            }
        } else {
            imgView.image = NSImage(systemSymbolName: asset.downloaded ? "arrow.down.circle.fill" : "photo",
                                    accessibilityDescription: nil)
        }
    }
}

// MARK: - 分类标题

final class AssetHeaderView: NSView {
    let titleLabel = NSTextField(labelWithString: "")

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
}

// MARK: - 注入面板(AppKit sheet)

@MainActor
final class InjectSheetController: NSViewController {
    private let onSubmit: (URL?, String, URL?, String?) -> Void
    private var videoURL: URL?
    private let videoField = NSTextField(labelWithString: "(未选择)")
    private let nameField = NSTextField()
    private let catField = NSTextField()

    init(onSubmit: @escaping (URL?, String, URL?, String?) -> Void) {
        self.onSubmit = onSubmit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 240))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "注入新壁纸"

        let videoRow = row("视频:", videoField, button: "选择…", action: #selector(pickVideo))
        let nameRow = row("名称:", nameField, button: nil, action: nil)
        let catRow = row("新分类:", catField, button: nil, action: nil)
        catField.stringValue = "MWI"
        catField.placeholderString = "新分类名(默认 MWI 独立分类)"

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "注入", target: self, action: #selector(okTapped))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, ok])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [videoRow, nameRow, catRow, buttons])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
        ])
    }

    private func row(_ label: String, _ field: NSTextField, button: String?, action: Selector?) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 56).isActive = true
        field.lineBreakMode = .byTruncatingMiddle
        if field.isEditable { field.isEditable = true }
        let stack = NSStackView(views: [l, field])
        stack.orientation = .horizontal
        stack.spacing = 8
        if let button, let action {
            let b = NSButton(title: button, target: self, action: action)
            b.bezelStyle = .rounded
            stack.addArrangedSubview(b)
        }
        return stack
    }

    @objc private func pickVideo() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url {
            videoURL = url
            videoField.stringValue = url.lastPathComponent
            if nameField.stringValue.isEmpty {
                nameField.stringValue = url.deletingPathExtension().lastPathComponent
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
        onSubmit(videoURL, name, nil, cat.isEmpty ? nil : cat)
        dismiss(self)
    }
}
