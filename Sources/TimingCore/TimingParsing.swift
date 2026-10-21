import Foundation

public protocol TimingLibraryParsing: Sendable {
    func parse(_ data: Data) throws -> TimingLibrary
}

public protocol TimingConstraintParsing: Sendable {
    func parse(_ data: Data, modeID: String) throws -> TimingConstraintSet
    func parse(_ data: Data, modeID: String, resources: any LibertySourceResourceAccounting)
        throws -> TimingTransformValue<TimingConstraintSet>
}

public protocol TimingDesignParsing: Sendable {
    func parse(_ data: Data, topDesignName: String) throws -> TimingDesign
    func parse(_ data: Data, topDesignName: String, resources: any LibertySourceResourceAccounting,
        json: any TimingBoundedJSONDecoding) throws -> TimingTransformValue<TimingDesign>
}

public protocol TimingParasiticParsing: Sendable {
    func parse(_ data: Data) throws -> TimingParasitics
    func parse(_ data: Data, resources: any LibertySourceResourceAccounting,
        json: any TimingBoundedJSONDecoding) throws -> TimingTransformValue<TimingParasitics>
}

public protocol TimingSDFParsing: Sendable {
    func parse(_ data: Data) throws -> TimingSDF
}
