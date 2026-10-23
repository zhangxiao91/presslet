import AppKit
import ApplicationServices

extension LabController {
    func routeLocalInput(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, menuPresenter.isVisible {
            dismissActionMenu(reason: "按 Esc"); return
        }
        if event.type == .mouseMoved, menuPresenter.hasRadialMenu, !menuPressHeld {
            menuPresenter.updatePointer(screenPoint(for: event))
        }
        if event.type == .leftMouseDown, !inputState.hasTap { suppressGestureUntilUp = menuPresenter.isVisible }
        if menuPresenter.isVisible, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
           !menuPresenter.contains(window: event.window) {
            if event.type == .leftMouseDown { suppressGestureUntilUp = true }
            dismissActionMenu(reason: "点击菜单外")
        }
        if let diagnostic = diagnosticsWindow, event.window === diagnostic { receive(event, source: "local") }
    }

    func routeGlobalInput(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 { dismissActionMenu(reason: "按 Esc"); return }
        if event.type == .mouseMoved, menuPresenter.hasRadialMenu, !menuPressHeld {
            menuPresenter.updatePointer(screenPoint(for: event)); return
        }
        if event.type == .leftMouseDown, !inputState.hasTap {
            gestureCaptureID = contextResolver.beginGesture(for: NSWorkspace.shared.frontmostApplication)
            suppressGestureUntilUp = menuPresenter.isVisible
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
           menuPresenter.isVisible, let frame = menuPresenter.frame, !frame.contains(screenPoint(for: event)) {
            if event.type == .leftMouseDown { suppressGestureUntilUp = true }
            dismissActionMenu(reason: "点击菜单外")
        }
        receive(event, source: "global")
    }

    func screenPoint(for event: NSEvent) -> NSPoint {
        if let cgEvent = event.cgEvent { return appKitPoint(from: cgEvent.location) }
        return event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    func currentApp(source: String) -> (String, String) {
        if source == "local" { return ("按刻", Bundle.main.bundleIdentifier ?? "dev.zxlab.Presslet") }
        if source == "overlay" { return overlayOrigin }
        if source == "gestureTap", let context = gestureContext { return context }
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.localizedName ?? "未知应用", app?.bundleIdentifier ?? "unknown")
    }

    func receive(_ event: NSEvent, source: String) {
        guard !isPaused else { return }
        let (app, bundle) = currentApp(source: source)
        let t = ProcessInfo.processInfo.systemUptime - startUptime
        var isDeep = false
        var stage: Int?
        var force: Double?
        var transition: Double?
        var type: String
        switch event.type {
        case .pressure:
            type = "pressure"
            stage = event.stage
            force = Double(event.pressure)
            transition = Double(event.stageTransition)
            isDeep = cycles[source]?.accept(.pressure(stage: event.stage, value: Double(event.pressure))) ?? false
            if source == "local" { ownSamples += 1 }
            else if source == "overlay" { overlaySamples += 1 }
            else if source == "gestureTap" { gestureSamples += 1 }
            else { otherSamples += 1 }
            let location = source == "local" ? "本窗口" : source == "overlay" ? "指针浮层" : source == "gestureTap" ? "跨 App · \(app)" : app
            live.stringValue = "\(location)  ·  阶段 \(event.stage)  ·  阶段力度 \(String(format: "%.3f", event.pressure))"
            if isDeep {
                if source == "local" { ownDeep += 1 }
                else if source == "overlay" { overlayDeep += 1 }
                else if source == "gestureTap" { gestureDeep += 1 }
                else { otherDeep += 1 }
                addLine("重按 · \(location) · 阶段 \(event.stage)")
                if (source == "gestureTap" || source == "local"), menuOnRelease.state == .on,
                   !menuPresenter.isVisible, !suppressGestureUntilUp, hasActions(bundleID: bundle) {
                    menuShowTask?.cancel()
                    menuShowTask = nil
                    menuGate.arm(source: source, appName: app, bundleID: bundle)
                    pendingMenuStartedUptime = event.timestamp.isFinite && event.timestamp > 0
                        ? event.timestamp : ProcessInfo.processInfo.systemUptime
                    pendingMenuPoint = source == "gestureTap" ? (gestureBeginPoint ?? NSEvent.mouseLocation) : NSEvent.mouseLocation
                    openMenuImmediately(source: source)
                }
            }
            if event.stage == 0, (NSEvent.pressedMouseButtons & 1) == 0 { releaseMenu(source: source) }
        case .leftMouseDown:
            type = "mouseDown"
            if source == "local" { cancelPendingMenu() }
            _ = cycles[source]?.accept(.mouseDown)
        case .leftMouseUp:
            type = "mouseUp"
            _ = cycles[source]?.accept(.mouseUp)
            releaseMenu(source: source, confirmedMouseUp: true, point: screenPoint(for: event))
            if !inputState.hasTap { suppressGestureUntilUp = false }
        case .leftMouseDragged:
            type = "mouseDragged"
            // Drag samples are bounded; pressure events remain unthrottled.
            if t - (lastDragRecord[source] ?? -1) < 0.05 { return }
            lastDragRecord[source] = t
        default: return
        }
        let key = source + ":" + bundle
        var stats = statistics[key] ?? AppStats(app: app, bundleID: bundle, source: source)
        if type == "pressure" { stats.pressureEvents += 1 }
        if type == "mouseDown" { stats.clicks += 1 }
        if isDeep { stats.deepPresses += 1 }
        statistics[key] = stats
        append(EventRecord(elapsed: t, source: source, app: app, bundleID: bundle,
                           type: type, stage: stage, pressure: force, transition: transition, firstDeep: isDeep))
        dirty = true
    }

    func openMenuImmediately(source: String) {
        guard let trigger = menuGate.release(source: source) else { return }
        let point = pendingMenuPoint
        let triggeredAt = pendingMenuStartedUptime ?? ProcessInfo.processInfo.systemUptime
        let sourcePID = gestureSourcePID
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.menuGate.isCurrent(trigger) else { return }
            self.menuShowTask = nil
            guard !self.isPaused, self.menuOnRelease.state == .on,
                  source != "gestureTap" || (self.observationRequested && self.inputState.hasTap
                      && sourcePID != nil && sourcePID == NSWorkspace.shared.frontmostApplication?.processIdentifier),
                  (NSEvent.pressedMouseButtons & 1) != 0 else {
                self.cancelPendingMenu()
                return
            }
            self.pressMenusShown += 1
            self.showActionMenu(origin: "\(source == "gestureTap" ? "跨 App 重按" : "窗口重按") · \(trigger.appName)",
                                near: point, holdUntilMouseUp: true, targetBundleID: trigger.bundleID)
            let response = (ProcessInfo.processInfo.systemUptime - triggeredAt) * 1000
            self.menuResponseMilliseconds.append(response)
            self.addLine("重按至菜单开始显示：\(String(format: "%.1f", response)) ms。")
        }
        menuShowTask?.cancel()
        menuShowTask = task
        // Leave the event-tap callback before constructing and presenting windows.
        DispatchQueue.main.async(execute: task)
    }

