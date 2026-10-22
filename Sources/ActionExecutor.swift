import AppKit
import ApplicationServices

private struct ActionExecutionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class BoundedActionOutput {
    private let lock = NSLock()
    private var bytes = Data()
    private let limit = 16_384

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - bytes.count)
        bytes.append(data.prefix(remaining))
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class ActionExecutor {
    private struct Pending {
        let completion: (Result<String, Error>) -> Void
        var process: Process?
    }

    // All mutable execution state is confined to the main queue.
    private var pending: [UUID: Pending] = [:]

    func execute(_ action: MenuAction, target: NSRunningApplication?, completion: @escaping (Result<String, Error>) -> Void) {
        onMain { [weak self] in
            guard let self = self else { return }
            guard action.isEnabled else {
                completion(.failure(ActionExecutionError(message: "这个动作尚未启用。")))
                return
            }
            let id = UUID()
            self.pending[id] = Pending(completion: completion, process: nil)
            switch action.kind {
            case .shortcut: self.executeShortcut(action, target: target, id: id)
            case .open: self.executeOpen(action, id: id)
            case .workflow: self.executeWorkflow(action, id: id)
            }
        }
    }

    func cancelAll() {
        onMain { [weak self] in
            guard let self = self else { return }
            let cancelled = self.pending
            self.pending.removeAll()
            for item in cancelled.values {
                if let process = item.process, process.isRunning { process.terminate() }
                item.completion(.failure(ActionExecutionError(message: "动作已取消。")))
            }
        }
    }

    private func executeShortcut(_ action: MenuAction, target: NSRunningApplication?, id: UUID) {
        guard AXIsProcessTrusted() else {
            fail(id, "请先在系统设置的“辅助功能”中允许本 App 控制输入。")
            return
        }
        guard let components = action.shortcutComponents,
              let key = components.last, let keyCode = Self.keyCodes[key] else {
            fail(id, "快捷键格式不正确，请重新选择按键。")
            return
        }
        guard let target = target, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            fail(id, "原来的 App 已关闭或无法找到，未发送快捷键。")
            return
        }
        let modifiers = components.dropLast().compactMap { Self.modifiers[$0] }
        guard modifiers.count == components.count - 1,
              let events = Self.keyboardEvents(key: keyCode, modifiers: modifiers) else {
            fail(id, "无法创建这个快捷键，未发送输入。")
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
            sendShortcut(events, target: target, id: id)
        } else {
            guard target.activate(options: []) else {
                fail(id, "无法回到原来的 App，未发送快捷键。")
                return
            }
            waitForTarget(target, events: events, id: id, attempts: 20)
        }
    }

    private func waitForTarget(_ target: NSRunningApplication, events: [CGEvent], id: UUID, attempts: Int) {
        guard pending[id] != nil else { return }
        guard !target.isTerminated else {
            fail(id, "原来的 App 已关闭，未发送快捷键。")
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
            sendShortcut(events, target: target, id: id)
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                self?.waitForTarget(target, events: events, id: id, attempts: attempts - 1)
            }
        } else {
            fail(id, "原来的 App 没有回到前台，未发送快捷键。")
        }
    }

    private func sendShortcut(_ events: [CGEvent], target: NSRunningApplication, id: UUID) {
        guard pending[id] != nil else { return }
        guard AXIsProcessTrusted(), !target.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            fail(id, "输入权限或前台 App 已改变，未发送快捷键。")
            return
        }
        // Address every event to the captured PID, including modifier releases.
        // No asynchronous work can interrupt this complete key-down/key-up sequence.
        for event in events { event.postToPid(target.processIdentifier) }
        finish(id, .success("已向原来的 App 发送快捷键。"))
    }

    private static func keyboardEvents(key: CGKeyCode, modifiers: [(CGKeyCode, CGEventFlags)]) -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        var events: [CGEvent] = []
        var flags: CGEventFlags = []
        func append(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) -> Bool {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return false }
            event.flags = flags
            events.append(event)
            return true
        }
        for (code, flag) in modifiers {
            flags.insert(flag)
            guard append(code, down: true, flags: flags) else { return nil }
        }
        guard append(key, down: true, flags: flags), append(key, down: false, flags: flags) else { return nil }
        for (code, flag) in modifiers.reversed() {
            flags.remove(flag)
            guard append(code, down: false, flags: flags) else { return nil }
        }
        return events
    }

    private func executeOpen(_ action: MenuAction, id: UUID) {
        let value = action.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let callback: (NSRunningApplication?, Error?) -> Void = { [weak self] application, error in
            self?.onMain { [weak self] in
                if let error = error {
                    self?.fail(id, "无法打开：\(error.localizedDescription)")
                } else if application != nil {
                    self?.finish(id, .success("已交给系统打开。"))
                } else {
                    self?.fail(id, "系统未确认打开请求，请检查地址或应用是否可用。")
                }
            }
        }
        if let url = URL(string: value), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty {
            NSWorkspace.shared.open(url, configuration: configuration, completionHandler: callback)
            return
        }
        let applicationURL: URL?
        if value.hasPrefix("/"), value.lowercased().hasSuffix(".app") {
            let url = URL(fileURLWithPath: value).standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
               Bundle(url: url)?.bundleIdentifier != nil {
                applicationURL = url
            } else {
                applicationURL = nil
            }
        } else if !value.isEmpty, !value.contains("/"), !value.contains(":") {
            applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value)
        } else {
            applicationURL = nil
        }
        guard let url = applicationURL else {
            fail(id, "找不到这个应用。请填写应用标识、完整 .app 路径或 http/https 网址。")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: callback)
    }

    private func executeWorkflow(_ action: MenuAction, id: UUID) {
        let name = action.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\0") else {
            fail(id, "请填写要运行的快捷指令名称。")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/shortcuts") else {
            fail(id, "当前系统无法运行快捷指令。")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        let output = BoundedActionOutput()
        let drained = DispatchGroup()
        process.standardError = stderr
        drained.enter()
        process.terminationHandler = { [weak self] terminated in
            drained.wait()
            let detail = output.text()
            self?.onMain { [weak self] in
                if terminated.terminationReason == .exit && terminated.terminationStatus == 0 {
                    self?.finish(id, .success("快捷指令已完成。"))
                } else {
                    self?.fail(id, detail.isEmpty ? "快捷指令未完成，请在“快捷指令”App 中检查名称和运行权限。" : "快捷指令未完成：\(detail)")
                }
            }
        }
        pending[id]?.process = process
        do {
            try process.run()
            try? stderr.fileHandleForWriting.close()
            DispatchQueue.global(qos: .utility).async {
                defer {
                    try? stderr.fileHandleForReading.close()
                    drained.leave()
                }
                do {
                    while let chunk = try stderr.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                        output.append(chunk)
                    }
                } catch {
                    // The process status remains authoritative if the pipe closes early.
                }
            }
        } catch {
            try? stderr.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close()
            drained.leave()
            fail(id, "无法启动快捷指令：\(error.localizedDescription)")
        }
    }

    private func finish(_ id: UUID, _ result: Result<String, Error>) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.completion(result)
    }

    private func fail(_ id: UUID, _ message: String) {
        finish(id, .failure(ActionExecutionError(message: message)))
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    private static let modifiers: [String: (CGKeyCode, CGEventFlags)] = [
        "cmd": (55, .maskCommand), "ctrl": (59, .maskControl),
        "option": (58, .maskAlternate), "shift": (56, .maskShift)
    ]

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "home": 115, "pageup": 116, "forwarddelete": 117, "end": 119, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
        "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90
    ]
}
