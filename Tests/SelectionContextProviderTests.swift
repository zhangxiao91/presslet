import AppKit

private final class SelectionTestApplication: NSRunningApplication, @unchecked Sendable {
    var testPID: pid_t = 12345
    var testBundleID = "org.example.fresh-selection"
    var testTerminated = false
    override var processIdentifier: pid_t { testPID }
    override var bundleIdentifier: String? { testBundleID }
    override var localizedName: String? { "Selection Test" }
    override var isTerminated: Bool { testTerminated }
}

private final class SelectionReaderState {
    struct Selection {
        var text: String?
        var files: [URL] = []
        var reason: String?
    }
    final class Gate {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
    }
    private let lock = NSLock()
    private var selection = Selection(text: "A")
    private var nextGate: Gate?
    private var reads = 0
    private var workerOnly = true
    private var gateTimedOut = false

    func set(_ value: Selection) {
        lock.lock(); selection = value; lock.unlock()
    }
    func blockNextRead() -> Gate {
        let gate = Gate()
        lock.lock(); nextGate = gate; lock.unlock()
        return gate
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }; return reads
    }
    var allReadsOnWorker: Bool {
        lock.lock(); defer { lock.unlock() }; return workerOnly
    }
    var completedWithoutTimeout: Bool {
        lock.lock(); defer { lock.unlock() }; return !gateTimedOut
    }
    func read(_ source: SelectionContextProvider.Source) -> ActionContext {
        lock.lock()
        reads += 1
        workerOnly = workerOnly && !Thread.isMainThread
        let value = selection
        let gate = nextGate
        nextGate = nil
        lock.unlock()
        if let gate {
            gate.entered.signal()
            if gate.release.wait(timeout: .now() + 3) != .success {
                lock.lock(); gateTimedOut = true; lock.unlock()
            }
        }
        return ActionContext(sourcePID: source.pid, sourceBundleID: source.bundleID,
                             sourceName: source.name, capturedAt: Date(), selectedText: value.text,
                             fileURLs: value.files, unavailableReason: value.reason)
    }
}

private final class SelectionFixture {
    let app = SelectionTestApplication()
    let center = NotificationCenter()
    let reader = SelectionReaderState()
    var frontPID: pid_t? = 12345
    var enabled = true
    lazy var provider = SelectionContextProvider(frontmostPID: { [unowned self] in self.frontPID },
                                                 notificationCenter: center,
                                                 selectionReader: { [reader] in reader.read($0) })
    init() {
        provider.shouldObserve = { [unowned self] _ in self.enabled }
    }
    func activate(_ pid: pid_t) {
        frontPID = pid
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }
}

@main
struct SelectionContextProviderTestRunner {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func wait(_ message: String, until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), deadline.timeIntervalSinceNow > 0 {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
        expect(predicate(), message)
    }
    private static func entered(_ gate: SelectionReaderState.Gate) {
        expect(gate.entered.wait(timeout: .now() + 3) == .success, "Reader reaches its controlled blocking point")
    }
    private static func capture(_ fixture: SelectionFixture, current: Bool = false) -> ActionContext {
        var result: ActionContext?
        let completion: (ActionContext) -> Void = {
            expect(Thread.isMainThread, "Read completion runs on the main thread")
            result = $0
        }
        if current { fixture.provider.currentSelection(for: fixture.app, completion: completion) }
        else { fixture.provider.lockSelection(for: fixture.app, completion: completion) }
        wait("Read completes within the deadline") { result != nil }
        return result!
    }
    static func expectEmpty(_ context: ActionContext, _ message: String) {
        expect(context.selectedText == nil && context.fileURLs.isEmpty && context.unavailableReason != nil, message)
    }

    static func main() {
        expect(Thread.isMainThread, "Tests own lifecycle state on the main thread")
        freshSelectionAndIdle()
        lifecycleInvalidation()
        configurationAndSourceGuards()
        resolverKeepsOnlyCurrentGesture()
        print("SelectionContextProviderTests: \(assertions) assertions passed")
    }

