import AppKit
import Carbon
import ApplicationServices

extension LabController {
    @objc func showDiagnostics() {
        if let diagnosticsWindow {
            diagnosticsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let diagnostic = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        diagnostic.title = "力度与诊断"
        diagnostic.minSize = NSSize(width: 640, height: 720)
        diagnostic.isReleasedWhenClosed = false
        diagnosticsWindow = diagnostic
        let container = NSView()
        diagnostic.contentView = container
        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.heightAnchor.constraint(equalToConstant: 168).isActive = true
        let counts = stack([ownCount, globalCount], vertical: false, spacing: 24)
        let tools = stack([button("清空记录", self, #selector(clearRecords)),
                           button("导出诊断…", self, #selector(exportReport))], vertical: false, spacing: 8)
        let summary = makeTextBox(summaryView, height: 75)
        let log = makeTextBox(logView, height: 100)
        let root = stack([pad, live, counts, samples, overlayCount, tapStatus, tools, summary, log], spacing: 11)
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            root.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20)
        ])
        for v in [pad, summary, log] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        live.preferredMaxLayoutWidth = 620
        tapStatus.preferredMaxLayoutWidth = 620
        diagnostic.center()
        diagnostic.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func makeTextBox(_ text: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        scroll.documentView = text
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 9, height: 7)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textColor = .labelColor
        text.backgroundColor = .textBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    func append(_ event: EventRecord) {
        if records.count >= 8000 { records.removeFirst(256); droppedRecords += 256 }
        records.append(event)
    }

    func addLine(_ value: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - startUptime
        lines.append(String(format: "%7.2fs  ", elapsed) + value)
        if lines.count > 120 { lines.removeFirst(lines.count-120) }
        dirty = true
    }

    func refresh() {
        refreshHome()
        guard dirty else { return }
        dirty = false
        ownCount.stringValue = "窗口重按  \(ownDeep)"
        globalCount.stringValue = "跨 App 重按  \(gestureDeep)"
        samples.stringValue = "压感事件：本窗口 \(ownSamples) · 跨 App \(gestureSamples)"
        overlayCount.stringValue = "指针浮层：\(overlayDeep) 次重按 · \(overlaySamples) 个压感事件"
        gestureCount.stringValue = "重按菜单 \(pressMenusShown) 次 · 动作完成 \(actionsCompleted) 次"
        var text = "来源 / App                       点击    压感事件    重按\n"
        for s in statistics.values.sorted(by: { ($0.source, $0.app) < ($1.source, $1.app) }) {
            let name = s.source == "local" ? "本窗口" : s.source == "overlay" ? "指针浮层" : s.source == "gestureTap" ? "跨 App" : "其他事件"
            text += "\(name) / \(s.app)    \(s.clicks)       \(s.pressureEvents)       \(s.deepPresses)\n"
        }
        text += "鼠标事件：\(tapClicks) 次鼠标按下；不推算重按。"
        summaryView.string = text
        logView.string = lines.suffix(120).joined(separator: "\n")
        logView.scrollToEndOfDocument(nil)
    }

    @objc func clearRecords() {
        records.removeAll(); statistics.removeAll(); lines.removeAll()
        ownDeep = 0; otherDeep = 0; ownSamples = 0; otherSamples = 0; tapClicks = 0
        overlayDeep = 0; overlaySamples = 0
        gestureDeep = 0; gestureSamples = 0
        menusShown = 0; pressMenusShown = 0; actionsCompleted = 0
        menuResponseMilliseconds.removeAll()
        inputStatsStart = inputManager.stats
        dismissActionMenu(reason: "清空记录")
        captureOverlay.dismiss(reason: "开始新一轮记录", notify: false)
        droppedRecords = 0
        startedAt = Date(); startUptime = ProcessInfo.processInfo.systemUptime
        lastDragRecord.removeAll()
        cancelPendingMenu()
        cancelCycles()
        live.stringValue = "记录已清空，请先松开再重按"
        addLine("开始新一轮记录。")
        refresh()
    }

    @objc func exportReport() {
        let save = NSSavePanel()
        save.nameFieldStringValue = "Presslet-diagnostics.json"
        save.title = "导出诊断记录"
        save.message = "保存事件和计数。报告不包含选中文字、按键内容或屏幕。"
        save.beginSheetModal(for: diagnosticsWindow?.isVisible == true ? diagnosticsWindow! : window) { [weak self] response in
            guard let self, response == .OK, let url = save.url else { return }
            do {
                let data = try self.reportData()
                try data.write(to: url, options: .atomic)
                self.feedback.stringValue = "报告已保存：\(url.lastPathComponent)"
                self.addLine("用户已导出本次报告。")
            } catch {
                self.feedback.stringValue = "报告保存失败：\(error.localizedDescription)"
            }
        }
    }

    func reportData() throws -> Data {
        struct Report: Encodable {
            let formatVersion: Int
            let appVersion: String
            let appBuild: String
            let mouseReleaseDelivery: String
            let startedAt: String
            let exportedAt: String
            let os: String
            let globalMonitorInstalled: Bool
            let cgTapInstalled: Bool
            let cgTapEnabled: Bool
            let inputMonitoringAllowed: Bool
            let accessibilityAllowed: Bool
            let activeFiltering: Bool
            let configuredProfileCount: Int
            let configurationPath: String
            let configuredActionsSubmitted: Int
            let configuredActionFailures: Int
            let menuProfileBundleID: String
            let edgeTakeoverSelected: Bool
            let blockedPressureEvents: Int
            let blockedPresses: Int
            let blockedDragEvents: Int
            let pairedMouseUps: Int
            let isPaused: Bool
            let primaryInput: String
            let autoMenuEnabled: Bool
            let primaryPressureEvents: Int
            let primaryDeepPresses: Int
            let menusShown: Int
            let pressMenusShown: Int
            let actionsCompleted: Int
            let menuMotion: String
            let menuTrigger: String
            let menuResponseLastMilliseconds: Double?
            let menuResponseAverageMilliseconds: Double?
            let menuResponseMaxMilliseconds: Double?
            let reducedMotion: Bool
            let hotkeyStatus: String
            let localPressureEvents: Int
            let localDeepPresses: Int
            let globalPressureEvents: Int
            let globalDeepPresses: Int
            let overlayPressureEvents: Int
            let overlayDeepPresses: Int
            let gestureTapSelected: Bool
            let gestureTapPressureEvents: Int
            let gestureTapDeepPresses: Int
            let rawGestureEvents: Int
            let auxiliaryMouseDowns: Int
            let recordsDiscarded: Int
            let countsMeaning: String
            let perApp: [AppStats]
            let activity: [String]
            let events: [EventRecord]
        }
        let iso = ISO8601DateFormatter()
        let report = Report(formatVersion: 4,
                            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                            mouseReleaseDelivery: "The original physical mouse-up continues through the session tap at the last passed-through position. pairedMouseUps counts tap returns, not confirmed application receipt.",
                            startedAt: iso.string(from: startedAt),
                            exportedAt: iso.string(from: Date()), os: ProcessInfo.processInfo.operatingSystemVersionString,
                            globalMonitorInstalled: inputState.hasGlobalMonitor, cgTapInstalled: inputState.hasTap,
                            cgTapEnabled: inputState.tapEnabled,
                            inputMonitoringAllowed: CGPreflightListenEventAccess(),
                            accessibilityAllowed: AXIsProcessTrusted(), activeFiltering: activeFiltering,
                            configuredProfileCount: configurationStore.configuration.profiles.count,
                            configurationPath: configurationStore.fileURL.path,
                            configuredActionsSubmitted: configuredActionsSubmitted,
                            configuredActionFailures: configuredActionFailures,
                            menuProfileBundleID: menuProfileBundleID,
                            edgeTakeoverSelected: shouldIntercept(bundleID: "com.microsoft.edgemac"),
                            blockedPressureEvents: blockedPressureEvents, blockedPresses: blockedPresses,
                            blockedDragEvents: max(0, inputManager.stats.blockedDragEvents - inputStatsStart.blockedDragEvents),
                            pairedMouseUps: max(0, inputManager.stats.pairedMouseUps - inputStatsStart.pairedMouseUps),
                            isPaused: isPaused,
                            primaryInput: "gestureTap", autoMenuEnabled: menuOnRelease.state == .on,
                            primaryPressureEvents: gestureSamples, primaryDeepPresses: gestureDeep,
                            menusShown: menusShown, pressMenusShown: pressMenusShown, actionsCompleted: actionsCompleted,
                            menuMotion: "compact glass layout for 1-9 actions; continuous 17pt action corners; enter 320ms; exit 220ms; display-linked velocity-preserving pressure and attraction springs; fixed cancel target with depression and release rebound; reduced motion supported",
                            menuTrigger: "first stage 2; ordered asynchronous main-queue delivery before mouse release; response measured from the native event timestamp through presentation submission, including queue delay, not displayed-frame latency",
                            menuResponseLastMilliseconds: menuResponseMilliseconds.last,
                            menuResponseAverageMilliseconds: menuResponseMilliseconds.isEmpty ? nil : menuResponseMilliseconds.reduce(0, +) / Double(menuResponseMilliseconds.count),
                            menuResponseMaxMilliseconds: menuResponseMilliseconds.max(),
                            reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                            hotkeyStatus: hotKeyStatus,
                            localPressureEvents: ownSamples, localDeepPresses: ownDeep,
                            globalPressureEvents: otherSamples, globalDeepPresses: otherDeep,
                            overlayPressureEvents: overlaySamples, overlayDeepPresses: overlayDeep,
                            gestureTapSelected: gestureEnabled.state == .on,
                            gestureTapPressureEvents: gestureSamples, gestureTapDeepPresses: gestureDeep,
                            rawGestureEvents: rawGestureEvents,
                            auxiliaryMouseDowns: tapClicks, recordsDiscarded: droppedRecords,
                            countsMeaning: "Deep presses count the first stage >= 2 of each real NSEvent pressure cycle. Overlay pressure is received by our own nonactivating panel; its app identity describes the foreground app before showing the overlay. The optional gestureTap path follows Hammerspoon's CG gesture (29) to NSEvent pressure conversion; it excludes our process and active overlay before counting pressure. Raw gesture totals may include our process. Manual previews and CGEventTap mousePressure are excluded. Zero global events means none observed in this session. Event records retain the newest 8000 entries; summary counts cover the session. Drag samples are limited to 20 per second per source. Global app identity is the frontmost app at observation time, not a verified event recipient.",
                            perApp: statistics.values.sorted { ($0.source, $0.app) < ($1.source, $1.app) },
                            activity: lines, events: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }
}
