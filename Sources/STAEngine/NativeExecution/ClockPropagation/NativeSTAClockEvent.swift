import TimingCore

internal struct NativeSTAClockEvent {
    let clock: TimingConstraintSet.Clock
    let edge: TimingEdge
    let rootEdge: TimingEdge
    let rootPhase: Double
    let late: Double
    let early: Double
    let lateSlew: Double
    let earlySlew: Double
    let segments: [STAClockObservation.Segment]
}
