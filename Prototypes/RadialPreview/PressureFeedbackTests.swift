import Foundation

@main
struct PressureFeedbackTestRunner {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool,
                       _ message: String, line: Int = #line) {
        assertions += 1
        guard condition() else {
            fputs("FAIL line \(line): \(message)\n", stderr)
            exit(1)
        }
    }

    static func close(_ actual: CGFloat, _ expected: CGFloat) -> Bool {
        abs(actual - expected) < 0.000001
    }

    static func main() {
        var feedback = PressureFeedback()
        expect(!feedback.isDeepPressed, "Feedback starts without a deep-press latch")
        expect(feedback.update(stage: 2, pressure: 0) == 0.38,
               "A stage-two first frame immediately has visible base compression")
        expect(!feedback.isDeepPressed, "Base compression does not engage the extra haptic latch")
        expect(feedback.update(stage: 2, pressure: 0.219) > 0.38,
               "Pressure continuously strengthens compression before the haptic threshold")
        expect(!feedback.isDeepPressed, "The deep latch waits for the exact enter threshold")
        let belowEnter = feedback.update(stage: 2, pressure: 0.219999)
        let atEnter = feedback.update(stage: 2, pressure: 0.22)
        expect(atEnter > belowEnter && atEnter - belowEnter < 0.00001,
               "Engaging the deep latch does not jump the continuous compression")
        expect(feedback.isDeepPressed, "The deep latch engages at 0.22")
        expect(close(feedback.update(stage: 2, pressure: 0.325), 0.69),
               "Half saturation pressure gives the midpoint of base and full compression")
        expect(feedback.update(stage: 2, pressure: 0.649) < 1,
               "Compression remains continuous immediately below saturation")
        expect(feedback.update(stage: 2, pressure: 0.65) == 1,
               "Compression reaches full strength early at 0.65")
        expect(feedback.update(stage: 2, pressure: 1) == 1,
               "Pressure beyond saturation stays at full strength")
        expect(feedback.update(stage: 2, pressure: 0.20) > 0.38,
               "Releasing pressure continuously approaches base compression")
        expect(feedback.isDeepPressed, "The latch persists below its enter threshold")
        expect(feedback.update(stage: 2, pressure: 0.101) > 0.38,
               "Compression remains visible near the haptic exit threshold")
        expect(feedback.isDeepPressed, "The latch persists until the exit threshold")
        expect(feedback.update(stage: 2, pressure: 0.10) > 0.38,
               "The haptic exit threshold does not remove visible compression")
        expect(!feedback.isDeepPressed, "The latch exits at 0.10")
        _ = feedback.update(stage: 2, pressure: 0.20)
        expect(!feedback.isDeepPressed, "Small pressure rebounds do not reengage the latch")
        expect(feedback.update(stage: 2, pressure: 0) == 0.38,
               "Returning to stage-two zero pressure retains the base shape")

        var previous: CGFloat = 0
        for step in 0...100 {
            let value = feedback.update(stage: 2, pressure: CGFloat(step) / 100)
            expect(value.isFinite && value >= 0.38 && value <= 1,
                   "All normal pressures produce bounded finite feedback")
            expect(value >= previous, "Increasing pressure produces monotonic feedback")
            previous = value
        }
        for stage in [-1, 0, 1] {
            _ = feedback.update(stage: 2, pressure: 1)
            expect(feedback.update(stage: stage, pressure: 1) == 0,
                   "Leaving stage two removes all additional-pressure feedback")
            expect(!feedback.isDeepPressed, "Leaving stage two clears the latch")
        }
        for invalid in [CGFloat.nan, CGFloat.infinity, -CGFloat.infinity] {
            _ = feedback.update(stage: 2, pressure: 1)
            expect(feedback.update(stage: 2, pressure: invalid) == 0,
                   "Nonfinite pressure safely returns zero")
            expect(!feedback.isDeepPressed, "Nonfinite pressure clears the latch")
        }
        expect(feedback.update(stage: 2, pressure: -0.25) == 0.38,
               "Negative pressure is clamped to the stage-two base compression")
        expect(!feedback.isDeepPressed, "Negative pressure cannot engage the latch")
        expect(feedback.update(stage: 2, pressure: 1.25) == 1,
               "Pressure above one is clamped to one")
        expect(feedback.isDeepPressed, "Clamped high pressure engages the latch")
        feedback.reset()
        expect(!feedback.isDeepPressed, "Explicit reset clears the latch")
        expect(feedback.update(stage: 2, pressure: 0) == 0.38,
               "A new stage-two cycle starts with base compression")
        print("PASS: \(assertions) pressure feedback assertions")
    }
}
