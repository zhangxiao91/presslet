import CoreGraphics

struct PressDragEventRouting {
    let observed: CGEvent?
    var suppress = false
    var pairedMouseUp = false
    var endedIsolation = false
}

/// Keeps the menu's physical pointer sample separate from the event delivered
/// to the application that received mouse-down. This never posts input itself.
struct PressDragEventRouter {
    private var isolation = PressDragIsolation()
    var isActive: Bool { isolation.isActive }

    @discardableResult
    mutating func begin(targetPID: Int32) -> Bool {
        isolation.begin(targetPID: targetPID)
    }

    mutating func route(type: CGEventType, event: CGEvent, frontmostPID: Int32) -> PressDragEventRouting {
        // Copy before relocating a release: menu selection always uses the real pointer.
        var result = PressDragEventRouting(observed: event.copy())
        switch type {
        case .leftMouseDown:
            let rawPID = Int32(clamping: event.getIntegerValueField(.eventTargetUnixProcessID))
            result.endedIsolation = isolation.mouseDown(at: event.location, targetPID: rawPID == 0 ? frontmostPID : rawPID)
        case .leftMouseDragged:
            result.suppress = isolation.mouseDragged(at: event.location)
        case .leftMouseUp:
            if let point = isolation.mouseUp() {
                result.endedIsolation = true
                event.location = point
                event.setIntegerValueField(.mouseEventDeltaX, value: 0)
                event.setIntegerValueField(.mouseEventDeltaY, value: 0)
                // Keep this one physical up in the session stream so the system
                // can end its native mouse capture. Leave source/target/window
                // metadata intact; posting a replacement to a PID skips that path.
                result.pairedMouseUp = true
            }
        default: break
        }
        return result
    }
}
