import CoreGraphics

/// Tracks the mouse sequence already delivered to the underlying application.
/// Once a menu takes over, drags stay private and the physical up finishes the
/// underlying sequence at its last delivered position. Menu cancellation does
/// not end this sequence; only a physical up or a fresh down does.
struct PressDragIsolation {
    private var downTargetPID: Int32?
    private var lastDeliveredPoint: CGPoint?
    private var releasePoint: CGPoint?

    var isActive: Bool { releasePoint != nil }
    var activeTargetPID: Int32? { isActive ? downTargetPID : nil }

    /// A new physical down also recovers from an up missed while the tap was
    /// disabled. Returns whether it replaced an unfinished isolated sequence.
    @discardableResult
    mutating func mouseDown(at point: CGPoint, targetPID: Int32) -> Bool {
        let replacedActiveSequence = isActive
        releasePoint = nil
        downTargetPID = targetPID > 0 && point.x.isFinite && point.y.isFinite ? targetPID : nil
        lastDeliveredPoint = downTargetPID == nil ? nil : point
        return replacedActiveSequence
    }

    /// Returns true when the system must not receive this drag. Otherwise the
    /// caller passes it through and this position becomes the safe release point.
    mutating func mouseDragged(at point: CGPoint) -> Bool {
        guard !isActive else { return true }
        if downTargetPID != nil, point.x.isFinite, point.y.isFinite {
            lastDeliveredPoint = point
        }
        return false
    }

    /// The caller checks menu eligibility using its cached policy first. A
    /// source mismatch or an unobserved down cannot claim a mouse sequence.
    @discardableResult
    mutating func begin(targetPID: Int32) -> Bool {
        guard !isActive, targetPID > 0, downTargetPID == targetPID,
              let point = lastDeliveredPoint else { return false }
        releasePoint = point
        return true
    }

    /// Returns the location for the original physical up, or nil for a normal
    /// release. The menu must receive its own unmodified copy of the up first.
    mutating func mouseUp() -> CGPoint? {
        let point = releasePoint
        releasePoint = nil
        downTargetPID = nil
        lastDeliveredPoint = nil
        return point
    }
}
