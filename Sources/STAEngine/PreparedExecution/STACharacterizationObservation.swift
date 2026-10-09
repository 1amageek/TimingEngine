import CircuiteFoundation

/// Raw numeric process remains unmapped; selected names exist only for explicit observation policy.
public struct STACharacterizationObservation: Sendable, Hashable, Codable {
    public let cornerID: String
    public let source: ArtifactReference
    public let conditionName: String
    public let numericProcess: Double?
    public let voltage: Double?
    public let temperatureCelsius: Double?
    public let selected: Bool
    internal init(cornerID: String, source: ArtifactReference, conditionName: String,
        numericProcess: Double?, voltage: Double?, temperatureCelsius: Double?, selected: Bool) {
        self.cornerID = cornerID; self.source = source; self.conditionName = conditionName
        self.numericProcess = numericProcess; self.voltage = voltage
        self.temperatureCelsius = temperatureCelsius; self.selected = selected
    }
}
