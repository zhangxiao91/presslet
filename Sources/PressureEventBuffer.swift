import Foundation

struct PressureInputPolicy: Equatable {
    var enabled = true
    var paused = false
    var autoMenu = true
    var gestureEnabled = true
    var overlayVisible = false
    var menuVisible = false
    var ownPID: Int32 = 0
    var frontmostPID: Int32 = 0
    var interceptedPIDs: Set<Int32> = []
    var menuPIDs: Set<Int32> = []
}

struct PressureInputStats: Equatable {
    var blockedPressureEvents = 0
    var blockedPresses = 0
    var rawGestureEvents = 0
    var overflows = 0
    var blockedDragEvents = 0
    var pairedMouseUps = 0
}

struct PressureFilterDecision: Equatable {
    var eligibleInput = false
    var shouldBlock = false
}

/// The event-tap path uses only these cached values; it never resolves apps.
struct PressureInputFilter {
    private(set) var blockedThisPress = false
    private(set) var suppressGestureUntilUp = false
    private(set) var awaitingFreshDown = false
    private(set) var stats = PressureInputStats()

    mutating func mouseDown(policy: PressureInputPolicy) {
        blockedThisPress = false
        suppressGestureUntilUp = policy.menuVisible
        awaitingFreshDown = false
    }

    mutating func mouseUp() {
        blockedThisPress = false
        suppressGestureUntilUp = false
    }

    mutating func cancelUntilNextDown() {
        blockedThisPress = false
        suppressGestureUntilUp = false
        awaitingFreshDown = true
    }

    mutating func rawGesture(policy: PressureInputPolicy) {
        if policy.enabled && !policy.paused && policy.gestureEnabled { stats.rawGestureEvents += 1 }
    }

    mutating func recordBlockedDrag() { stats.blockedDragEvents += 1 }
    mutating func recordPairedMouseUp() { stats.pairedMouseUps += 1 }

    mutating func recordOverflow() {
        stats.overflows += 1
        cancelUntilNextDown()
    }

    mutating func pressure(stage: Int, targetPID: Int32, policy: PressureInputPolicy,
                           canFilter: Bool) -> PressureFilterDecision {
        guard policy.enabled, !policy.paused, policy.gestureEnabled, !awaitingFreshDown else { return .init() }
        let eligible = !policy.overlayVisible && !policy.menuVisible && !suppressGestureUntilUp
            && targetPID != policy.ownPID
            && !(targetPID == 0 && policy.frontmostPID == policy.ownPID)
        let resolvedPID = targetPID == 0 ? policy.frontmostPID : targetPID
        let block = canFilter && policy.autoMenu && stage >= 2
            && (blockedThisPress || (eligible && policy.interceptedPIDs.contains(resolvedPID)))
        if block {
            stats.blockedPressureEvents += 1
            if !blockedThisPress { stats.blockedPresses += 1 }
            blockedThisPress = true
        }
        return PressureFilterDecision(eligibleInput: eligible, shouldBlock: block)
    }
}

enum PressureBufferedKind: Equatable {
    case mouseDown
    case mouseUp
    case pressure(stage: Int)
    case coalescible(String)
    case other
    case cancellation
}

struct PressureBufferedEvent<Payload> {
    let generation: UInt64
    let kind: PressureBufferedKind
    let payload: Payload
}

enum PressureBufferAppendResult: Equatable {
    case appended
    case coalesced
    case stale
    case overflow
}

/// Caller serializes access. Only adjacent movement samples coalesce; boundaries
/// and pressure stages stay in original order. Overflow discards the whole
/// pending gesture, so its caller must deliver cancellation and pass through
/// until a fresh mouse down.
struct PressureEventBuffer<Payload> {
    let capacity: Int
    private(set) var generation: UInt64
    private var items: [PressureBufferedEvent<Payload>] = []
    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    init(capacity: Int = 1024, generation: UInt64 = 0) {
        self.capacity = max(2, capacity)
        self.generation = generation
    }

    mutating func reset(generation: UInt64) {
        self.generation = generation
        items.removeAll(keepingCapacity: true)
    }

    mutating func append(_ payload: Payload, kind: PressureBufferedKind,
                         generation: UInt64) -> PressureBufferAppendResult {
        guard generation == self.generation else { return .stale }
        let event = PressureBufferedEvent(generation: generation, kind: kind, payload: payload)
        if case .coalescible = kind, items.last?.kind == kind {
            items[items.count - 1] = event
            return .coalesced
        }
        guard items.count < capacity else {
            items.removeAll(keepingCapacity: true)
            return .overflow
        }
        items.append(event)
        return .appended
    }

    mutating func replaceWithCancellation(_ payload: Payload, generation: UInt64) {
        guard generation == self.generation else { return }
        items = [PressureBufferedEvent(generation: generation, kind: .cancellation, payload: payload)]
    }

    mutating func take(limit: Int = 128) -> [PressureBufferedEvent<Payload>] {
        let end = min(items.count, max(1, limit))
        let result = Array(items.prefix(end))
        items.removeFirst(end)
        return result
    }
}
