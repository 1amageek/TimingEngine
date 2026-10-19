/// Native owner limits bound source transforms and scenario fan-out independently of Liberty accounting.
public struct STAExecutionLimits: Sendable, Hashable {
    public let maximumInputBytes: UInt64
    public let maximumScenarios: Int
    public let maximumDesignElements: Int
    public let maximumPaths: Int
    /// Bounds route/static state; distributed mode also bounds cumulative clock/data/scenario construction slots.
    public let maximumPathStates: Int
    public let maximumPathWorkUnits: UInt64
    public init(maximumInputBytes: UInt64 = 1_048_576, maximumScenarios: Int = 32,
        maximumDesignElements: Int = 4096, maximumPaths: Int = 1000, maximumPathStates: Int = 100_000, maximumPathWorkUnits: UInt64 = 100_000_000) throws(STAPreparationError) {
        guard maximumInputBytes > 0, maximumScenarios > 0, maximumDesignElements > 0, maximumPaths > 0, maximumPathStates > 0, maximumPathWorkUnits > 0 else {
            throw .capacity("Native STA limits must be positive")
        }
        self.maximumInputBytes = maximumInputBytes; self.maximumScenarios = maximumScenarios
        self.maximumDesignElements = maximumDesignElements; self.maximumPaths = maximumPaths
        self.maximumPathStates = maximumPathStates; self.maximumPathWorkUnits = maximumPathWorkUnits
    }
}
