import Foundation

/// Normalized stages also define the sound's tension/rip/release timing.
public struct ReceiptTearPose: Sendable {
    public let rip: Double
    public let curl: Double
    public let tilt: Double
    public let rotation: Double
    public let x: Double
    public let y: Double
    public let shadow: Double
    public let opacity: Double
    public init(progress: Double) {
        let p = min(1, max(0, progress.isFinite ? progress : 0))
        func smooth(_ value: Double) -> Double { let t = min(1, max(0, value)); return t * t * (3 - 2 * t) }
        let tension = smooth(p / 0.175)
        rip = smooth((p - 0.175) / 0.25)
        let fall = max(0, (p - 0.425) / 0.575)
        curl = sin(.pi * rip) * (1 - fall)
        tilt = tension * 3 + rip * 9 + fall * fall * 20
        rotation = tension * 0.6 + rip * 3 + fall * 5
        x = tension + rip * 4 + fall * fall * 18
        y = tension * 2 + rip * 5 + fall * fall * 200
        shadow = min(1, rip + fall)
        opacity = 1 - smooth((p - 0.72) / 0.28)
    }
}
