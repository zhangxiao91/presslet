import AppKit
import Carbon
import ApplicationServices

private let accent = NSColor.systemBlue

extension LabController {
    func makeMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let menu = NSMenu()
        menu.addItem(withTitle: "关于按刻", action: #selector(showAbout), keyEquivalent: "")
        let settingsItem = menu.addItem(withTitle: "按 App 配置…", action: #selector(showProfileSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出按刻", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = menu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: "按刻")
        let statusMenu = NSMenu()
        let show = statusMenu.addItem(withTitle: "打开按刻", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        let preview = statusMenu.addItem(withTitle: "预览动作菜单", action: #selector(previewMenu), keyEquivalent: "")
        preview.target = self
        let fallback = statusMenu.addItem(withTitle: "指针浮层  ⌃⌥空格", action: #selector(toggleCaptureOverlay), keyEquivalent: "")
        fallback.target = self
        let configure = statusMenu.addItem(withTitle: "按 App 配置…", action: #selector(showProfileSettings), keyEquivalent: "")
        configure.target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem?.menu = statusMenu
    }

    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "按刻"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let content = NSView()
        window.contentView = content
        menuOnRelease.state = .on
        gestureEnabled.state = .on

        let logo = NSImageView(image: NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: nil)!)
        logo.contentTintColor = accent
        logo.symbolConfiguration = .init(pointSize: 30, weight: .medium)
        logo.widthAnchor.constraint(equalToConstant: 44).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let brand = stack([label("按刻", size: 27, weight: .semibold),
                           label("PRESSLET", size: 10, weight: .medium, color: .secondaryLabelColor)], spacing: 2)
        runningSwitch.target = self
        runningSwitch.action = #selector(toggleRunning)
        runningSwitch.setAccessibilityLabel("启用按刻")
        let status = stack([homeStatus, homeDetail], spacing: 3)
        let header = stack([logo, brand, NSView(), status, runningSwitch], vertical: false, spacing: 13)
        status.alignment = .trailing
        homeDetail.preferredMaxLayoutWidth = 225

        permissionButton.target = self
        permissionButton.action = #selector(requestFilterPermission)
        permissionButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryTap)
        retryButton.bezelStyle = .rounded
        let permissions = stack([permissionButton, retryButton], vertical: false, spacing: 8)
        permissionRow = permissions

        let configure = button("管理 App 动作…", self, #selector(showProfileSettings))
        configure.bezelStyle = .rounded
        configure.controlSize = .large
        configure.keyEquivalent = ","
        configure.keyEquivalentModifierMask = .command
        let appHeader = stack([label("App 动作", size: 19, weight: .semibold), NSView(), configure], vertical: false)
        let appBody = stack([appHeader, profileSummary,
                             label("发送快捷键 · 打开应用或网址 · 运行快捷指令", size: 13, color: .secondaryLabelColor)], spacing: 11)
        let appCard = makeHomeCard(appBody)
        appHeader.widthAnchor.constraint(equalTo: appBody.widthAnchor).isActive = true

        let preview = button("预览菜单", self, #selector(previewMenu))
        let floating = button("打开指针浮层", self, #selector(toggleCaptureOverlay))
        let previewRow = stack([stack([label("随时预览", size: 13, weight: .medium),
                                      label("⌃⌥M", size: 12, color: .secondaryLabelColor)], spacing: 4), NSView(), preview], vertical: false)
        let floatingRow = stack([stack([label("指针浮层", size: 13, weight: .medium),
                                       label("⌃⌥空格 · 为不便直接重按的场景准备", size: 12, color: .secondaryLabelColor)], spacing: 4), NSView(), floating], vertical: false)
        let separator = NSBox()
        separator.boxType = .separator
        let ways = stack([previewRow, separator, floatingRow], spacing: 13)
        for row in [previewRow, floatingRow, separator] {
            row.widthAnchor.constraint(equalTo: ways.widthAnchor).isActive = true
        }
        let waysCard = makeHomeCard(ways)
        let footer = stack([feedback, NSView(), button("诊断…", self, #selector(showDiagnostics))], vertical: false, spacing: 14)
        feedback.preferredMaxLayoutWidth = 530
        feedback.stringValue = "重按后保持按住，滑向动作再松手；回中央取消。"
        let root = stack([header, permissions, appCard, waysCard, NSView(), footer], spacing: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -23)
        ])
        for v in [header, appCard, waysCard, footer] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        profileSummary.preferredMaxLayoutWidth = 590
    }

    func makeHomeCard(_ body: NSStackView) -> NSView {
        let card = NSBox()
        card.boxType = .custom
        card.titlePosition = .noTitle
        card.borderColor = .separatorColor.withAlphaComponent(0.3)
        card.borderWidth = 0.5
        card.cornerRadius = 13
        card.fillColor = .controlBackgroundColor
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        return card
    }

    func refreshHome() {
        let allowed = AXIsProcessTrusted()
        let connected = inputState.tapEnabled
        let ready = connected && activeFiltering
        let enabled = observationRequested && !isPaused
        runningSwitch.state = enabled ? .on : .off
        homeStatus.stringValue = !enabled ? "已暂停" : ready ? "运行中" : "等待连接"
        homeStatus.textColor = enabled && ready ? .systemGreen : .secondaryLabelColor
        homeDetail.stringValue = !allowed ? "允许辅助功能后即可接管重按" : !enabled ? "打开开关即可继续" : ready ? "重按即可呼出动作" : "点重试连接，开启重按接管"
        permissionButton.isHidden = allowed
        retryButton.isHidden = ready || !enabled
        permissionRow?.isHidden = allowed && (ready || !enabled)
        let profiles = configurationStore.configuration.profiles
        let apps = profiles.filter { $0.bundleID != "*" }.count
        let actions = profiles.reduce(0) { $0 + $1.actions.filter { $0.isEnabled }.count }
        profileSummary.stringValue = "已配置 \(apps) 个 App · \(actions) 个动作 · 其他 App 使用通用菜单"
    }

    @objc func showWindow() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }

    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "按刻", .applicationVersion: "1.1.0",
                                                   .credits: NSAttributedString(string: "重按触控板，打开当前 App 的常用动作。\n快捷键、应用与网址、快捷指令，按需配置。")])
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window {
            sender.orderOut(nil)
            return false
        }
        return true
    }
}
