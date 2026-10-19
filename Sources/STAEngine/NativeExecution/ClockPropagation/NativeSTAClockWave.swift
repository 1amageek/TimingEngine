import TimingCore

internal struct NativeSTAClockWave {
    let rise: NativeSTAClockEvent
    let fall: NativeSTAClockEvent
    func event(_ edge: TimingEdge) -> NativeSTAClockEvent { edge == .rise ? rise : fall }
    var lateSource: STAPeriodicRCSource {
        .init(period: rise.clock.period, risePhase: rise.late, fallPhase: fall.late, riseSlew: rise.lateSlew, fallSlew: fall.lateSlew)
    }
    var earlySource: STAPeriodicRCSource {
        .init(period: rise.clock.period, risePhase: rise.early, fallPhase: fall.early, riseSlew: rise.earlySlew, fallSlew: fall.earlySlew)
    }
}
