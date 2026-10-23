import Foundation

struct PressureFeedback {
    private(set) var isDeepPressed = false

    static let minimumCompression: CGFloat = 0.38
    static let saturationPressure: CGFloat = 0.65
    static let deepPressEnter: CGFloat = 0.22
    static let deepPressExit: CGFloat = 0.10

    mutating func update(stage: Int, pressure: CGFloat) -> CGFloat {
        guard stage >= 2, pressure.isFinite else {
            reset()
            return 0
        }
        let clamped = min(1, max(0, pressure))
        if isDeepPressed {
            if clamped <= Self.deepPressExit { isDeepPressed = false }
        } else if clamped >= Self.deepPressEnter {
            isDeepPressed = true
        }

        let progress = min(1, clamped / Self.saturationPressure)
        let smooth = progress * progress * (3 - 2 * progress)
        return Self.minimumCompression + (1 - Self.minimumCompression) * smooth
    }

    mutating func reset() {
        isDeepPressed = false
    }
}
