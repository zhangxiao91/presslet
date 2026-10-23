import Foundation

@main
struct RadialBubbleMotionTestRunner {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool,
                       _ message: String, line: Int = #line) {
        assertions += 1
        guard condition() else {
            fputs("FAIL line \(line): \(message)\n", stderr)
            exit(1)
        }
    }

    static func close(_ lhs: CGFloat, _ rhs: CGFloat,
                      tolerance: CGFloat = 0.00000001) -> Bool {
        abs(lhs - rhs) < tolerance
    }

    static func main() {
        var spring = RadialSpring()
        expect(spring.isSettled, "An untouched spring starts settled")
        expect(!spring.advance(by: 1.0 / 60), "A resting spring needs no further frames")
        spring.target = 1
        expect(!spring.isSettled, "Retargeting wakes the spring immediately")
        expect(spring.value == 0 && spring.velocity == 0,
               "Retargeting does not jump the displayed position")
        expect(spring.advance(by: 1.0 / 120), "A press starts moving on the next frame")
        expect(spring.value > 0 && spring.velocity > 0, "A press starts moving toward its target")
        let beforeReverse = spring
        spring.target = -1
        expect(spring.value == beforeReverse.value && spring.velocity == beforeReverse.velocity,
               "A rapid pressure reversal preserves presentation and momentum")
        spring.advance(by: 0.00001)
        expect(spring.velocity > 0, "A reversed target decelerates rather than cutting velocity")
        for _ in 0..<240 { spring.advance(by: 1.0 / 120) }
        expect(spring.isSettled && spring.value == -1 && spring.velocity == 0,
               "A reversed spring reaches its new destination and stops exactly")

        for damping: CGFloat in [0.6, 0.82, 1, 1.000001, 1.4, 4] {
            var at60 = RadialSpring(response: 0.3, dampingRatio: damping)
            var at120 = at60
            var single = at60
            at60.target = 1
            at120.target = 1
            single.target = 1
            for _ in 0..<12 { at60.advance(by: 1.0 / 60) }
            for _ in 0..<24 { at120.advance(by: 1.0 / 120) }
            single.advance(by: 0.2)
            expect(close(at60.value, at120.value) && close(at60.velocity, at120.velocity),
                   "60 Hz and 120 Hz yield the same motion for every damping regime")
            expect(close(at60.value, single.value) && close(at60.velocity, single.velocity),
                   "Irregular frame intervals match one exact elapsed interval")
            at60.advance(by: 100000)
            expect(at60.isSettled && at60.value == 1 && at60.velocity == 0,
                   "Resuming after a long suspension settles without numerical failure")
        }

        var critical = RadialSpring(response: 0.3, dampingRatio: 1)
        critical.target = 1
        var previous: CGFloat = 0
        for _ in 0..<120 {
            critical.advance(by: 1.0 / 120)
            expect(critical.value >= previous && critical.value <= 1,
                   "A critically damped spring approaches without overshoot")
            previous = critical.value
        }
        var bouncy = RadialSpring(response: 0.3, dampingRatio: 0.6)
        bouncy.target = 1
        var maximum: CGFloat = 0
        for _ in 0..<120 {
            bouncy.advance(by: 1.0 / 120)
            maximum = max(maximum, bouncy.value)
        }
        expect(maximum > 1 && maximum < 1.12,
               "Gesture momentum has a small, bounded rebound")

        var rapid = RadialSpring()
        for index in 0..<2000 {
            rapid.target = index % 7 < 3 ? 1 : 0
            rapid.advance(by: index % 2 == 0 ? 1.0 / 60 : 1.0 / 120)
            expect(rapid.value.isFinite && rapid.velocity.isFinite && abs(rapid.value) < 2,
                   "Repeated pressure changes remain finite and visually bounded")
        }
        rapid.snap(to: 0.7)
        expect(rapid.value == 0.7 && rapid.target == 0.7 && rapid.velocity == 0 && rapid.isSettled,
               "Reduced motion snaps both presentation and destination without residual velocity")
        expect(!rapid.advance(by: 1.0 / 60), "Reduced motion leaves no idle animation work")

        rapid.target = 1
        rapid.advance(by: 1.0 / 60)
        for invalid in [Double.nan, Double.infinity, -Double.infinity, -1, 0] {
            let before = rapid
            rapid.advance(by: invalid)
            expect(rapid.value == before.value && rapid.velocity == before.velocity,
                   "An invalid timestamp cannot move or corrupt the spring")
        }
        for invalid in [CGFloat.nan, CGFloat.infinity, -CGFloat.infinity] {
            let before = rapid
            rapid.target = invalid
            rapid.snap(to: invalid)
            expect(rapid.value == before.value && rapid.velocity == before.velocity
                   && rapid.target == before.target,
                   "Invalid destinations leave ongoing motion intact")
            let invalidSpring = RadialSpring(value: invalid, response: invalid, dampingRatio: invalid)
            expect(invalidSpring.value == 0 && invalidSpring.isSettled,
                   "Invalid construction values produce a usable resting spring")
        }
        for response: CGFloat in [-1, 0, 0.000001, 100] {
            for damping: CGFloat in [-1, 0, 100] {
                var extreme = RadialSpring(response: response, dampingRatio: damping)
                extreme.target = 1
                for _ in 0..<100 { extreme.advance(by: 0.1) }
                expect(extreme.value.isFinite && extreme.velocity.isFinite,
                       "Extreme configuration values are normalized to stable parameters")
            }
        }
        var huge = RadialSpring(value: -CGFloat.greatestFiniteMagnitude)
        huge.target = CGFloat.greatestFiniteMagnitude
        huge.advance(by: 0.01)
        expect(huge.value.isFinite && huge.velocity.isFinite,
               "Even overflow-sized finite input cannot leave nonfinite state")
        print("PASS: \(assertions) radial bubble motion assertions")
    }
}
