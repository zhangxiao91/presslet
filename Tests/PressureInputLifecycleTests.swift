import AppKit
import ApplicationServices

@main
struct PressureInputLifecycleTestRunner {
    static var assertions = 0

    final class FakeWorker: PressureTapStopping {
        var stopCount = 0
        var automaticallyAcknowledgesStop = true
        private var stopAcknowledgements: [() -> Void] = []
        var pendingStopAcknowledgements: Int { stopAcknowledgements.count }

        func requestStop() { stopCount += 1 }

        func requestStop(afterStopped completion: @escaping () -> Void) {
            requestStop()
            if automaticallyAcknowledgesStop {
                DispatchQueue.main.async(execute: completion)
            } else {
                stopAcknowledgements.append(completion)
            }
        }

        func acknowledgeStop() {
            let completions = stopAcknowledgements
            stopAcknowledgements.removeAll()
            for completion in completions { DispatchQueue.main.async(execute: completion) }
        }
    }

    final class Recorder {
        var restarts = 0
        var mouse: [(type: CGEventType, point: CGPoint)] = []
        var cancellations: [String] = []
    }

    struct Harness {
        let worker = FakeWorker()
        let recorder = Recorder()
        let input: PressureInputManager

        init() {
            let record = recorder
            input = PressureInputManager(testingWorker: worker, policy: Self.policy(),
                restart: { record.restarts += 1 })
            input.onTapMouse = { type, event in record.mouse.append((type, event.location)) }
            input.onCancelGesture = { record.cancellations.append($0) }
        }

        static func policy() -> PressureInputPolicy {
            PressureInputPolicy(ownPID: 100, frontmostPID: 200,
                                interceptedPIDs: [200], menuPIDs: [200])
        }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        assertions += 1
        guard condition() else {
            fputs("FAIL line \(line): \(message)\n", stderr)
            exit(1)
        }
    }

