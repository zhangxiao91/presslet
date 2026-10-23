import Foundation

/// An interruptible scalar spring. Changing the target retains the current velocity.
struct RadialSpring {
    private(set) var value: CGFloat
    private(set) var velocity: CGFloat = 0
    private var destination: CGFloat
    let response: CGFloat
    let dampingRatio: CGFloat

    var target: CGFloat {
        get { destination }
        set {
            if newValue.isFinite { destination = newValue }
        }
    }

    var isSettled: Bool {
        abs(value - destination) <= 0.0001 && abs(velocity) <= 0.001
    }

    init(value: CGFloat = 0, response: CGFloat = 0.26,
         dampingRatio: CGFloat = 0.82) {
        let initial = value.isFinite ? value : 0
        self.value = initial
        destination = initial
        self.response = response.isFinite ? min(5, max(0.01, response)) : 0.26
        self.dampingRatio = dampingRatio.isFinite
            ? min(4, max(0.01, dampingRatio)) : 0.82
    }

    /// Uses the exact damped-oscillator solution instead of frame-dependent integration.
    @discardableResult
    mutating func advance(by delta: TimeInterval) -> Bool {
        guard delta.isFinite, delta > 0 else { return !isSettled }
        if isSettled {
            snap(to: destination)
            return false
        }

        // A suspended window can resume hours later. Its spring has already settled.
        if delta > Double(120 * response / dampingRatio) {
            snap(to: destination)
            return false
        }

        let t = CGFloat(delta)
        let omega = 2 * CGFloat.pi / response
        let zeta = dampingRatio
        let displacement = value - destination
        let initialVelocity = velocity
        let nextDisplacement: CGFloat
        let nextVelocity: CGFloat

        if abs(zeta - 1) < 0.00001 {
            let decay = exp(-omega * t)
            let coefficient = initialVelocity + omega * displacement
            nextDisplacement = decay * (displacement + coefficient * t)
            nextVelocity = decay * (initialVelocity - omega * coefficient * t)
        } else if zeta < 1 {
            let decayRate = zeta * omega
            let frequency = omega * sqrt(1 - zeta * zeta)
            let decay = exp(-decayRate * t)
            let cosine = cos(frequency * t)
            let sine = sin(frequency * t)
            nextDisplacement = decay * (displacement * cosine
                + (initialVelocity + decayRate * displacement) / frequency * sine)
            nextVelocity = decay * (initialVelocity * cosine
                - (decayRate * initialVelocity + omega * omega * displacement)
                / frequency * sine)
        } else {
            let root = sqrt(zeta * zeta - 1)
            let slowRate = -omega / (zeta + root)
            let fastRate = -omega * (zeta + root)
            let slowCoefficient = (initialVelocity - fastRate * displacement)
                / (slowRate - fastRate)
            let fastCoefficient = displacement - slowCoefficient
            let slow = slowCoefficient * exp(slowRate * t)
            let fast = fastCoefficient * exp(fastRate * t)
            nextDisplacement = slow + fast
            nextVelocity = slowRate * slow + fastRate * fast
        }

        let nextValue = destination + nextDisplacement
        guard nextValue.isFinite, nextVelocity.isFinite else {
            snap(to: destination)
            return false
        }
        value = nextValue
        velocity = nextVelocity
        if isSettled {
            snap(to: destination)
            return false
        }
        return true
    }

    /// Use for initial state and reduced motion; no residual momentum remains.
    mutating func snap(to newValue: CGFloat) {
        guard newValue.isFinite else { return }
        destination = newValue
        value = newValue
        velocity = 0
    }
}
