import AppKit
import ApplicationServices

extension LabController {
    @objc func toggleRunning() {
        if runningSwitch.state == .on {
            if isPaused { togglePause() }
            if !observationRequested { toggleObservation() }
        } else {
            stopObservation()
            if !isPaused { togglePause() }
        }
        dirty = true
        refresh()
    }

    @objc func requestInputPermission() {
        if CGPreflightListenEventAccess() {
            tapStatus.stringValue = "系统已允许输入监控；可点击重试恢复跨 App 输入。"
        } else {
            let granted = CGRequestListenEventAccess()
            tapStatus.stringValue = granted ? "输入监控已允许；请重试辅助监听。" : "请在系统设置中允许“按刻”使用输入监控，再返回重试；系统可能要求重开 App。"
        }
        addLine("用户打开了输入监控权限流程。当前状态：\(CGPreflightListenEventAccess() ? "已允许" : "未允许")。")
        dirty = true
    }

    @objc func requestFilterPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let allowed = AXIsProcessTrustedWithOptions(options)
        addLine("辅助功能权限：\(allowed ? "已允许" : "等待允许")。")
        if !allowed {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    @objc func menuPreferenceChanged() {
        updateInputPolicy()
        cancelPendingMenu()
        if menuOnRelease.state != .on { dismissActionMenu(reason: "关闭自动菜单") }
        if menuOnRelease.state == .on {
            addLine("重按菜单已启用；保持按住滑向动作，松手执行。")
        } else { addLine("重按菜单已关闭；保留事件观察。") }
    }

    @objc func togglePause() {
        isPaused.toggle()
        updateInputPolicy()
        contextResolver.cancel()
        cancelPendingMenu()
        for key in Array(cycles.keys) { cycles[key]?.setEnabled(!isPaused) }
        if isPaused { dismissActionMenu(reason: "暂停") }
        if isPaused { captureOverlay.dismiss(reason: "暂停记录") }
        pauseButton.title = isPaused ? "继续记录" : "暂停记录"
        live.stringValue = isPaused ? "记录已暂停" : "记录已恢复，请先松开再重按"
        addLine(isPaused ? "记录已暂停。" : "记录已恢复；等待松开后进入下一个周期。")
    }

    @objc func previewMenu() {
        showActionMenu(origin: "手动预览 · 不计入重按")
    }

    @objc func toggleCaptureOverlay() {
        guard !isPaused else { feedback.stringValue = "请先开启按刻，再打开指针浮层。"; return }
        cancelPendingMenu()
        if !captureOverlay.isVisible {
            let app = NSWorkspace.shared.frontmostApplication
            overlayOrigin = (app?.localizedName ?? "未知应用", app?.bundleIdentifier ?? "unknown")
            _ = cycles["overlay"]?.accept(.mouseUp)
            menuPresenter.dismiss(reason: "打开接收层")
            addLine("呼出重按接收层 · 当前应用 \(overlayOrigin.0)。")
        }
        captureOverlay.show(appName: overlayOrigin.0, bundleID: overlayOrigin.1)
        updateInputPolicy()
    }

    @objc func showProfileSettings() {
        dismissActionMenu(reason: "打开配置")
        if let settings = profileSettings {
            // Existing unsaved edits belong to the editor until saved or discarded.
            settings.showWindow(nil)
            settings.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let settings = ProfileSettingsController(configuration: configurationStore.configuration) { [weak self] configuration in
            guard let self else { return }
            try self.actionProvider.save(configuration)
            self.dismissActionMenu(reason: "配置已更新")
            self.cancelCycles()
            self.contextResolver.cancel()
            self.updateInputPolicy()
            self.feedback.stringValue = "配置已保存，下一次重按即生效。"
            self.addLine("按 App 配置已保存。")
        }
        settings.onRequestFinderAccess = { [weak self] in
            self?.contextResolver.requestFinderAccess { [weak self] allowed in
                self?.feedback.stringValue = allowed ? "已允许读取 Finder 选中文件。" : "尚未允许读取 Finder 文件，请在系统设置的自动化中允许按刻控制 Finder。"
            }
        }
        settings.onPreview = { [weak self] profile in
            self?.showActionMenu(origin: "配置预览", targetBundleID: profile.bundleID, profileOverride: profile)
        }
        profileSettings = settings
        settings.showWindow(nil)
        settings.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