    static func mouse(_ type: CGEventType, _ point: CGPoint, pid: Int32 = 200) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)!
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        return event
    }

    // All input is created in memory. Running the main loop only delivers the
    // manager's queued callbacks; this test never installs a tap or posts input.
    static func pump(until condition: () -> Bool = { false }, timeout: TimeInterval = 0.06) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
        } while !condition() && Date() < deadline
    }

    static func begin(_ h: Harness, down: CGPoint = CGPoint(x: 20, y: 30),
                      locked: CGPoint = CGPoint(x: 25, y: 32)) {
        expect(!h.input.testingReceive(type: .leftMouseDown, event: mouse(.leftMouseDown, down)),
               "The underlying application's physical down is passed through")
        expect(!h.input.testingReceive(type: .leftMouseDragged, event: mouse(.leftMouseDragged, locked)),
               "Movement before menu takeover is passed through")
        expect(h.input.testingTakeOver(pid: 200), "A qualified press captures its original receiver")
        expect(h.input.isIsolatingPress, "The captured press stays owned until physical release")
    }

    static func testIdleStop() {
        let h = Harness()
        var completed = 0
        h.input.stop(afterRelease: { completed += 1 })
        expect(h.worker.stopCount == 1, "Idle stop closes the tap immediately")
        expect(completed == 0, "Idle stop completion is always asynchronous")
        pump(until: { completed == 1 })
        expect(completed == 1, "Idle stop delivers completion")
        pump()
        expect(completed == 1 && h.worker.stopCount == 1, "Idle completion and teardown happen once")
    }

    static func testActiveStopWaitsForPhysicalUp() {
        let h = Harness()
        begin(h)
        var completed = 0
        h.input.stop(afterRelease: { completed += 1 })
        expect(h.worker.stopCount == 0 && completed == 0, "Stopping an owned press keeps its tap alive")
        pump()
        expect(h.worker.stopCount == 0 && completed == 0, "Queue drainage cannot finish a still-held press")
        expect(h.input.testingReceive(type: .leftMouseDragged,
                                     event: mouse(.leftMouseDragged, CGPoint(x: 200, y: 300))),
               "Drags remain suppressed while stopping")
        let up = mouse(.leftMouseUp, CGPoint(x: 220, y: 330), pid: 300)
        let returned = h.input.testingRoutedEvent(type: .leftMouseUp, event: up)
        expect(returned === up, "Stopping returns the same physical release through the native callback")
        expect(up.location == CGPoint(x: 25, y: 32), "Native release uses the last passed position")
        expect(up.getIntegerValueField(.eventTargetUnixProcessID) == 300,
               "Stopping preserves the physical release's native target")
        expect(h.input.stats.blockedDragEvents == 1 && h.input.stats.pairedMouseUps == 1,
               "Stopping records one suppressed drag and one paired native release")
        expect(h.worker.stopCount == 0 && completed == 0, "Physical release schedules rather than inlines teardown")
        pump(until: { completed == 1 })
        expect(h.worker.stopCount == 1 && completed == 1, "Physical release permits one teardown and completion")
        expect(!h.input.isIsolatingPress, "Release ends isolation")
        expect(!h.input.testingReceive(type: .leftMouseUp,
                                      event: mouse(.leftMouseUp, CGPoint(x: 240, y: 350))),
               "An extra release is passed through without another pairing")
        pump()
        expect(h.input.stats.pairedMouseUps == 1 && completed == 1, "Duplicate up does not repeat completion or pairing count")
    }

    static func testPolicyChangesDoNotLeakDragging() {
        let changes: [(String, (inout PressureInputPolicy) -> Void)] = [
            ("pause", { $0.paused = true }),
            ("disable input", { $0.enabled = false }),
            ("disable gestures", { $0.gestureEnabled = false }),
            ("cancel menu", { $0.menuVisible = false; $0.autoMenu = false }),
            ("switch source app", { $0.frontmostPID = 300; $0.menuPIDs = []; $0.interceptedPIDs = [] })
        ]
        for (name, change) in changes {
            let h = Harness()
            begin(h)
            var policy = Harness.policy()
            policy.menuVisible = true
            h.input.updatePolicy(policy)
            change(&policy)
            h.input.updatePolicy(policy)
            expect(h.input.testingReceive(type: .leftMouseDragged,
                                         event: mouse(.leftMouseDragged, CGPoint(x: 300, y: 400))),
                   "\(name) cannot release an already captured drag")
            expect(h.input.isIsolatingPress, "\(name) keeps ownership until physical up")
            let up = mouse(.leftMouseUp, CGPoint(x: 310, y: 410), pid: 300)
            expect(h.input.testingRoutedEvent(type: .leftMouseUp, event: up) === up,
                   "\(name) leaves the single physical release in the native callback")
            expect(up.location == CGPoint(x: 25, y: 32) && !h.input.isIsolatingPress,
                   "\(name) preserves the safe position and ends isolation on physical release")
            expect(up.getIntegerValueField(.eventTargetUnixProcessID) == 300,
                   "\(name) preserves native release targeting instead of reposting to another PID")
            expect(h.input.stats.blockedDragEvents == 1 && h.input.stats.pairedMouseUps == 1,
                   "\(name) records one suppressed drag and one paired native release")
            let extra = mouse(.leftMouseUp, CGPoint(x: 320, y: 420), pid: 300)
            expect(h.input.testingRoutedEvent(type: .leftMouseUp, event: extra) === extra &&
                   h.input.stats.pairedMouseUps == 1, "\(name) cannot pair a duplicate release")
            h.input.stop()
            pump()
            expect(h.worker.stopCount == 1, "\(name) permits idle teardown after release")
        }

        let h = Harness()
        begin(h)
        _ = h.input.testingReceive(type: .tapDisabledByTimeout,
                                  event: mouse(.leftMouseDragged, CGPoint(x: 100, y: 100)))
        pump(until: { !h.recorder.cancellations.isEmpty })
        expect(!h.recorder.cancellations.isEmpty, "Tap interruption cancels menu delivery")
        expect(h.input.testingReceive(type: .leftMouseDragged,
                                     event: mouse(.leftMouseDragged, CGPoint(x: 400, y: 500))),
               "Cancelling the menu after interruption does not leak drag")
        let interruptedUp = mouse(.leftMouseUp, CGPoint(x: 410, y: 510))
        expect(h.input.testingRoutedEvent(type: .leftMouseUp, event: interruptedUp) === interruptedUp,
               "An interrupted press returns its original physical release")
        expect(h.input.stats.pairedMouseUps == 1 && !h.input.isIsolatingPress,
               "Interruption still pairs one native release and ends isolation")
        h.input.stop()
        pump()
    }

    static func testRetryDefersAndCanBeCancelled() {
        let h = Harness()
        begin(h)
        h.input.retry()
        expect(h.worker.stopCount == 0 && h.recorder.restarts == 0,
               "Retry waits for physical release before replacing the tap")
        pump()
        expect(h.recorder.restarts == 0, "Main-loop activity alone cannot restart a held press")
        expect(h.input.testingReceive(type: .leftMouseDragged,
                                     event: mouse(.leftMouseDragged, CGPoint(x: 280, y: 380))),
               "Retry keeps held-menu dragging isolated until physical release")
        let retryUp = mouse(.leftMouseUp, CGPoint(x: 300, y: 400))
        expect(h.input.testingRoutedEvent(type: .leftMouseUp, event: retryUp) === retryUp,
               "Retry returns the original physical release through the native callback")
        expect(h.input.stats.pairedMouseUps == 1, "Retry counts one physical release pairing")
        pump(until: { h.recorder.restarts == 1 })
        expect(h.worker.stopCount == 1 && h.recorder.restarts == 1,
               "Release stops the old worker and requests one restart")
        pump()
        expect(h.recorder.restarts == 1, "Deferred restart is requested only once")

        let cancelled = Harness()
        begin(cancelled)
        cancelled.input.retry()
        var completed = 0
        cancelled.input.stop(afterRelease: { completed += 1 })
        expect(cancelled.worker.stopCount == 0, "Explicit stop still preserves release routing")
        _ = cancelled.input.testingReceive(type: .leftMouseUp,
                                          event: mouse(.leftMouseUp, CGPoint(x: 300, y: 400)))
        pump(until: { completed == 1 })
        expect(cancelled.worker.stopCount == 1 && completed == 1,
               "Explicit stop completes after physical release")
        expect(cancelled.recorder.restarts == 0, "Explicit stop cancels an outstanding retry")
    }

    static func testStopAfterQueuedRelease() {
        let h = Harness()
        begin(h)
        var first = 0
        var second = 0
        h.input.stop(afterRelease: { first += 1 })
        _ = h.input.testingReceive(type: .leftMouseUp,
                                  event: mouse(.leftMouseUp, CGPoint(x: 300, y: 400)))
        // The deferred finish has been queued, but has not run yet.
        h.input.stop(afterRelease: { second += 1 })
        expect(first == 0 && second == 0, "Both queued-stop completions remain asynchronous")
        expect(h.worker.stopCount == 1, "Second stop can close an already released tap")
        pump(until: { first == 1 && second == 1 })
        expect(first == 1 && second == 1, "A second stop cannot discard either completion")
        pump()
        expect(first == 1 && second == 1 && h.worker.stopCount == 1,
               "The obsolete finish task cannot duplicate completion or teardown")
    }

    static func testHeldStopWaitsForWorkerAcknowledgement() {
        let h = Harness()
        h.worker.automaticallyAcknowledgesStop = false
        begin(h)
        var completed = 0
        h.input.stop(afterRelease: { completed += 1 })
        expect(h.worker.stopCount == 0 && completed == 0, "Held termination retains the tap until physical up")
        let up = mouse(.leftMouseUp, CGPoint(x: 300, y: 400))
        expect(h.input.testingRoutedEvent(type: .leftMouseUp, event: up) === up,
               "Held termination returns the physical up before worker shutdown")
        pump(until: { h.worker.stopCount == 1 })
        expect(h.worker.stopCount == 1 && h.worker.pendingStopAcknowledgements == 1,
               "Physical up requests worker shutdown and awaits its acknowledgement")
        expect(completed == 0, "Termination cannot complete while the worker may still be inside its callback")
        pump()
        expect(completed == 0, "Main-queue activity cannot substitute for worker shutdown acknowledgement")
        h.worker.acknowledgeStop()
        expect(completed == 0, "Worker acknowledgement delivers termination asynchronously")
        pump(until: { completed == 1 })
        expect(completed == 1, "Termination completes once after the worker has stopped")
        h.worker.acknowledgeStop()
        pump()
        expect(completed == 1, "Repeated worker acknowledgement cannot complete termination twice")
    }

    static func testRetryWaitsForWorkerAcknowledgement() {
        let h = Harness()
        h.worker.automaticallyAcknowledgesStop = false
        begin(h)
        h.input.retry()
        let up = mouse(.leftMouseUp, CGPoint(x: 300, y: 400))
        expect(h.input.testingRoutedEvent(type: .leftMouseUp, event: up) === up,
               "Retry returns the physical up before requesting a new worker")
        pump(until: { h.worker.stopCount == 1 })
        expect(h.worker.stopCount == 1 && h.recorder.restarts == 0,
               "Retry requests old-worker shutdown without restarting early")
        pump()
        expect(h.recorder.restarts == 0, "Retry remains pending until old-worker shutdown is acknowledged")
        h.worker.acknowledgeStop()
        pump(until: { h.recorder.restarts == 1 })
        expect(h.recorder.restarts == 1, "Retry restarts once after old-worker shutdown acknowledgement")
        h.worker.acknowledgeStop()
        pump()
        expect(h.recorder.restarts == 1, "Repeated acknowledgement cannot repeat a deferred restart")
    }

    static func testRepeatedStopWhileWorkerIsStopping() {
        let h = Harness()
        h.worker.automaticallyAcknowledgesStop = false
        begin(h)
        var first = 0
        var second = 0
        var third = 0
        h.input.stop(afterRelease: { first += 1 })
        _ = h.input.testingRoutedEvent(type: .leftMouseUp,
                                      event: mouse(.leftMouseUp, CGPoint(x: 300, y: 400)))
        pump(until: { h.worker.stopCount == 1 })
        h.input.stop(afterRelease: { second += 1 })
        h.input.stop(afterRelease: { third += 1 })
        pump()
        expect(first == 0 && second == 0 && third == 0,
               "Repeated stop keeps every completion pending until the worker is stopped")
        expect(h.worker.stopCount == 1 && h.worker.pendingStopAcknowledgements == 1,
               "Repeated stop shares the one in-flight worker shutdown")
        h.worker.acknowledgeStop()
        pump(until: { first == 1 && second == 1 && third == 1 })
        expect(first == 1 && second == 1 && third == 1,
               "Worker acknowledgement preserves and delivers every pending stop completion")
        pump()
        expect(first == 1 && second == 1 && third == 1 && h.worker.stopCount == 1,
               "Repeated stop never duplicates completion or worker shutdown")
    }

    static func testExplicitStopCancelsRestartDuringWorkerShutdown() {
        let h = Harness()
        h.worker.automaticallyAcknowledgesStop = false
        begin(h)
        h.input.retry()
        _ = h.input.testingRoutedEvent(type: .leftMouseUp,
                                      event: mouse(.leftMouseUp, CGPoint(x: 300, y: 400)))
        pump(until: { h.worker.stopCount == 1 })
        expect(h.recorder.restarts == 0, "Retry is pending during old-worker shutdown")
        var completed = 0
        h.input.stop(afterRelease: { completed += 1 })
        pump()
        expect(completed == 0 && h.recorder.restarts == 0,
               "Explicit stop during shutdown waits for acknowledgement and cancels restart")
        h.worker.acknowledgeStop()
        pump(until: { completed == 1 })
        expect(completed == 1 && h.recorder.restarts == 0,
               "A late worker acknowledgement completes stop without reviving the cancelled retry")
        pump()
        expect(completed == 1 && h.recorder.restarts == 0 && h.worker.stopCount == 1,
               "Cancelled retry stays cancelled after all queued work drains")
    }

    static func testPhysicalPointerAndNativeRelease() {
        let h = Harness()
        begin(h)
        let physicalPoint = CGPoint(x: 350, y: 440)
        let up = mouse(.leftMouseUp, physicalPoint, pid: 300)
        up.timestamp = 987_654_321
        up.flags = [.maskShift]
        up.setIntegerValueField(.mouseEventDeltaX, value: 325)
        up.setIntegerValueField(.mouseEventDeltaY, value: 408)
        up.setIntegerValueField(.mouseEventNumber, value: 42)
        up.setIntegerValueField(.mouseEventClickState, value: 2)
        up.setIntegerValueField(.eventSourceUserData, value: 0x1234)
        up.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 50)
        up.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: 51)
        expect(h.input.testingRoutedEvent(type: .leftMouseUp, event: up) === up,
               "Owned up returns the identical physical event instead of consuming and reposting it")
        expect(h.recorder.mouse.isEmpty, "Menu pointer callbacks stay outside the tap callback")
        expect(up.location == CGPoint(x: 25, y: 32), "Native up uses only the safe position")
        expect(up.getIntegerValueField(.mouseEventDeltaX) == 0 && up.getIntegerValueField(.mouseEventDeltaY) == 0,
               "Native up carries no pointer movement deltas")
        expect(up.timestamp == 987_654_321 && up.flags == [.maskShift], "Native timestamp and flags remain intact")
        for (field, value): (CGEventField, Int64) in [(.eventTargetUnixProcessID, 300),
                (.mouseEventNumber, 42), (.mouseEventClickState, 2), (.eventSourceUserData, 0x1234),
                (.mouseEventWindowUnderMousePointer, 50), (.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, 51)] {
            expect(up.getIntegerValueField(field) == value, "Native metadata \(field.rawValue) remains intact")
        }
        expect(h.input.stats.pairedMouseUps == 1, "The callback records one native release pairing")
        pump(until: { h.recorder.mouse.contains { $0.type == .leftMouseUp } })
        expect(h.recorder.mouse.last?.type == .leftMouseUp && h.recorder.mouse.last?.point == physicalPoint,
               "The menu receives the independently preserved physical release location")
        expect(h.recorder.mouse.filter { $0.type == .leftMouseUp }.count == 1,
               "One physical release creates one menu callback")

        let freeMove = mouse(.mouseMoved, CGPoint(x: 360, y: 450))
        expect(h.input.testingRoutedEvent(type: .mouseMoved, event: freeMove) === freeMove,
               "Pointer movement with no captured button remains native")
        expect(!h.input.isIsolatingPress && h.input.stats.pairedMouseUps == 1,
               "Free pointer movement does not rearm isolation")
        let down = mouse(.leftMouseDown, CGPoint(x: 50, y: 60))
        let drag = mouse(.leftMouseDragged, CGPoint(x: 55, y: 62))
        let ordinaryUp = mouse(.leftMouseUp, CGPoint(x: 60, y: 70))
        for event in [down, drag, ordinaryUp] {
            expect(h.input.testingRoutedEvent(type: event.type, event: event) === event,
                   "The following ordinary click/drag/release sequence passes the original events")
        }
        expect(drag.location == CGPoint(x: 55, y: 62) && ordinaryUp.location == CGPoint(x: 60, y: 70),
               "The following ordinary drag and release retain their physical coordinates")
        expect(h.input.stats.pairedMouseUps == 1 && h.input.stats.blockedDragEvents == 0,
               "Ordinary input does not change isolation counters")
        h.input.stop()
        pump()
    }

    static func main() {
        expect(Thread.isMainThread, "Lifecycle tests run on the application dispatch thread")
        testIdleStop()
        testActiveStopWaitsForPhysicalUp()
        testPolicyChangesDoNotLeakDragging()
        testRetryDefersAndCanBeCancelled()
        testStopAfterQueuedRelease()
        testHeldStopWaitsForWorkerAcknowledgement()
        testRetryWaitsForWorkerAcknowledgement()
        testRepeatedStopWhileWorkerIsStopping()
        testExplicitStopCancelsRestartDuringWorkerShutdown()
        testPhysicalPointerAndNativeRelease()
        print("PressureInputLifecycleTests: \(assertions) assertions passed")
    }
}
