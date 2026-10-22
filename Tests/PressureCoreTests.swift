import Foundation

@main
struct TestRunner {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool,
                       _ message: String, line: Int = #line) {
        assertions += 1
        guard condition() else {
            fputs("FAIL line \(line): \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        var cycle = PressureCycle()
        expect(!cycle.accept(.mouseDown), "Ordinary mouse down is not deep")
        expect(!cycle.accept(.pressure(stage: 1, value: 1)), "Stage 1 is not deep")
        expect(cycle.accept(.pressure(stage: 2, value: 0.1)), "Stage, not a pressure threshold, identifies deep")
        expect(cycle.isDeep, "Deep state remains held")
        for _ in 0..<100 {
            expect(!cycle.accept(.pressure(stage: 2, value: 0.9)), "A held deep press fires only once")
        }
        expect(!cycle.accept(.mouseDown), "Repeated down does not rearm a held press")
        expect(!cycle.accept(.pressure(stage: 1, value: 0.1)), "Dropping to stage 1 does not end a press")
        expect(!cycle.accept(.pressure(stage: 2, value: 1)), "Stage oscillation does not fire twice")
        expect(!cycle.accept(.pressure(stage: 0, value: 0)), "Stage 0 ends a press")
        expect(!cycle.isDeep, "Stage 0 clears deep state")
        expect(cycle.accept(.pressure(stage: 2, value: 0)), "A new deep press may begin at any valid pressure")
        expect(!cycle.accept(.mouseUp), "Mouse up does not trigger")
        expect(!cycle.isDeep, "Mouse up clears deep state")

        for _ in 0..<30 {
            expect(!cycle.accept(.mouseDown), "Ordinary down is harmless")
            expect(!cycle.accept(.mouseUp), "Ordinary click never triggers deep")
            expect(cycle.accept(.pressure(stage: 2, value: 0.5)), "Consecutive independent deep cycles work")
            _ = cycle.accept(.mouseUp)
        }

        _ = cycle.accept(.pressure(stage: 2, value: 0.4))
        _ = cycle.accept(.cancel)
        expect(!cycle.isDeep, "Cancel clears deep state")
        expect(!cycle.accept(.pressure(stage: 2, value: 0.4)), "Cancel requires a release")
        _ = cycle.accept(.mouseUp)
        expect(cycle.accept(.pressure(stage: 2, value: 0.4)), "A release rearms after cancel")

        cycle.setEnabled(false)
        expect(!cycle.isEnabled && !cycle.isDeep, "Disabling clears the held state")
        expect(!cycle.accept(.pressure(stage: 2, value: 0.4)), "Disabled input never triggers")
        cycle.setEnabled(true)
        expect(!cycle.accept(.pressure(stage: 2, value: 0.4)), "Enabling while held never triggers")
        _ = cycle.accept(.pressure(stage: 0, value: 0))
        expect(cycle.accept(.pressure(stage: 2, value: 0.4)), "Release rearms after disabling")
        cycle.setEnabled(false)
        _ = cycle.accept(.mouseUp)
        cycle.setEnabled(true)
        expect(cycle.accept(.pressure(stage: 2, value: 0.4)), "Release can be observed while disabled")

        for bad in [PressureInput.pressure(stage: -1, value: 0.5),
                    .pressure(stage: 2, value: .nan),
                    .pressure(stage: 2, value: .infinity),
                    .pressure(stage: 2, value: -.infinity),
                    .pressure(stage: 2, value: -0.1),
                    .pressure(stage: 2, value: 1.1)] {
            _ = cycle.accept(.mouseUp)
            expect(!cycle.accept(bad), "Malformed input never triggers")
            expect(!cycle.isDeep, "Malformed input clears deep state")
            expect(!cycle.accept(.pressure(stage: 2, value: 0.5)), "Malformed input requires release")
            _ = cycle.accept(.mouseUp)
            expect(cycle.accept(.pressure(stage: 2, value: 0.5)), "Valid cycles recover after malformed input")
        }

        var tap = PressureCycle(source: "tap")
        for stage in [0, 1, 2, 3] {
            expect(!tap.accept(.pressure(stage: stage, value: 0.8)), "Tap pressure cannot establish a deep stage")
        }
        expect(!tap.isDeep, "Tap observation remains non-deep")
        var local = PressureCycle(source: "local")
        var global = PressureCycle(source: "global")
        expect(local.accept(.pressure(stage: 2, value: 0.3)), "Local source can identify a deep stage")
        expect(global.accept(.pressure(stage: 2, value: 0.3)), "Global cycles maintain independent state")
        _ = local.accept(.mouseUp)
        expect(global.isDeep, "Releasing local does not release global")

        var startup = PressureCycle(source: "global")
        _ = startup.accept(.cancel)
        expect(!startup.accept(.pressure(stage: 2, value: 0.6)), "Startup cancel rejects an already-held press")
        _ = startup.accept(.mouseDown)
        expect(!startup.accept(.pressure(stage: 1, value: 0.6)), "A fresh first down begins at stage 1")
        expect(startup.accept(.pressure(stage: 2, value: 0.6)), "First full press works after startup cancel")

        _ = startup.accept(.cancel)
        _ = startup.accept(.mouseDown)
        expect(startup.accept(.pressure(stage: 2, value: 0.6)), "A new down works after an app-switch cancel")
        startup.setEnabled(false)
        // The corresponding up may occur outside this observer's scope.
        startup.setEnabled(true)
        expect(!startup.accept(.pressure(stage: 2, value: 0.6)), "Resume still rejects an already-held press")
        _ = startup.accept(.mouseDown)
        expect(startup.accept(.pressure(stage: 2, value: 0.6)), "A fresh down recovers after a missed up while paused")
        _ = startup.accept(.mouseDown)
        expect(!startup.accept(.pressure(stage: 2, value: 0.6)), "Repeated down still cannot duplicate a deep cycle")
        print("PASS: \(assertions) pressure-cycle assertions")
    }
}
