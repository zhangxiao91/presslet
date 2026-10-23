import AppKit

/// This boundary allows delayed AX results to be exercised without reading other apps.
protocol SelectionContextProviding: AnyObject {
    var shouldObserve: ((String) -> Bool)? { get set }
    func start()
    func stop()
    func lockSelection(for app: NSRunningApplication, completion: @escaping (ActionContext) -> Void)
    func currentSelection(for app: NSRunningApplication, completion: @escaping (ActionContext) -> Void)
    func requestFinderAccess(completion: @escaping (Bool) -> Void)
}

extension SelectionContextProvider: SelectionContextProviding {}

/// Main-thread ownership of gesture selection and its asynchronous subscribers.
/// The resolver forgets content when the gesture ends; already-subscribed menus
/// may finish one outstanding read after release, including the persistent list menu.
final class ContextResolver {
    private struct Source {
        let pid: pid_t
        let bundleID: String
        let name: String
        init(_ app: NSRunningApplication) {
            pid = app.processIdentifier
            bundleID = app.bundleIdentifier ?? ""
            name = app.localizedName ?? "App"
        }
        func matches(_ app: NSRunningApplication) -> Bool {
            pid == app.processIdentifier && bundleID == (app.bundleIdentifier ?? "")
        }
        func matches(_ context: ActionContext) -> Bool {
            pid == context.sourcePID && bundleID == context.sourceBundleID
        }
    }
    private struct Gesture {
        let id: UUID
        let source: Source
        var ended = false
        var result: ActionContext?
        var subscribers: [(ActionContext) -> Void] = []
    }
    private struct Read {
        let source: Source
        let completion: (ActionContext) -> Void
    }

    private let provider: SelectionContextProviding
    private let shouldObserve: (String) -> Bool
    private let notificationCenter: NotificationCenter
    private var activationToken: NSObjectProtocol?
    private var gesture: Gesture?
    private var reads: [UUID: Read] = [:]
    private var generation: UInt64 = 0
    private var running = false

    init(provider: SelectionContextProviding = SelectionContextProvider(),
         shouldObserve: @escaping (String) -> Bool,
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.provider = provider
        self.shouldObserve = shouldObserve
        self.notificationCenter = notificationCenter
        provider.shouldObserve = shouldObserve
    }

    deinit {
        if let activationToken { notificationCenter.removeObserver(activationToken) }
    }

    func start() {
        requireMain()
        guard !running else { return }
        running = true
        activationToken = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            if self.gesture.map({ $0.source.pid != pid }) == true
                || self.reads.values.contains(where: { $0.source.pid != pid }) {
                self.cancel()
            }
        }
        provider.start()
    }

    func stop() {
        requireMain()
        cancel()
        running = false
        if let activationToken { notificationCenter.removeObserver(activationToken) }
        activationToken = nil
        provider.stop()
    }

    func requestFinderAccess(completion: @escaping (Bool) -> Void) {
        requireMain()
        provider.requestFinderAccess { allowed in Self.onMain { completion(allowed) } }
    }

    @discardableResult
    func beginGesture(for app: NSRunningApplication?) -> UUID? {
        requireMain()
        cancel()
        guard running, let app, !app.isTerminated, shouldObserve(app.bundleIdentifier ?? "") else { return nil }
        let id = UUID()
        let source = Source(app)
        let version = generation
        gesture = Gesture(id: id, source: source)
        provider.lockSelection(for: app) { [weak self] context in
            Self.onMain { self?.finishGesture(id: id, generation: version, context: context) }
        }
        return id
    }

    func endGesture() {
        requireMain()
        guard var current = gesture else { return }
        current.ended = true
        if current.result != nil || current.subscribers.isEmpty {
            gesture = nil
        } else {
            gesture = current
        }
    }

    func cancel() {
        requireMain()
        generation &+= 1
        gesture = nil
        reads.removeAll()
    }

    func resolve(for app: NSRunningApplication?, gestureID: UUID?, completion: @escaping (ActionContext) -> Void) {
        requireMain()
        guard running, let app, !app.isTerminated, shouldObserve(app.bundleIdentifier ?? "") else {
            completion(empty(app.map(Source.init), reason: "这个 App 没有启用需要选中内容的动作。"))
            return
        }
        if let id = gestureID {
            guard var current = gesture, current.id == id, current.source.matches(app) else {
                completion(empty(Source(app), reason: "此次重按已结束，请重新打开菜单。"))
                return
            }
            if let result = current.result { completion(result) }
            else {
                current.subscribers.append(completion)
                gesture = current
            }
            return
        }
        let id = UUID()
        let version = generation
        let source = Source(app)
        reads[id] = Read(source: source, completion: completion)
        provider.currentSelection(for: app) { [weak self] context in
            Self.onMain {
                guard let self, self.generation == version,
                      let read = self.reads.removeValue(forKey: id) else { return }
                let valid = read.source.matches(context)
                    ? context : self.empty(read.source, reason: "选中内容的来源发生变化，请重新打开菜单。")
                read.completion(valid)
            }
        }
    }

    private func finishGesture(id: UUID, generation version: UInt64, context: ActionContext) {
        requireMain()
        guard generation == version, var current = gesture, current.id == id else { return }
        let result = current.source.matches(context)
            ? context : empty(current.source, reason: "选中内容的来源发生变化，请重新打开菜单。")
        let subscribers = current.subscribers
        current.subscribers.removeAll()
        current.result = result
        gesture = current.ended ? nil : current
        // A subscriber may dismiss the menu, cancel, stop, or start another gesture.
        // Re-check the generation before each callback to avoid notifying stale menus.
        for completion in subscribers {
            guard generation == version else { break }
            completion(result)
        }
    }

    private func empty(_ source: Source?, reason: String) -> ActionContext {
        ActionContext(sourcePID: source?.pid ?? 0, sourceBundleID: source?.bundleID ?? "",
                      sourceName: source?.name ?? "App", capturedAt: Date(), unavailableReason: reason)
    }
    private func requireMain() { precondition(Thread.isMainThread, "ContextResolver must be used on the main thread") }
    private static func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }
}
