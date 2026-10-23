import AppKit
import ApplicationServices

struct InputConnectionState: Equatable {
    var hasGlobalMonitor = false
    var hasTap = false
    var tapEnabled = false
    var canFilter = false
    var error: String?
}

/// Owns platform listeners and delivers their events asynchronously, in order.
/// The tap itself only consults cached policy, decides filtering, and buffers input.
final class PressureInputManager {
    var onLocalEvent: ((NSEvent) -> Void)?
    var onGlobalEvent: ((NSEvent) -> Void)?
    var onPressure: ((NSEvent, Bool) -> Void)?
    var onTapMouse: ((CGEventType, CGEvent) -> Void)?
    var onStatus: ((InputConnectionState) -> Void)?
    var onCancelGesture: ((String) -> Void)?

    private enum Delivery {
        case local(NSEvent, UInt64)
        case global(NSEvent)
        case pressure(NSEvent, Bool)
        case mouse(CGEventType, CGEvent)
        case status(InputConnectionState)
        case cancel(String)
    }

    private final class TapContext {
        weak var owner: PressureInputManager?
        let generation: UInt64
        init(owner: PressureInputManager, generation: UInt64) {
            self.owner = owner
            self.generation = generation
        }
    }

    /// Owns the port, source, and callback context until its thread has removed
    /// the source and invalidated the port. Stop is a signal, never a join.
    private final class TapWorker {
        let port: CFMachPort
        private let source: CFRunLoopSource
        private let context: TapContext
        private let control = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private var runLoop: CFRunLoop?
        private var stopping = false

        init?(port: CFMachPort, context: TapContext) {
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return nil }
            self.port = port
            self.context = context
            self.source = source
        }

        func start() -> Bool {
            let thread = Thread { [self] in
                autoreleasepool { run() }
            }
            thread.name = "Presslet.PressureInput"
            thread.qualityOfService = .userInteractive
            thread.start()
            // Setup only waits for source installation, never event handling or
            // thread teardown. A delayed startup is cancelled after this bound.
            guard ready.wait(timeout: .now() + 1) == .success else {
                requestStop()
                return false
            }
            return true
        }

        func requestStop() {
            control.lock()
            stopping = true
            let loop = runLoop
            control.unlock()
            guard let loop else { return }
            // A queued block also handles the race before CFRunLoopRun begins.
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(loop)
        }

