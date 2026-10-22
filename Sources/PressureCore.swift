public enum PressureInput {
    case pressure(stage: Int, value: Double)
    case mouseDown
    case mouseUp
    case cancel
}

public struct PressureCycle {
    public let source: String
    public private(set) var isEnabled: Bool
    public private(set) var isDeep = false
    private var requiresRelease: Bool

    public init(source: String = "local", isEnabled: Bool = true) {
        self.source = source
        self.isEnabled = isEnabled
        self.requiresRelease = !isEnabled
    }

    public mutating func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled { invalidateCycle() }
    }

    // A true result means the first deep stage of a valid press cycle.
    // A tap's mouse pressure is observational: it cannot establish stage 2.
    public mutating func accept(_ input: PressureInput) -> Bool {
        switch input {
        case .mouseUp:
            release()
            return false
        case .cancel:
            invalidateCycle()
            return false
        case .mouseDown:
            // A newly observed physical down establishes a fresh cycle even
            // when the preceding up happened before monitoring began.
            // Repeated down events during an already-deep hold do not rearm.
            if isEnabled && !isDeep { requiresRelease = false }
            return false
        case let .pressure(stage, value):
            guard stage >= 0, value.isFinite, (0...1).contains(value) else {
                invalidateCycle()
                return false
            }
            if stage == 0 {
                release()
                return false
            }
            guard isEnabled, source != "tap", !requiresRelease,
                  stage >= 2, !isDeep else { return false }
            isDeep = true
            return true
        }
    }

    private mutating func release() {
        isDeep = false
        requiresRelease = false
    }

    private mutating func invalidateCycle() {
        isDeep = false
        // Require an observed release or a fresh physical down before a
        // still-held press can fire again.
        requiresRelease = true
    }
}
