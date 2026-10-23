import AppKit
import ApplicationServices
import Carbon

/// Reads only the active application's selection. No clipboard or synthetic input is used.
final class SelectionContextProvider {
    /// Set on the main queue. Applications without an input action should return false.
    var shouldObserve: ((String) -> Bool)?

    private struct Source {
        let pid: pid_t
        let bundleID: String
        let name: String
    }
    private struct Identity {
        let window: AXUIElement
        let element: AXUIElement
        func matches(_ other: Identity) -> Bool {
            CFEqual(window, other.window) && CFEqual(element, other.element)
        }
    }
    private struct Cached {
        let source: Source
        let identity: Identity
        let context: ActionContext
    }

    private let queue = DispatchQueue(label: "dev.zxlab.Presslet.selection", qos: .userInitiated)
    // AX objects and selected content are confined to queue.
    private var cached: Cached?
    private var observer: AXObserver?
    private var observerApp: AXUIElement?
    private var observerElement: AXUIElement?
    private var observerPID: pid_t?
    private var workerGeneration: UInt64 = 0
    // Lifecycle and application snapshots are confined to the main queue.
    private var activationToken: NSObjectProtocol?
    private var timer: Timer?
    private var generation: UInt64 = 0
    private var running = false
    private var pollPending = false
    private let textLimit = 1_048_576
    private let fileLimit = 100