    static func freshSelectionAndIdle() {
        let fixture = SelectionFixture()
        expectEmpty(capture(fixture), "A stopped provider returns no selection")
        expect(fixture.reader.count == 0, "Stopped reads never query the reader")
        fixture.provider.start(); fixture.provider.start()
        expect(capture(fixture).selectedText == "A", "First gesture reads selection A")
        fixture.reader.set(.init(text: "B"))
        expect(capture(fixture).selectedText == "B", "An immediate second gesture reads B rather than recent A")
        expect(fixture.reader.count == 2, "Both adjacent gestures perform an independent read")
        fixture.reader.set(.init(text: nil, reason: "No selected text"))
        expectEmpty(capture(fixture), "A collapsed selection does not restore B")
        fixture.reader.set(.init(text: nil, reason: "AX server unavailable"))
        expectEmpty(capture(fixture), "A failed read does not restore the last successful selection")
        fixture.reader.set(.init(text: "Preview"))
        expect(capture(fixture, current: true).selectedText == "Preview", "An explicit preview also reads current content")
        fixture.reader.set(.init(text: "New preview"))
        expect(capture(fixture, current: true).selectedText == "New preview", "Adjacent previews do not reuse content")

        fixture.app.testBundleID = "com.apple.finder"
        let first = URL(fileURLWithPath: "/tmp/selection-A.txt")
        let second = URL(fileURLWithPath: "/tmp/selection-B.txt")
        fixture.reader.set(.init(text: nil, files: [first]))
        expect(capture(fixture).fileURLs == [first], "Finder reads current file A")
        fixture.reader.set(.init(text: nil, files: [second]))
        let files = capture(fixture)
        expect(files.fileURLs == [second], "An immediate Finder gesture reads file B rather than file A")
        expect(files.sourceBundleID == "com.apple.finder", "The current source metadata accompanies file content")
        fixture.reader.set(.init(text: nil, reason: "Finder selection empty"))
        expectEmpty(capture(fixture), "An empty Finder selection cannot restore a previous file")

        let count = fixture.reader.count
        var idleFinished = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { idleFinished = true }
        wait("Idle observation interval completes") { idleFinished }
        expect(fixture.reader.count == count, "An idle running provider performs no periodic selection reads")
        expect(fixture.reader.allReadsOnWorker, "All actual reads run away from the main thread")
        expect(fixture.reader.completedWithoutTimeout, "No worker gate timed out")
        fixture.provider.stop()
    }

    static func lifecycleInvalidation() {
        let fixture = SelectionFixture()
        fixture.provider.start()
        var delayed: ActionContext?
        let stopped = fixture.reader.blockNextRead()
        fixture.provider.lockSelection(for: fixture.app) { delayed = $0 }
        entered(stopped)
        fixture.provider.stop(); fixture.provider.start()
        stopped.release.signal()
        wait("A read pending across stop and restart completes") { delayed != nil }
        expectEmpty(delayed!, "Stop and restart reject the old lifecycle's selection")
        fixture.reader.set(.init(text: "After restart"))
        expect(capture(fixture).selectedText == "After restart", "New lifecycle reads fresh content")

        delayed = nil
        let switched = fixture.reader.blockNextRead()
        fixture.provider.lockSelection(for: fixture.app) { delayed = $0 }
        entered(switched)
        fixture.activate(23456); fixture.activate(fixture.app.processIdentifier)
        switched.release.signal()
        wait("A read pending across an app round trip completes") { delayed != nil }
        expectEmpty(delayed!, "Returning to the same PID cannot resurrect a pre-switch read")

        delayed = nil
        let stoppedOnly = fixture.reader.blockNextRead()
        fixture.provider.currentSelection(for: fixture.app) { delayed = $0 }
        entered(stoppedOnly)
        fixture.provider.stop()
        stoppedOnly.release.signal()
        wait("Stopping while a read is outstanding completes safely") { delayed != nil }
        expectEmpty(delayed!, "A stopped provider does not deliver outstanding selected content")
        expect(fixture.reader.completedWithoutTimeout, "Lifecycle gates all released explicitly")
    }

