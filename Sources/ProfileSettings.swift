import AppKit
import UniformTypeIdentifiers

private func settingsLabel(_ text: String, size: CGFloat = 13, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size)
    field.textColor = color
    return field
}

private final class ProfileActionsDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class ProfileActionRow: NSView, NSTextFieldDelegate {
    let titleField = NSTextField()
    let valueField = NSTextField()
    let kindPopup = NSPopUpButton()
    private let inputPopup = NSPopUpButton()
    private let inputKinds = ActionInputRequirement.allCases
    let enabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let help = settingsLabel("", size: 11, color: .secondaryLabelColor)
    private let upButton = NSButton(title: "↑", target: nil, action: nil)
    private let downButton = NSButton(title: "↓", target: nil, action: nil)
    private let deleteButton = NSButton(title: "−", target: nil, action: nil)
    private let chooseAppButton = NSButton(title: "选择应用…", target: nil, action: nil)
    var action: MenuAction
    var onChange: ((MenuAction) -> Void)?
    var onMove: ((Int) -> Void)?
    var onDelete: (() -> Void)?
    private let kinds: [ActionKind] = [.shortcut, .open, .workflow]

    init(action: MenuAction, index: Int, count: Int) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        titleField.stringValue = action.title
        titleField.placeholderString = "菜单名称"
        titleField.delegate = self
        valueField.stringValue = action.value
        valueField.delegate = self
        kindPopup.addItems(withTitles: kinds.map { $0.displayName })
        kindPopup.selectItem(at: kinds.firstIndex(of: action.kind) ?? 0)
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)
        inputPopup.addItems(withTitles: inputKinds.map { $0.displayName })
        inputPopup.selectItem(at: inputKinds.firstIndex(of: action.inputRequirement) ?? 0)
        inputPopup.target = self
        inputPopup.action = #selector(inputChanged)
        inputPopup.setAccessibilityLabel("动作 \(index + 1) 输入要求")
        enabledButton.state = action.isEnabled ? .on : .off
        enabledButton.target = self
        enabledButton.action = #selector(enabledChanged)
        enabledButton.toolTip = "在菜单中显示这个动作"
        upButton.target = self
        upButton.action = #selector(moveActionUp)
        upButton.isEnabled = index > 0
        upButton.toolTip = "上移"
        downButton.target = self
        downButton.action = #selector(moveActionDown)
        downButton.isEnabled = index + 1 < count
        downButton.toolTip = "下移"
        deleteButton.target = self
        deleteButton.action = #selector(remove)
        deleteButton.toolTip = "删除动作"
        for b in [upButton, downButton, deleteButton] { b.bezelStyle = .rounded }
        enabledButton.setAccessibilityLabel("启用动作 \(index + 1)")
        titleField.setAccessibilityLabel("动作 \(index + 1) 名称")
        valueField.setAccessibilityLabel("动作 \(index + 1) 内容")
        let heading = NSStackView(views: [enabledButton, titleField, kindPopup, upButton, downButton, deleteButton])
        heading.orientation = .horizontal
        heading.spacing = 6
        heading.alignment = .centerY
        chooseAppButton.bezelStyle = .rounded
        chooseAppButton.target = self
        chooseAppButton.action = #selector(chooseApplication)
        chooseAppButton.setContentHuggingPriority(.required, for: .horizontal)
        chooseAppButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let valueRow = NSStackView(views: [valueField, chooseAppButton])
        valueRow.orientation = .horizontal
        valueRow.spacing = 7
        valueRow.alignment = .centerY
        valueRow.detachesHiddenViews = true
        let inputRow = NSStackView(views: [settingsLabel("使用内容", size: 12, color: .secondaryLabelColor), inputPopup])
        inputRow.spacing = 8
        let content = NSStackView(views: [heading, valueRow, inputRow, help])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 5
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            heading.widthAnchor.constraint(equalTo: content.widthAnchor),
            titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            kindPopup.widthAnchor.constraint(equalToConstant: 150),
            upButton.widthAnchor.constraint(equalToConstant: 29),
            downButton.widthAnchor.constraint(equalToConstant: 29),
            deleteButton.widthAnchor.constraint(equalToConstant: 29),
            valueRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            help.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        refreshHelp()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func refreshHelp() {
        chooseAppButton.isHidden = action.kind != .open
        switch action.kind {
        case .shortcut:
            valueField.placeholderString = "例如 cmd+l 或 cmd+shift+t"
            help.stringValue = "输入要求用于确认选区；快捷键仍发送给原 App，不会自动粘贴内容。"
        case .open:
            valueField.placeholderString = "网址、应用标识，或 .app 完整路径"
            help.stringValue = action.inputRequirement == .none
                ? "可选择应用或填写网址。选择文件输入后，会用指定应用打开这些文件。"
                : "文件会交给指定应用打开；网址和文字输入不适用于此动作。"
        case .workflow:
            valueField.placeholderString = "快捷指令名称"
            help.stringValue = action.inputRequirement == .none
                ? "运行「快捷指令」App 中已有的同名快捷指令。"
                : "将选中的内容作为输入传给同名快捷指令；请在快捷指令中接收文字或文件。"
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        action.title = titleField.stringValue
        action.value = valueField.stringValue
        onChange?(action)
    }
    @objc private func inputChanged() {
        action.inputRequirement = inputKinds[inputPopup.indexOfSelectedItem]
        refreshHelp()
        onChange?(action)
    }
    @objc private func kindChanged() {
        action.kind = kinds[kindPopup.indexOfSelectedItem]
        refreshHelp()
        onChange?(action)
    }
    @objc private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择要打开的应用"
        panel.prompt = "选择应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard let hostWindow = window else { return }
        panel.beginSheetModal(for: hostWindow) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            let target = Bundle(url: url)?.bundleIdentifier ?? url.path
            self.valueField.stringValue = target
            self.action.value = target
            self.onChange?(self.action)
        }
    }
    @objc private func enabledChanged() { action.isEnabled = enabledButton.state == .on; onChange?(action) }
    @objc private func moveActionUp() { onMove?(-1) }
    @objc private func moveActionDown() { onMove?(1) }
    @objc private func remove() { onDelete?() }
}