        private func run() {
            let loop = CFRunLoopGetCurrent()!
            control.lock()
            runLoop = loop
            let stopBeforeStartup = stopping
            control.unlock()
            if !stopBeforeStartup {
                CFRunLoopAddSource(loop, source, .commonModes)
                CGEvent.tapEnable(tap: port, enable: true)
            }
            ready.signal()
            control.lock()
            let shouldRun = !stopping
            control.unlock()
            if shouldRun { CFRunLoopRun() }
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            CFRunLoopRemoveSource(loop, source, .commonModes)
            control.lock()
            runLoop = nil
            control.unlock()
            // The thread closure retains self, including context, through here.
            withExtendedLifetime(context) {}
        }
    }

    private let lock = NSLock()
    private var policy = PressureInputPolicy()
    private var filter = PressureInputFilter()
    private var state = InputConnectionState()
    private var generation: UInt64 = 0
    // Cancels already-extracted batches without invalidating the live tap token.
    private var deliveryEpoch: UInt64 = 0
    private var localGeneration: UInt64 = 0
    private var buffer: PressureEventBuffer<Delivery>
    private var drainScheduled = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var tap: CFMachPort?
    private var tapWorker: TapWorker?
    private var observing = false

    init(bufferCapacity: Int = 1024) {
        buffer = PressureEventBuffer(capacity: bufferCapacity)
    }

    var connectionState: InputConnectionState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    var stats: PressureInputStats {
        lock.lock(); defer { lock.unlock() }
        return filter.stats
    }

    func updatePolicy(_ value: PressureInputPolicy) {
        lock.lock(); defer { lock.unlock() }
        let suspending = (!value.enabled || value.paused || !value.gestureEnabled)
            && policy.enabled && !policy.paused && policy.gestureEnabled
        policy = value
        if suspending {
            filter.cancelUntilNextDown()
            deliveryEpoch &+= 1
            buffer.replaceWithCancellation(.cancel("输入已暂停"), generation: generation)
            scheduleDrainLocked()
        }
    }

    func startLocal() {
        precondition(Thread.isMainThread)
        guard localMonitor == nil else { return }
        lock.lock()
        localGeneration &+= 1
        let token = localGeneration
        lock.unlock()
        let mask: NSEvent.EventTypeMask = [.pressure, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                           .mouseMoved, .keyDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let consumed = self?.enqueueLocal(event, token: token) ?? false
            return consumed ? nil : event
        }
    }

    func stopLocal() {
        precondition(Thread.isMainThread)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        lock.lock()
        localGeneration &+= 1
        lock.unlock()
    }

    func start() {
        precondition(Thread.isMainThread)
        lock.lock()
        guard !observing else { lock.unlock(); return }
        observing = true
        generation &+= 1
        let token = generation
        deliveryEpoch &+= 1
        buffer.reset(generation: token)
        drainScheduled = false
        filter.cancelUntilNextDown()
        lock.unlock()
        let mask: NSEvent.EventTypeMask = [.pressure, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                           .mouseMoved, .keyDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.enqueueGlobal(event, token: token)
        }
        // Permission checks belong to setup, never the event callback.
        let canFilter = AXIsProcessTrusted()
        let canListen = canFilter || CGPreflightListenEventAccess()
        var newState = InputConnectionState(hasGlobalMonitor: globalMonitor != nil,
                                             canFilter: canFilter)
        var newWorker: TapWorker?
        if canListen {
            let context = TapContext(owner: self, generation: token)
            let eventMask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
                | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
                | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
                | (CGEventMask(1) << NSEvent.EventType.gesture.rawValue)
            if let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: canFilter ? .defaultTap : .listenOnly,
                                           eventsOfInterest: eventMask, callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<TapContext>.fromOpaque(info).takeUnretainedValue()
                guard let owner = context.owner else { return Unmanaged.passUnretained(event) }
                return autoreleasepool {
                    owner.handleTap(type: type, event: event, token: context.generation)
                }
            }, userInfo: Unmanaged.passUnretained(context).toOpaque()) {
                newWorker = TapWorker(port: port, context: context)
                if newWorker == nil { CFMachPortInvalidate(port) }
                newState.hasTap = newWorker != nil
            }
            if newWorker == nil { newState.error = "输入连接失败，请检查权限后重试。" }
        } else {
            newState.error = "等待输入监控或辅助功能权限。"
        }
        lock.lock()
        tapWorker = newWorker
        tap = newWorker?.port
        state = newState
        lock.unlock()
        // The worker owns its callback context before it enables the tap.
        if let newWorker {
            let started = newWorker.start()
            lock.lock()
            if token == generation {
                state.tapEnabled = started && CGEvent.tapIsEnabled(tap: newWorker.port)
                if !started {
                    state.hasTap = false
                    state.error = "输入线程未能启动，请重试。"
                    tapWorker = nil
                    tap = nil
                }
            }
            lock.unlock()
        }
        lock.lock()
        _ = enqueueLocked(.status(state), kind: .other, token: token)
        lock.unlock()
    }

    func stop() {
        precondition(Thread.isMainThread)
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        lock.lock()
        observing = false
        generation &+= 1
        let oldWorker = tapWorker
        tapWorker = nil
        tap = nil
        deliveryEpoch &+= 1
        buffer.reset(generation: generation)
        drainScheduled = false
        filter.cancelUntilNextDown()
        state = InputConnectionState()
        _ = enqueueLocked(.status(state), kind: .other, token: generation)
        lock.unlock()
        oldWorker?.requestStop()
    }

    func retry() {
        precondition(Thread.isMainThread)
        stop()
        start()
    }

    private func enqueueLocal(_ event: NSEvent, token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard token == localGeneration else { return false }
        // Only this cached-policy decision is synchronous. Closing the menu still
        // routes through the ordered queue, so Esc cannot reach the underlying UI.
        let consumed = policy.menuVisible && event.type == .keyDown && event.keyCode == 53
        _ = enqueueLocked(.local(event, token), kind: bufferedKind(event, source: "local"), token: generation)
        return consumed
    }

    private func enqueueGlobal(_ event: NSEvent, token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard observing, token == generation, policy.enabled, !policy.paused else { return }
        _ = enqueueLocked(.global(event), kind: bufferedKind(event, source: "global"), token: token)
    }

    private func bufferedKind(_ event: NSEvent, source: String) -> PressureBufferedKind {
        switch event.type {
        case .leftMouseDown: return .mouseDown
        case .leftMouseUp: return .mouseUp
        case .pressure: return .pressure(stage: event.stage)
        case .mouseMoved: return .coalescible(source + ".move")
        case .leftMouseDragged: return .coalescible(source + ".drag")
        default: return .other
        }
    }

    private func handleTap(type: CGEventType, event: CGEvent, token: UInt64) -> Unmanaged<CGEvent>? {
        lock.lock(); defer { lock.unlock() }
        guard observing, token == generation else { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            filter.cancelUntilNextDown()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            state.tapEnabled = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
            state.error = state.tapEnabled ? "输入连接曾被系统暂停，已重新连接。" : "输入连接被系统暂停，请重试。"
            deliveryEpoch &+= 1
            buffer.replaceWithCancellation(.cancel("输入连接被系统暂停"), generation: token)
            _ = enqueueLocked(.status(state), kind: .other, token: token)
            scheduleDrainLocked()
            return Unmanaged.passUnretained(event)
        }
        guard policy.enabled, !policy.paused else { return Unmanaged.passUnretained(event) }
        if type.rawValue == UInt32(NSEvent.EventType.gesture.rawValue) {
            filter.rawGesture(policy: policy)
            guard policy.gestureEnabled, !filter.awaitingFreshDown,
                  let ownedEvent = event.copy(),
                  let converted = NSEvent(cgEvent: ownedEvent), converted.type == .pressure else {
                return Unmanaged.passUnretained(event)
            }
            let target = Int32(clamping: ownedEvent.getIntegerValueField(.eventTargetUnixProcessID))
            var nextFilter = filter
            let decision = nextFilter.pressure(stage: converted.stage, targetPID: target,
                                               policy: policy, canFilter: state.canFilter)
            let queued = enqueueLocked(.pressure(converted, decision.eligibleInput),
                                       kind: .pressure(stage: converted.stage), token: token)
            if queued != .overflow { filter = nextFilter }
            return queued != .overflow && decision.shouldBlock ? nil : Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDown { filter.mouseDown(policy: policy) }
        if type == .leftMouseUp { filter.mouseUp() }
        let kind: PressureBufferedKind = type == .leftMouseDown ? .mouseDown
            : type == .leftMouseUp ? .mouseUp : .coalescible("tap.drag")
        _ = enqueueLocked(.mouse(type, event.copy() ?? event), kind: kind, token: token)
        return Unmanaged.passUnretained(event)
    }

    @discardableResult
    private func enqueueLocked(_ delivery: Delivery, kind: PressureBufferedKind,
                               token: UInt64) -> PressureBufferAppendResult {
        let result = buffer.append(delivery, kind: kind, generation: token)
        if result == .overflow {
            filter.recordOverflow()
            deliveryEpoch &+= 1
            buffer.replaceWithCancellation(.cancel("输入积压，已取消本次重按，请松开后重新按下。"), generation: token)
        }
        if result != .stale { scheduleDrainLocked() }
        return result
    }

    private func scheduleDrainLocked() {
        guard !drainScheduled else { return }
        drainScheduled = true
        let token = generation
        DispatchQueue.main.async { [weak self] in self?.drain(token: token) }
    }

    private func drain(token: UInt64) {
        precondition(Thread.isMainThread)
        lock.lock()
        guard token == generation else { lock.unlock(); return }
        let batchEpoch = deliveryEpoch
        let deliveries = buffer.take()
        lock.unlock()
        for event in deliveries {
            lock.lock()
            let current = token == generation && batchEpoch == deliveryEpoch
            lock.unlock()
            // Cancellation may race with an extracted batch. Stop its remainder,
            // then reach the normal tail so the queued cancel is rescheduled.
            guard current else { break }
            switch event.payload {
            case .local(let event, let localToken):
                lock.lock()
                let currentLocal = localToken == localGeneration
                lock.unlock()
                if currentLocal { onLocalEvent?(event) }
            case .global(let event): onGlobalEvent?(event)
            case .pressure(let event, let eligible): onPressure?(event, eligible)
            case .mouse(let type, let event): onTapMouse?(type, event)
            case .status(let state): onStatus?(state)
            case .cancel(let reason): onCancelGesture?(reason)
            }
        }
        lock.lock()
        guard token == generation else { lock.unlock(); return }
        drainScheduled = false
        if !buffer.isEmpty { scheduleDrainLocked() }
        lock.unlock()
    }

    deinit {
        let monitors = [localMonitor, globalMonitor].compactMap { $0 }
        if Thread.isMainThread {
            monitors.forEach { NSEvent.removeMonitor($0) }
        } else {
            DispatchQueue.main.async { monitors.forEach { NSEvent.removeMonitor($0) } }
        }
        // Safe even if deinit runs after the final callback on the worker itself.
        // The worker/context keep living until asynchronous run-loop teardown.
        tapWorker?.requestStop()
    }
}