    static func configurationAndSourceGuards() {
        let fixture = SelectionFixture()
        fixture.provider.start()
        fixture.enabled = false
        expectEmpty(capture(fixture), "Disabled actions do not expose a selection")
        fixture.enabled = true
        fixture.app.testTerminated = true
        expectEmpty(capture(fixture), "Terminated applications do not expose a selection")
        fixture.app.testTerminated = false
        fixture.frontPID = 23456
        expectEmpty(capture(fixture), "A background application cannot be read")
        fixture.frontPID = fixture.app.processIdentifier
        fixture.app.testPID = ProcessInfo.processInfo.processIdentifier
        fixture.frontPID = fixture.app.processIdentifier
        expectEmpty(capture(fixture), "Presslet cannot capture itself")
        expect(fixture.reader.count == 0, "All failed preconditions avoid querying the worker reader")
        fixture.app.testPID = 12345
        fixture.frontPID = 12345

        for terminate in [false, true] {
            var result: ActionContext?
            let gate = fixture.reader.blockNextRead()
            fixture.provider.lockSelection(for: fixture.app) { result = $0 }
            entered(gate)
            if terminate { fixture.app.testTerminated = true }
            else { fixture.enabled = false }
            gate.release.signal()
            wait("A configuration change during reading completes safely") { result != nil }
            expectEmpty(result!, terminate ? "Termination during a read rejects its content" : "Disabling an action during a read rejects its content")
            fixture.app.testTerminated = false
            fixture.enabled = true
        }
        expect(fixture.reader.completedWithoutTimeout, "Configuration gates all released explicitly")
        fixture.provider.stop()
    }

    static func resolverKeepsOnlyCurrentGesture() {
        let fixture = SelectionFixture()
        let resolver = ContextResolver(provider: fixture.provider, shouldObserve: { _ in fixture.enabled }, notificationCenter: fixture.center)
        resolver.start()
        let delayedA = fixture.reader.blockNextRead()
        let first = resolver.beginGesture(for: fixture.app)!
        var staleWasDelivered = false
        resolver.resolve(for: fixture.app, gestureID: first) { _ in staleWasDelivered = true }
        entered(delayedA)
        fixture.reader.set(.init(text: "B"))
        let second = resolver.beginGesture(for: fixture.app)!
        var delivered: [String?] = []
        resolver.resolve(for: fixture.app, gestureID: second) { delivered.append($0.selectedText) }
        resolver.resolve(for: fixture.app, gestureID: second) { delivered.append($0.selectedText) }
        delayedA.release.signal()
        wait("New gesture subscribers receive fresh B") { delivered.count == 2 }
        expect(!staleWasDelivered, "A late A read cannot notify the replaced gesture")
        expect(delivered == ["B", "B"], "All subscribers of the new gesture receive B")
        expect(fixture.reader.count == 2, "Two gestures read once each despite multiple menu subscribers")

        fixture.reader.set(.init(text: "Changed while menu is open"))
        var locked: ActionContext?
        resolver.resolve(for: fixture.app, gestureID: second) { locked = $0 }
        expect(locked?.selectedText == "B", "Menu changes do not replace the current gesture's locked result")
        expect(fixture.reader.count == 2, "An action resolution does not reread the target App")
        resolver.endGesture()
        var ended: ActionContext?
        resolver.resolve(for: fixture.app, gestureID: second) { ended = $0 }
        expectEmpty(ended!, "An ended gesture cannot expose historical B")
        fixture.reader.set(.init(text: "C"))
        let third = resolver.beginGesture(for: fixture.app)!
        var fresh: ActionContext?
        resolver.resolve(for: fixture.app, gestureID: third) { fresh = $0 }
        wait("The next gesture gets another fresh read") { fresh != nil }
        expect(fresh?.selectedText == "C" && fixture.reader.count == 3, "A following gesture reads C rather than retaining B")
        expect(fixture.reader.completedWithoutTimeout && fixture.reader.allReadsOnWorker, "The integrated resolver test uses controlled worker reads")
        resolver.stop()
    }
}
