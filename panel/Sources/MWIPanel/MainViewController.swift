import AppKit
import UniformTypeIdentifiers

// MARK: - 主界面(AppKit)

@MainActor
final class MainViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var assets: [InjectedAsset] = []
    private var status: StatusInfo?
    private var selectedID: String?
    private var busy = false

    // 视图
    private let tableView = NSTableView()
    private let logView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "未选择注入资产")
    private let statusDots = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let selectButton = NSButton(title: "设为壁纸", target: nil, action: nil)
    private let injectButton = NSButton(title: "注入新壁纸", target: nil, action: nil)
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
        configure(refreshButton, #selector(doRefresh), "arrow.clockwise")
        toolbar.addArrangedSubview(selectButton)
        toolbar.addArrangedSubview(injectButton)
        toolbar.addArrangedSubview(restoreButton)
        toolbar.addArrangedSubview(NSView())
        toolbar.addArrangedSubview(refreshButton)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        // 左:标题 + 列表
        let listTitle = NSTextField(labelWithString: "注入资产")
        listTitle.font = .boldSystemFont(ofSize: 14)
        let listScroll = NSScrollView()
        let column = NSTableColumn(identifier: .init("name"))
        column.title = "资产"
        column.width = 260
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 30
        tableView.allowsEmptySelection = true
        listScroll.documentView = tableView
        listScroll.hasVerticalScroller = true

        let leftStack = NSStackView(views: [listTitle, listScroll])
        leftStack.orientation = .vertical
        leftStack.spacing = 6
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        // 状态条
        let statusIcon = NSTextField(labelWithString: "⏸")
        statusIcon.font = .systemFont(ofSize: 14)
        statusDots.font = .systemFont(ofSize: 10)
        statusDots.textColor = .secondaryLabelColor
        let statusStack = NSStackView(views: [statusIcon, statusLabel, NSView(), statusDots])
        statusStack.orientation = .horizontal
        statusStack.spacing = 8

        let leftContainer = NSStackView(views: [leftStack, statusStack])
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
            self.assets = list
            self.status = st
            self.tableView.reloadData()
            self.updateStatusBar()
            self.appendLog("已加载 \(list.count) 个注入资产")
            if !st.assetID.isEmpty {
                self.appendLog("当前: \(st.name)(\(st.assetID.prefix(8))) \(st.playing ? "PLAYING" : "")")
            }
            self.setBusy(false)
        }
    }

    private func setBusy(_ b: Bool) {
        busy = b
        selectButton.isEnabled = !b && selectedID != nil
        injectButton.isEnabled = !b
        restoreButton.isEnabled = !b
        refreshButton.isEnabled = !b
    }

    private func updateStatusBar() {
        guard let s = status else {
            statusLabel.stringValue = "未选择注入资产"
            statusDots.stringValue = ""
            return
        }
        statusLabel.stringValue = s.assetID.isEmpty ? "未选择注入资产"
            : (s.name.isEmpty ? String(s.assetID.prefix(8)) : s.name)
        statusDots.stringValue = s.playing ? "● 播放中" : "○ 未播放"
        statusDots.textColor = s.playing ? .systemGreen : .secondaryLabelColor
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
                self.updateStatusBar()
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
        Task {
            do {
                let out = try await WallpaperService.shared.prepare(
                    videoURL: video, name: name, thumbnailURL: thumb, newCategory: newCat)
                self.appendLog("prepare \(name):\n\(out)")
                self.appendLog("refresh: 重查面板模型...")
                let r = try await WallpaperService.shared.refresh()
                self.appendLog(r)
                self.assets = await WallpaperService.shared.list()
                self.tableView.reloadData()
            } catch {

                self.appendLog("ERROR(prepare): \(error.localizedDescription)")
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
                self.tableView.reloadData()
                self.updateStatusBar()
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

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { assets.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let asset = assets[row]
        let cell = NSTableCellView()
        let icon = NSTextField(labelWithString: asset.downloaded ? "⬇" : "○")
        icon.font = .systemFont(ofSize: 12)
        let name = NSTextField(labelWithString: asset.name)
        name.lineBreakMode = .byTruncatingTail
        let cat = NSTextField(labelWithString: asset.categories.joined(separator: ", "))
        cat.font = .systemFont(ofSize: 10)
        cat.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, name])
        stack.orientation = .horizontal
        stack.spacing = 6
        let outer = NSStackView(views: [stack, cat])
        outer.orientation = .vertical
        outer.spacing = 0
        outer.alignment = .leading
        cell.addSubview(outer)
        outer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            outer.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            outer.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        selectedID = row >= 0 && row < assets.count ? assets[row].id : nil
        selectButton.isEnabled = !busy && selectedID != nil
    }
}

// MARK: - 注入面板(AppKit sheet)

@MainActor
final class InjectSheetController: NSViewController {
    private let onSubmit: (URL?, String, URL?, String?) -> Void
    private var videoURL: URL?
    private var thumbURL: URL?
    private let videoField = NSTextField(labelWithString: "(未选择)")
    private let thumbField = NSTextField(labelWithString: "(可选,缺省自动抽帧)")
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
        let thumbRow = row("缩略图:", thumbField, button: "选择…", action: #selector(pickThumb))
        let catRow = row("新分类:", catField, button: nil, action: nil)
        catField.placeholderString = "留空归入 Landscape;填则新建独立分类"

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "注入", target: self, action: #selector(okTapped))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, ok])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [videoRow, nameRow, thumbRow, catRow, buttons])
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

    @objc private func pickThumb() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url {
            thumbURL = url
            thumbField.stringValue = url.lastPathComponent
        }
    }

    @objc private func cancelTapped() {
        dismiss(self)
    }

    @objc private func okTapped() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard videoURL != nil, !name.isEmpty else { return }
        let cat = catField.stringValue.trimmingCharacters(in: .whitespaces)
        onSubmit(videoURL, name, thumbURL, cat.isEmpty ? nil : cat)
        dismiss(self)
    }
}
