/// Explicit Liberty threshold percentages. These values do not confer signoff qualification.
public struct TimingCharacterizationThresholds: Sendable, Equatable {
    public let inputRise: Double
    public let inputFall: Double
    public let outputRise: Double
    public let outputFall: Double
    public let slewLowerRise: Double
    public let slewUpperRise: Double
    public let slewLowerFall: Double
    public let slewUpperFall: Double

    package init(
        inputRise: Double, inputFall: Double, outputRise: Double, outputFall: Double,
        slewLowerRise: Double, slewUpperRise: Double, slewLowerFall: Double, slewUpperFall: Double
    ) {
        self.inputRise = inputRise
        self.inputFall = inputFall
        self.outputRise = outputRise
        self.outputFall = outputFall
        self.slewLowerRise = slewLowerRise
        self.slewUpperRise = slewUpperRise
        self.slewLowerFall = slewLowerFall
        self.slewUpperFall = slewUpperFall
    }
}