final class ProfileSettingsController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    var onPreview: ((AppProfile) -> Void)?
    var onRequestFinderAccess: (() -> Void)?
    private let finderAccessButton = NSButton(title: "允许读取 Finder 选中文件…", target: nil, action: nil)
    private var configuration: ActionConfiguration
    private var savedConfiguration: ActionConfiguration
    private let onSave: (ActionConfiguration) throws -> Void
    private var selectedIndex = 0
    private var dirty = false
    var hasUnsavedChanges: Bool { dirty }
    private let table = NSTableView()
    private let nameField = NSTextField()
    private let appIDLabel = settingsLabel("", size: 11, color: .secondaryLabelColor)
    private let enabledButton = NSButton(checkboxWithTitle: "在这个 App 中启用菜单", target: nil, action: nil)
    private let interceptButton = NSButton(checkboxWithTitle: "接管系统重按", target: nil, action: nil)
    private let actionStack = NSStackView()
    private let emptyHint = settingsLabel("还没有动作。点击「添加动作」开始。", color: .secondaryLabelColor)
    private let statusLabel = settingsLabel("配置已保存", size: 12, color: .secondaryLabelColor)
    private let deleteProfileButton = NSButton(title: "−", target: nil, action: nil)
    private let addActionButton = NSButton(title: "添加动作", target: nil, action: nil)
    private let presetButton = NSButton(title: "填入预设…", target: nil, action: nil)
    private let previewButton = NSButton(title: "预览菜单", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let actionCount = settingsLabel("", size: 12, color: .secondaryLabelColor)
    private let editor = NSView()

    init(configuration: ActionConfiguration, onSave: @escaping (ActionConfiguration) throws -> Void) {
        self.configuration = configuration
        self.savedConfiguration = configuration
        self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "按 App 配置"
        window.minSize = NSSize(width: 870, height: 580)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        refreshProfile()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload(configuration: ActionConfiguration) {
        self.configuration = configuration
        self.savedConfiguration = configuration
        selectedIndex = min(selectedIndex, max(0, configuration.profiles.count - 1))
        dirty = false
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        refreshProfile()
        refreshStatus()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let sidebar = NSView()
        let sidebarTitle = settingsLabel("应用", size: 13)
        sidebarTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let sidebarHelp = settingsLabel("未单独配置的 App 使用「通用」。", size: 11, color: .secondaryLabelColor)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 45
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        let addProfileButton = NSButton(title: "+", target: self, action: #selector(addProfile))
        addProfileButton.toolTip = "添加应用"
        deleteProfileButton.target = self
        deleteProfileButton.action = #selector(deleteProfile)
        deleteProfileButton.toolTip = "移除应用配置"
        let sidebarButtons = NSStackView(views: [addProfileButton, deleteProfileButton])
        sidebarButtons.orientation = .horizontal
        sidebarButtons.spacing = 5
        for view in [sidebarTitle, sidebarHelp, listScroll, sidebarButtons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(view)
        }
        let separator = NSBox()
        separator.boxType = .separator
        for view in [sidebar, separator, editor] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor), sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 210),
            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), separator.topAnchor.constraint(equalTo: content.topAnchor),
            separator.bottomAnchor.constraint(equalTo: content.bottomAnchor), separator.widthAnchor.constraint(equalToConstant: 1),
            editor.leadingAnchor.constraint(equalTo: separator.trailingAnchor), editor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editor.topAnchor.constraint(equalTo: content.topAnchor), editor.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16), sidebarTitle.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 20),
            sidebarHelp.leadingAnchor.constraint(equalTo: sidebarTitle.leadingAnchor), sidebarHelp.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            sidebarHelp.topAnchor.constraint(equalTo: sidebarTitle.bottomAnchor, constant: 7),
            listScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 7), listScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -7),
            listScroll.topAnchor.constraint(equalTo: sidebarHelp.bottomAnchor, constant: 14), listScroll.bottomAnchor.constraint(equalTo: sidebarButtons.topAnchor, constant: -10),
            sidebarButtons.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12), sidebarButtons.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16)
        ])
        nameField.font = .systemFont(ofSize: 22, weight: .semibold)
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.delegate = self
        nameField.setAccessibilityLabel("应用显示名称")
        enabledButton.target = self
        enabledButton.action = #selector(profileOptionsChanged)
        interceptButton.target = self
        interceptButton.action = #selector(profileOptionsChanged)
        let interceptHelp = settingsLabel("开启后由按刻处理重按，避免同时出现系统查词或预览。", size: 11, color: .secondaryLabelColor)
        let sectionTitle = settingsLabel("菜单动作", size: 13)
        sectionTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        finderAccessButton.target = self
        finderAccessButton.action = #selector(requestFinderAccess)
        finderAccessButton.bezelStyle = .rounded
        let actionHeader = NSStackView(views: [sectionTitle, actionCount, finderAccessButton])
        actionHeader.orientation = .horizontal
        actionHeader.spacing = 12
        actionStack.orientation = .vertical
        actionStack.alignment = .leading
        actionStack.spacing = 9
        let document = ProfileActionsDocument()
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(actionStack)
        let actionsScroll = NSScrollView()
        actionsScroll.documentView = document
        actionsScroll.hasVerticalScroller = true
        actionsScroll.drawsBackground = false
        actionsScroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: actionsScroll.contentView.widthAnchor),
            actionStack.leadingAnchor.constraint(equalTo: document.leadingAnchor), actionStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -5),
            actionStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 3), actionStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8)
        ])
        addActionButton.target = self
        addActionButton.action = #selector(addAction)
        presetButton.target = self
        presetButton.action = #selector(applyPreset)
        let actionButtons = NSStackView(views: [addActionButton, presetButton])
        actionButtons.orientation = .horizontal
        actionButtons.spacing = 8
        previewButton.target = self
        previewButton.action = #selector(preview)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        let footer = NSStackView(views: [statusLabel, NSView(), previewButton, saveButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        for view in [nameField, appIDLabel, enabledButton, interceptButton, interceptHelp, actionHeader, actionsScroll, actionButtons, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            editor.addSubview(view)
        }
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: editor.leadingAnchor, constant: 24), nameField.trailingAnchor.constraint(equalTo: editor.trailingAnchor, constant: -24),
            nameField.topAnchor.constraint(equalTo: editor.topAnchor, constant: 20),
            appIDLabel.leadingAnchor.constraint(equalTo: nameField.leadingAnchor), appIDLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 4),
            appIDLabel.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            enabledButton.leadingAnchor.constraint(equalTo: nameField.leadingAnchor), enabledButton.topAnchor.constraint(equalTo: appIDLabel.bottomAnchor, constant: 17),
            interceptButton.leadingAnchor.constraint(equalTo: nameField.leadingAnchor), interceptButton.topAnchor.constraint(equalTo: enabledButton.bottomAnchor, constant: 9),
            interceptHelp.leadingAnchor.constraint(equalTo: nameField.leadingAnchor, constant: 20), interceptHelp.topAnchor.constraint(equalTo: interceptButton.bottomAnchor, constant: 4),
            interceptHelp.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            actionHeader.leadingAnchor.constraint(equalTo: nameField.leadingAnchor), actionHeader.topAnchor.constraint(equalTo: interceptHelp.bottomAnchor, constant: 23),
            actionsScroll.leadingAnchor.constraint(equalTo: nameField.leadingAnchor), actionsScroll.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            actionsScroll.topAnchor.constraint(equalTo: actionHeader.bottomAnchor, constant: 10), actionsScroll.bottomAnchor.constraint(equalTo: actionButtons.topAnchor, constant: -10),
            actionButtons.leadingAnchor.constraint(equalTo: nameField.leadingAnchor), actionButtons.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -18),
            footer.leadingAnchor.constraint(equalTo: nameField.leadingAnchor), footer.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: editor.bottomAnchor, constant: -18)
        ])
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
    }

    @objc private func requestFinderAccess() { onRequestFinderAccess?() }
    func numberOfRows(in tableView: NSTableView) -> Int { configuration.profiles.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard configuration.profiles.indices.contains(row) else { return nil }
        let profile = configuration.profiles[row]
        let cell = NSTableCellView()
        let text = settingsLabel(profile.bundleID == "*" ? "通用" : profile.appName, size: 13,
                                 color: profile.isEnabled ? .labelColor : .secondaryLabelColor)
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard configuration.profiles.indices.contains(table.selectedRow) else { return }
        selectedIndex = table.selectedRow
        refreshProfile()
    }
    private func refreshProfile() {
        guard configuration.profiles.indices.contains(selectedIndex) else { return }
        let profile = configuration.profiles[selectedIndex]
        finderAccessButton.isHidden = profile.bundleID != "com.apple.finder"
        nameField.stringValue = profile.appName
        appIDLabel.stringValue = profile.bundleID == "*" ? "其他 App 的默认菜单" : profile.bundleID
        enabledButton.state = profile.isEnabled ? .on : .off
        interceptButton.state = profile.interceptForceClick ? .on : .off
        deleteProfileButton.isEnabled = profile.bundleID != "*"
        rebuildActions()
    }
    private func rebuildActions() {
        actionStack.arrangedSubviews.forEach { actionStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        guard configuration.profiles.indices.contains(selectedIndex) else { return }
        let profileIndex = selectedIndex
        let actions = configuration.profiles[profileIndex].actions
        actionCount.stringValue = "\(actions.count) / 9"
        addActionButton.isEnabled = actions.count < 9
        if actions.isEmpty { actionStack.addArrangedSubview(emptyHint) }
        for (index, action) in actions.enumerated() {
            let row = ProfileActionRow(action: action, index: index, count: actions.count)
            row.translatesAutoresizingMaskIntoConstraints = false
            actionStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: actionStack.widthAnchor).isActive = true
            row.onChange = { [weak self] value in
                guard let self = self, self.configuration.profiles.indices.contains(profileIndex), self.configuration.profiles[profileIndex].actions.indices.contains(index) else { return }
                self.configuration.profiles[profileIndex].actions[index] = value
                self.markDirty()
            }
            row.onMove = { [weak self] offset in
                guard let self = self else { return }
                self.window?.makeFirstResponder(nil)
                self.configuration.profiles[profileIndex].actions.swapAt(index, index + offset)
                self.markDirty(); self.rebuildActions()
            }
            row.onDelete = { [weak self] in
                guard let self = self else { return }
                self.window?.makeFirstResponder(nil)
                self.configuration.profiles[profileIndex].actions.remove(at: index)
                self.markDirty(); self.rebuildActions()
            }
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        guard configuration.profiles.indices.contains(selectedIndex) else { return }
        configuration.profiles[selectedIndex].appName = nameField.stringValue
        markDirty()
        table.reloadData()
    }
    @objc private func profileOptionsChanged() {
        guard configuration.profiles.indices.contains(selectedIndex) else { return }
        configuration.profiles[selectedIndex].isEnabled = enabledButton.state == .on
        configuration.profiles[selectedIndex].interceptForceClick = interceptButton.state == .on
        markDirty(); table.reloadData()
    }
    private func markDirty() { dirty = true; refreshStatus() }
    private func refreshStatus() {
        statusLabel.stringValue = dirty ? "有未保存的更改" : "配置已保存"
        window?.isDocumentEdited = dirty
    }
    @objc private func addProfile() {
        let panel = NSOpenPanel()
        panel.title = "选择要配置的应用"
        panel.prompt = "添加应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard let window = window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { self.showError("无法读取这个应用的信息。请选择一个 .app 应用。"); return }
            if let existing = self.configuration.profiles.firstIndex(where: { $0.bundleID == bundleID }) {
                self.table.selectRowIndexes(IndexSet(integer: existing), byExtendingSelection: false)
                return
            }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
            var profile = self.configuration.profiles.first(where: { $0.bundleID == "*" }) ?? AppProfile(bundleID: bundleID, appName: name, actions: [])
            profile.id = UUID().uuidString
            profile.bundleID = bundleID
            profile.appName = name
            profile.actions = profile.actions.map { action in var copy = action; copy.id = UUID().uuidString; return copy }
            self.configuration.profiles.append(profile)
            self.selectedIndex = self.configuration.profiles.count - 1
            self.table.reloadData()
            self.table.selectRowIndexes(IndexSet(integer: self.selectedIndex), byExtendingSelection: false)
            self.markDirty(); self.refreshProfile()
        }
    }
    @objc private func deleteProfile() {
        guard configuration.profiles.indices.contains(selectedIndex), configuration.profiles[selectedIndex].bundleID != "*" else { return }
        let alert = NSAlert()
        alert.messageText = "移除「\(configuration.profiles[selectedIndex].appName)」的配置？"
        alert.informativeText = "移除后，这个 App 将使用通用菜单。保存后生效。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        configuration.profiles.remove(at: selectedIndex)
        selectedIndex = max(0, selectedIndex - 1)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        markDirty(); refreshProfile()
    }
    @objc private func addAction() {
        guard configuration.profiles.indices.contains(selectedIndex), configuration.profiles[selectedIndex].actions.count < 9 else { return }
        configuration.profiles[selectedIndex].actions.append(MenuAction(title: "新动作", kind: .shortcut, value: "cmd+l"))
        markDirty(); rebuildActions()
    }
    @objc private func applyPreset() {
        guard configuration.profiles.indices.contains(selectedIndex) else { return }
        let menu = NSMenu()
        for (index, profile) in ActionConfiguration.defaults.profiles.enumerated() {
            let item = NSMenuItem(title: profile.bundleID == "*" ? "通用动作" : profile.appName, action: #selector(presetSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: presetButton.bounds.height + 3), in: presetButton)
    }
    @objc private func presetSelected(_ sender: NSMenuItem) {
        let presets = ActionConfiguration.defaults.profiles
        guard presets.indices.contains(sender.tag), configuration.profiles.indices.contains(selectedIndex) else { return }
        if !configuration.profiles[selectedIndex].actions.isEmpty {
            let alert = NSAlert()
            alert.messageText = "替换当前菜单动作？"
            alert.informativeText = "将填入「\(sender.title)」预设。保存后生效。"
            alert.addButton(withTitle: "替换")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        configuration.profiles[selectedIndex].actions = presets[sender.tag].actions.map { action in var copy = action; copy.id = UUID().uuidString; return copy }
        markDirty(); rebuildActions()
    }
    @objc private func preview() {
        window?.makeFirstResponder(nil)
        guard configuration.profiles.indices.contains(selectedIndex) else { return }
        onPreview?(configuration.profiles[selectedIndex])
    }
    @discardableResult private func saveChanges() -> Bool {
        window?.makeFirstResponder(nil)
        let errors = configuration.validationErrors
        guard errors.isEmpty else { showError(errors.joined(separator: "\n")); return false }
        do { try onSave(configuration); savedConfiguration = configuration; dirty = false; refreshStatus(); return true }
        catch { showError("保存失败：\(error.localizedDescription)"); return false }
    }
    @objc private func save() { _ = saveChanges() }
    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "请检查配置"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        if let window = window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "保存配置更改？"
        alert.informativeText = "关闭后将放弃尚未保存的更改。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "不保存")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveChanges()
        case .alertThirdButtonReturn:
            reload(configuration: savedConfiguration)
            return true
        default: return false
        }
    }
}
