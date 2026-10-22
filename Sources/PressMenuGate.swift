struct PressMenuTrigger: Equatable {
    let source: String
    let appName: String
    let bundleID: String
    let generation: UInt64
}

struct PressMenuGate {
    private var generation: UInt64 = 0
    private var pending: PressMenuTrigger?
    private var released: PressMenuTrigger?

    init() {}

    mutating func arm(source: String, appName: String, bundleID: String) {
        generation &+= 1
        pending = PressMenuTrigger(source: source, appName: appName,
                                   bundleID: bundleID, generation: generation)
        released = nil
    }

    mutating func release(source: String) -> PressMenuTrigger? {
        guard let trigger = pending, trigger.source == source else { return nil }
        pending = nil
        released = trigger
        return trigger
    }

    mutating func cancel() {
        generation &+= 1
        pending = nil
        released = nil
    }

    func isCurrent(_ trigger: PressMenuTrigger) -> Bool {
        released == trigger
    }
}