    func cancelPendingMenu() {
        menuGate.cancel()
        menuShowTask?.cancel()
        menuShowTask = nil
        pendingMenuStartedUptime = nil
        pendingMenuPoint = nil
    }

    func appKitPoint(from point: CGPoint) -> NSPoint {
        let displayHeight = CGDisplayBounds(CGMainDisplayID()).height
        return NSPoint(x: point.x, y: displayHeight - point.y)
    }

    // Runs after ordered delivery, so app lookup never enters the event tap.
    func acceptsGestureSource(_ event: CGEvent?, allowMenuTarget: Bool = false) -> Bool {
        guard let sourcePID = gestureSourcePID,
              sourcePID == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        let targetPID = event?.getIntegerValueField(.eventTargetUnixProcessID) ?? 0
        return targetPID == 0 || targetPID == Int64(sourcePID)
            || (allowMenuTarget && targetPID == Int64(ProcessInfo.processInfo.processIdentifier))
    }

    func receiveTap(type: CGEventType, event: CGEvent) {
        guard !isPaused else { return }
        if type == .leftMouseDown {
            suppressGestureUntilUp = menuPresenter.isVisible
            if let frame = menuPresenter.frame, menuPresenter.isVisible {
                suppressGestureUntilUp = true
                if !frame.contains(appKitPoint(from: event.location)) { dismissActionMenu(reason: "点击菜单外") }
            }
            if !suppressGestureUntilUp && !captureOverlay.isVisible {
                cancelPendingMenu()
                let front = NSWorkspace.shared.frontmostApplication
                let targetPID = Int32(clamping: event.getIntegerValueField(.eventTargetUnixProcessID))
                guard let app = targetPID > 0 ? NSRunningApplication(processIdentifier: targetPID) : front,
                      app.processIdentifier == front?.processIdentifier else {
                    cancelCycles(); dismissActionMenu(reason: "输入来源已切换")
                    gestureSourcePID = nil; gestureContext = nil; suppressGestureUntilUp = true
                    return
                }
                gestureSourcePID = app.processIdentifier
                gestureCaptureID = contextResolver.beginGesture(for: app)
                gestureContext = (app.localizedName ?? "未知应用", app.bundleIdentifier ?? "unknown")
                gestureBeginPoint = appKitPoint(from: event.location)
                _ = cycles["gestureTap"]?.accept(.mouseDown)
            }
        }
        if type == .leftMouseDragged || type == .leftMouseUp, menuPresenter.hasRadialMenu {
            menuPresenter.updatePointer(appKitPoint(from: event.location))
        }
        if type == .leftMouseUp {
            _ = cycles["gestureTap"]?.accept(.mouseUp)
            releaseMenu(source: "gestureTap", confirmedMouseUp: true, point: appKitPoint(from: event.location))
            suppressGestureUntilUp = false
        }
        let t = ProcessInfo.processInfo.systemUptime - startUptime
        if type == .leftMouseDragged {
            if t - (lastDragRecord["tap"] ?? -1) < 0.05 { return }
            lastDragRecord["tap"] = t
        }
        let app = currentApp(source: "tap")
        let name = type == .leftMouseDown ? "mouseDown" : type == .leftMouseUp ? "mouseUp" : "mouseDragged"
        let pressure = event.getDoubleValueField(.mouseEventPressure)
        if type == .leftMouseDown { tapClicks += 1 }
        append(EventRecord(elapsed: t, source: "tap", app: app.0, bundleID: app.1,
                           type: name, stage: nil, pressure: pressure.isFinite ? pressure : nil,
                           transition: nil, firstDeep: false))
        dirty = true
    }

    func cancelCycles() {
        let input: PressureInput = (NSEvent.pressedMouseButtons & 1) == 0 ? .mouseUp : .cancel
        for key in Array(cycles.keys) { _ = cycles[key]?.accept(input) }
    }
}
