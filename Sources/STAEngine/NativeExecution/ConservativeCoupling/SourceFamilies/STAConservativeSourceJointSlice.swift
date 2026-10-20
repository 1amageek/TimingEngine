import TimingCore

/// Outer projections of one retained family; Cartesian combinations need not be realizable.
public struct STAConservativeSourceJointSlice: Sendable {
    public var contextRecord: STAConservativeSourceContextRecord { context.record }
    public let sourceIndex: Int
    public let initialTimeSI: ClosedRange<Double>
    public let windowSI: ClosedRange<Double>
    public let initialValue: ClosedRange<Double>
    public let windowValue: ClosedRange<Double>
    /// Normalized derivative per SI second, almost everywhere; no side-limit assertion.
    public let almostEverywhereSlope: ClosedRange<Double>
    private let context: STAConservativeSourceContext
    private let lease: LibertySourceStorageReservation

    private init(context: STAConservativeSourceContext, sourceIndex: Int,
        initialTimeSI: ClosedRange<Double>, windowSI: ClosedRange<Double>,
        initialValue: ClosedRange<Double>, windowValue: ClosedRange<Double>,
        almostEverywhereSlope: ClosedRange<Double>, lease: LibertySourceStorageReservation) {
        self.context = context; self.sourceIndex = sourceIndex
        self.initialTimeSI = initialTimeSI; self.windowSI = windowSI
        self.initialValue = initialValue; self.windowValue = windowValue
        self.almostEverywhereSlope = almostEverywhereSlope; self.lease = lease
    }

    // Only the checked-context factory supplies projections and its preadmitted lease.
    internal static func checkedProjection(context: STAConservativeSourceContext, sourceIndex: Int,
        initialTimeSI: ClosedRange<Double>, windowSI: ClosedRange<Double>,
        initialValue: ClosedRange<Double>, windowValue: ClosedRange<Double>,
        almostEverywhereSlope: ClosedRange<Double>, lease: LibertySourceStorageReservation) -> Self {
        Self(context: context, sourceIndex: sourceIndex, initialTimeSI: initialTimeSI,
            windowSI: windowSI, initialValue: initialValue, windowValue: windowValue,
            almostEverywhereSlope: almostEverywhereSlope, lease: lease)
    }
}
