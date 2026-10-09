/// Native owner limits bound source transforms and scenario fan-out independently of Liberty accounting.
public struct STAExecutionLimits: Sendable, Hashable {
    public let maximumInputBytes: UInt64
    public let maximumScenarios: Int
    public let maximumDesignElements: Int
    public let maximumPaths: Int
    public init(maximumInputBytes: UInt64 = 1_048_576, maximumScenarios: Int = 32,
        maximumDesignElements: Int = 4096, maximumPaths: Int = 1000) throws(STAPreparationError) {
        guard maximumInputBytes > 0, maximumScenarios > 0, maximumDesignElements > 0, maximumPaths > 0 else {
            throw .capacity("Native STA limits must be positive")
        }
        self.maximumInputBytes = maximumInputBytes; self.maximumScenarios = maximumScenarios
        self.maximumDesignElements = maximumDesignElements; self.maximumPaths = maximumPaths
    }
}
