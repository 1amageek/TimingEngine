import CircuiteFoundation

/// Native graph-selected library objects; retained independently from requested PDK mappings.
public struct STALibraryConsumption: Sendable, Hashable, Codable {
    public let cornerID: String
    public let source: ArtifactReference
    public let cellNames: [String]
    public let pinNames: [String]
    public let conditionNames: [String]
    internal init(cornerID: String, source: ArtifactReference, cellNames: [String], pinNames: [String], conditionNames: [String]) {
        self.cornerID = cornerID; self.source = source; self.cellNames = cellNames
        self.pinNames = pinNames; self.conditionNames = conditionNames
    }
}
