import CircuiteFoundation
import TimingCore

/// An explicit caller condition, not measured voltage or electrical qualification.
public struct STAOperatingSupplyAssumption: Sendable, Hashable, Codable {
    public let instance: String
    public let cell: String
    public let cornerID: String
    public let library: ArtifactReference
    public let pin: String
    public let sourcePGType: String
    public let value: TimingDesign.Constant

    public init(instance: String, cell: String, cornerID: String, library: ArtifactReference,
                pin: String, sourcePGType: String, value: TimingDesign.Constant) throws {
        guard [instance, cell, cornerID, pin, sourcePGType].allSatisfy({ !$0.isEmpty }) else {
            throw TimingError.invalidInput("Operating supply assumptions require exact nonempty source identities")
        }
        self.instance = instance; self.cell = cell; self.cornerID = cornerID; self.library = library
        self.pin = pin; self.sourcePGType = sourcePGType; self.value = value
    }
}