    deinit {
        timer?.invalidate()
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    func start() {
        onMain { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.activationToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.activeApplicationChanged() }
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.pollActiveApplication()
            }
            self.activeApplicationChanged()
        }
    }

    func stop() {
        onMain { [weak self] in
            guard let self else { return }
            self.running = false
            self.timer?.invalidate()
            self.timer = nil
            if let token = self.activationToken { NSWorkspace.shared.notificationCenter.removeObserver(token) }
            self.activationToken = nil
            self.generation &+= 1
            let version = self.generation
            self.queue.async {
                self.workerGeneration = version
                self.cached = nil
                self.removeAXObserver()
            }
        }
    }

    /// Call at mouse-down. Completion is asynchronous on the main queue.
    /// A fresh cache may survive the click only when both window and focus still match.
    func lockSelection(for app: NSRunningApplication, completion: @escaping (ActionContext) -> Void) {
        read(app: app, allowCached: true, completion: completion)
    }

    func currentSelection(for app: NSRunningApplication, completion: @escaping (ActionContext) -> Void) {
        read(app: app, allowCached: false, completion: completion)
    }

    /// This is the only operation that may show the system's Finder Automation prompt.
    /// Call only from an explicit user action, never while observing or opening the menu.
    func requestFinderAccess(completion: @escaping (Bool) -> Void) {
        queue.async {
            let allowed = self.finderPermission(ask: true) == noErr
            DispatchQueue.main.async { completion(allowed) }
        }
    }

    private func activeApplicationChanged() {
        generation &+= 1
        let version = generation
        queue.async {
            self.workerGeneration = version
            self.cached = nil
            self.removeAXObserver()
        }
        pollActiveApplication()
    }

    private func pollActiveApplication() {
        guard running, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              shouldObserve?(app.bundleIdentifier ?? "") == true else {
            queue.async { self.cached = nil; self.removeAXObserver() }
            return
        }
        // Coalesce on the main queue before submitting work; a slow AX server must
        // not leave an ever-growing queue of stale polling requests.
        guard !pollPending else { return }
        pollPending = true
        let source = Self.source(app)
        let version = generation
        queue.async {
            defer { DispatchQueue.main.async { self.pollPending = false } }
            guard version == self.workerGeneration else { return }
            _ = self.capture(source, allowCached: false, installObserver: true)
        }
    }

    private func read(app: NSRunningApplication, allowCached: Bool,
                      completion: @escaping (ActionContext) -> Void) {
        onMain { [weak self] in
            guard let self else { return }
            let source = Self.source(app)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid else {
                self.queue.async { self.cached = nil }
                completion(self.empty(source, "请先回到原 App，选中内容后再打开菜单。"))
                return
            }
            guard !app.isTerminated, source.pid != ProcessInfo.processInfo.processIdentifier,
                  self.shouldObserve?(source.bundleID) == true else {
                self.queue.async { self.cached = nil }
                completion(self.empty(source, "这个 App 尚未启用需要选中内容的动作。"))
                return
            }
            let version = self.generation
            self.queue.async {
                let result = self.capture(source, allowCached: allowCached, installObserver: false)
                DispatchQueue.main.async {
                    // Switching apps while an AX request is outstanding invalidates its content.
                    guard version == self.generation,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid else {
                        completion(self.empty(source, "读取期间切换了 App，请重新选择。"))
                        return
                    }
                    completion(result)
                }
            }
        }
    }

    private func capture(_ source: Source, allowCached: Bool, installObserver: Bool) -> ActionContext {
        guard AXIsProcessTrusted() else { return invalidate(source, "请在系统设置的“辅助功能”中允许 Presslet 读取选中内容。") }
        let app = AXUIElementCreateApplication(source.pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let identity = identity(for: app) else {
            return invalidate(source, "无法读取这个 App 当前窗口中的选中内容。")
        }
        guard !isSecure(identity.element) else {
            return invalidate(source, "密码输入框中的内容不可读取。")
        }
        if installObserver { updateAXObserver(source: source, app: app, element: identity.element) }
        if allowCached, let saved = cached, saved.source.pid == source.pid,
           saved.source.bundleID == source.bundleID, saved.identity.matches(identity),
           (0...0.5).contains(Date().timeIntervalSince(saved.context.capturedAt)) {
            return saved.context
        }
        let context: ActionContext
        if source.bundleID == "com.apple.finder" {
            context = finderSelection(source)
        } else {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(identity.element, kAXSelectedTextAttribute as CFString, &value)
            guard status == .success, let text = value as? String, !text.isEmpty else {
                return invalidate(source, "没有可读取的选中文字，或这个 App 不提供选文。")
            }
            guard text.utf8.count <= textLimit else { return invalidate(source, "选中文字超过 1 MB，请缩小选择范围。") }
            context = makeContext(source, selectedText: text, files: [])
        }
        if context.selectedText?.isEmpty == false || !context.fileURLs.isEmpty {
            cached = Cached(source: source, identity: identity, context: context)
        } else { cached = nil }
        return context
    }

    private func identity(for app: AXUIElement) -> Identity? {
        guard let window = elementAttribute(app, kAXFocusedWindowAttribute),
              let element = elementAttribute(app, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.15)
        AXUIElementSetMessagingTimeout(element, 0.15)
        return Identity(window: window, element: element)
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let item = current else { break }
            AXUIElementSetMessagingTimeout(item, 0.15)
            for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(item, attribute as CFString, &value)
                if status == .cannotComplete || status == .invalidUIElement { return true }
                if attribute == kAXRoleAttribute && status != .success { return true }
                if let role = value as? String, role == kAXSecureTextFieldSubrole || role == "AXSecureTextField" { return true }
                if attribute == kAXRoleAttribute, value as? String == kAXWindowRole { return false }
            }
            current = elementAttribute(item, kAXParentAttribute)
        }
        return false
    }

    private func updateAXObserver(source: Source, app: AXUIElement, element: AXUIElement) {
        if observerPID != source.pid {
            removeAXObserver()
            var created: AXObserver?
            let status = AXObserverCreate(source.pid, { _, _, _, refcon in
                guard let refcon else { return }
                let owner = Unmanaged<SelectionContextProvider>.fromOpaque(refcon).takeUnretainedValue()
                DispatchQueue.main.async { [weak owner] in owner?.pollActiveApplication() }
            }, &created)
            guard status == .success, let created else { return }
            observer = created
            observerApp = app
            observerPID = source.pid
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            for notification in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
                AXObserverAddNotification(created, app, notification as CFString, pointer)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        }
        guard let observer else { return }
        if let previous = observerElement, CFEqual(previous, element) { return }
        if let previous = observerElement {
            AXObserverRemoveNotification(observer, previous, kAXSelectedTextChangedNotification as CFString)
        }
        observerElement = element
        AXObserverAddNotification(observer, element, kAXSelectedTextChangedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        // The 200 ms active-app poll also covers applications that reject AX notifications.
    }

    private func removeAXObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observerApp = nil
        observerElement = nil
        observerPID = nil
    }

    private func finderPermission(ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), ask)
    }

    private func finderSelection(_ source: Source) -> ActionContext {
        guard finderPermission(ask: false) == noErr else {
            return invalidate(source, "读取 Finder 文件需要“自动化”授权，请点击“允许读取 Finder”后再试。")
        }
        // Finder's selection is a list of object references. Ask for their URL property
        // in one read-only event rather than inferring paths from displayed filenames.
        let selection = property(Self.code("selp"), container: .null())
        let everyItem = NSAppleEventDescriptor.record()
        everyItem.setDescriptor(NSAppleEventDescriptor(typeCode: Self.code("cobj")), forKeyword: AEKeyword(keyAEDesiredClass))
        everyItem.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formAbsolutePosition)), forKeyword: AEKeyword(keyAEKeyForm))
        everyItem.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(kAEAll)), forKeyword: AEKeyword(keyAEKeyData))
        everyItem.setDescriptor(selection, forKeyword: AEKeyword(keyAEContainer))
        guard let items = everyItem.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else {
            return invalidate(source, "无法创建 Finder 文件读取请求。")
        }
        let urls = property(Self.code("pURL"), container: items)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
                                          targetDescriptor: NSAppleEventDescriptor(processIdentifier: source.pid),
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(urls, forKeyword: AEKeyword(keyDirectObject))
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 0.3)
            if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
                return invalidate(source, "Finder 未返回选中文件（\(error.int32Value)）。")
            }
            guard let result = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
                return invalidate(source, "Finder 未返回选中文件。")
            }
            let descriptors: [NSAppleEventDescriptor]
            if result.descriptorType == DescType(typeAEList) {
                guard result.numberOfItems <= fileLimit else { return invalidate(source, "一次最多读取 100 个文件，请缩小选择范围。") }
                descriptors = (0..<result.numberOfItems).compactMap { result.atIndex($0 + 1) }
            } else { descriptors = [result] }
            guard !descriptors.isEmpty else { return invalidate(source, "Finder 中尚未选中文件。") }
            var files: [URL] = []
            for descriptor in descriptors {
                guard let text = descriptor.stringValue, let url = URL(string: text), url.isFileURL,
                      url.host == nil || url.host == "" || url.host == "localhost",
                      url.path.hasPrefix("/") else {
                    return invalidate(source, "Finder 未提供可靠的本地文件地址。")
                }
                files.append(url)
            }
            return makeContext(source, selectedText: nil, files: files)
        } catch { return invalidate(source, "无法读取 Finder 选中文件，请检查授权并重试。") }
    }

    private func property(_ code: OSType, container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record()
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code), forKeyword: AEKeyword(keyAEKeyData))
        specifier.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return specifier.coerce(toDescriptorType: DescType(typeObjectSpecifier)) ?? .null()
    }

    private static func code(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }
    private static func source(_ app: NSRunningApplication) -> Source {
        Source(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "App")
    }
    private func makeContext(_ source: Source, selectedText: String?, files: [URL], reason: String? = nil) -> ActionContext {
        ActionContext(sourcePID: source.pid, sourceBundleID: source.bundleID, sourceName: source.name,
                      capturedAt: Date(), selectedText: selectedText, fileURLs: files, unavailableReason: reason)
    }
    private func empty(_ source: Source, _ reason: String) -> ActionContext {
        makeContext(source, selectedText: nil, files: [], reason: reason)
    }
    private func invalidate(_ source: Source, _ reason: String) -> ActionContext {
        cached = nil
        return empty(source, reason)
    }
    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }
}
