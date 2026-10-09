public struct STACharacterizationBinding: Sendable, Hashable, Codable {
    public let cornerID: String
    public let conditionName: String
    public let requiredNumericProcess: Double?
    public init(cornerID: String, conditionName: String, requiredNumericProcess: Double? = nil) {
        self.cornerID = cornerID; self.conditionName = conditionName; self.requiredNumericProcess = requiredNumericProcess
    }
}
