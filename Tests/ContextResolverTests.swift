import AppKit

private final class TestRunningApplication: NSRunningApplication, @unchecked Sendable {
    override var processIdentifier: pid_t { 12345 }
    override var bundleIdentifier: String? { "org.example.selection-tests" }
    override var localizedName: String? { "Selection Tests" }
    override var isTerminated: Bool { false }
}

private final class DeferredSelectionProvider: SelectionContextProviding {
    var shouldObserve: ((String) -> Bool)?
    var starts = 0
    var stops = 0
    var locked: [(ActionContext) -> Void] = []
    var current: [(ActionContext) -> Void] = []
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func lockSelection(for app: NSRunningApplication, completion: @escaping (ActionContext) -> Void) { locked.append(completion) }
    func currentSelection(for app: NSRunningApplication, completion: @escaping (ActionContext) -> Void) { current.append(completion) }
    func requestFinderAccess(completion: @escaping (Bool) -> Void) { completion(true) }
}

@main
struct ContextResolverTestRunner {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() {
        expect(Thread.isMainThread, "Runner uses the same ownership as event callbacks")
        let app = TestRunningApplication()
        let sourceID = app.bundleIdentifier ?? ""
        func context(_ text: String = "Selected", pid: Int32? = nil) -> ActionContext {
            ActionContext(sourcePID: pid ?? app.processIdentifier, sourceBundleID: sourceID,
                          sourceName: "Test", capturedAt: Date(), selectedText: text)
        }
        let provider = DeferredSelectionProvider()
        let center = NotificationCenter()
        var allowed = true
        let resolver = ContextResolver(provider: provider, shouldObserve: { _ in allowed }, notificationCenter: center)
        expect(resolver.beginGesture(for: app) == nil, "Stopped resolver does not read")
        resolver.start(); resolver.start()
        expect(provider.starts == 1, "Starting twice is idempotent")
        let first = resolver.beginGesture(for: app)!
        var delivered: [String?] = []
        resolver.resolve(for: app, gestureID: first) { delivered.append($0.selectedText) }
        resolver.resolve(for: app, gestureID: first) { delivered.append($0.selectedText) }
        expect(provider.locked.count == 1 && provider.current.isEmpty, "Menus subscribe to the single mouse-down read")
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: app])
        resolver.endGesture()
        provider.locked[0](context())
        expect(delivered == ["Selected", "Selected"], "Release preserves already-registered list-menu subscribers")
        var ended: ActionContext?
        resolver.resolve(for: app, gestureID: first) { ended = $0 }
        expect(ended?.selectedText == nil, "Ended gesture does not retain a readable historical selection")
        let second = resolver.beginGesture(for: app)!
        provider.locked[1](context("Ready"))
        var ready: String?
        resolver.resolve(for: app, gestureID: second) { ready = $0.selectedText }
        expect(ready == "Ready" && provider.locked.count == 2, "Completed current gesture reuses its one locked result")
        resolver.endGesture()
        let third = resolver.beginGesture(for: app)!
        var cancelled = false
        resolver.resolve(for: app, gestureID: third) { _ in cancelled = true }
        resolver.cancel()
        provider.locked[2](context("Stale"))
        expect(!cancelled, "Cancelled gesture cannot deliver a late selection")
        let fourth = resolver.beginGesture(for: app)!
        resolver.resolve(for: app, gestureID: fourth) { _ in cancelled = true }
        let fifth = resolver.beginGesture(for: app)!
        provider.locked[3](context("Previous"))
        expect(!cancelled, "New gesture invalidates the previous gesture's subscribers")
        var mismatched: ActionContext?
        resolver.resolve(for: app, gestureID: fifth) { mismatched = $0 }
        provider.locked[4](context("Wrong source", pid: app.processIdentifier + 1))
        expect(mismatched?.selectedText == nil && mismatched?.unavailableReason != nil, "Wrong source is converted to an empty context")
        resolver.endGesture()
        var preview: String?
        resolver.resolve(for: app, gestureID: nil) { preview = $0.selectedText }
        expect(provider.current.count == 1, "Manual menu requests a fresh current selection")
        provider.current[0](context("Current"))
        expect(preview == "Current", "Fresh read reaches the requesting menu")
        resolver.resolve(for: app, gestureID: nil) { _ in cancelled = true }
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        provider.current[1](context("Previous app"))
        expect(!cancelled, "Source activation change invalidates outstanding manual reads")
        let sixth = resolver.beginGesture(for: app)!
        var firstSubscriber = false
        var secondSubscriber = false
        resolver.resolve(for: app, gestureID: sixth) { _ in firstSubscriber = true; resolver.cancel() }
        resolver.resolve(for: app, gestureID: sixth) { _ in secondSubscriber = true }
        provider.locked[5](context("Reentrant"))
        expect(firstSubscriber && !secondSubscriber, "Cancellation inside one callback protects later subscribers")
        let seventh = resolver.beginGesture(for: app)!
        resolver.resolve(for: app, gestureID: seventh) { _ in cancelled = true }
        resolver.stop()
        provider.locked[6](context("Stopped"))
        expect(!cancelled && provider.stops == 1, "Stop prevents late callbacks and stops underlying observation")
        resolver.start()
        let noMenu = resolver.beginGesture(for: app)!
        resolver.endGesture()
        provider.locked[7](context("Ordinary click"))
        var endedWithoutMenu: ActionContext?
        resolver.resolve(for: app, gestureID: noMenu) { endedWithoutMenu = $0 }
        expect(endedWithoutMenu?.selectedText == nil, "Ordinary clicks retain no text when no menu subscribed")
        allowed = false
        expect(resolver.beginGesture(for: app) == nil, "Configuration can disable future selection reads")
        var disabled: ActionContext?
        resolver.resolve(for: app, gestureID: nil) { disabled = $0 }
        expect(disabled?.selectedText == nil && provider.current.count == 2, "Disabled actions do not reach the selection provider")
        var finderPermission = false
        resolver.requestFinderAccess { finderPermission = $0 }
        expect(finderPermission, "Explicit Finder permission request is forwarded")
        resolver.stop()
        print("ContextResolverTests: \(assertions) assertions passed")
    }
}
