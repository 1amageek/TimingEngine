import TimingCore

internal struct NativeSTAClockEvent: Sendable {
    let clock: TimingConstraintSet.Clock
    let edge: TimingEdge
    let rootEdge: TimingEdge
    let rootPhase: Double
    let late: Double
    let early: Double
    let lateSlew: Double
    let earlySlew: Double
    let segments: [STAClockObservation.Segment]
    let segmentPayload: LibertySourceStorageReservation?
    let textRetention: NativeSTATransformRetention?
    init(clock: TimingConstraintSet.Clock, edge: TimingEdge, rootEdge: TimingEdge, rootPhase: Double,
        late: Double, early: Double, lateSlew: Double, earlySlew: Double, segments: [STAClockObservation.Segment],
        segmentPayload: LibertySourceStorageReservation? = nil, textRetention: NativeSTATransformRetention? = nil) {
        self.clock = clock; self.edge = edge; self.rootEdge = rootEdge; self.rootPhase = rootPhase
        self.late = late; self.early = early; self.lateSlew = lateSlew; self.earlySlew = earlySlew
        self.segments = segments; self.segmentPayload = segmentPayload; self.textRetention = textRetention
    }
}
