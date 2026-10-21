import Foundation

public extension TimingDesignParsing {
    func parse(_ data: Data, topDesignName: String,
        resources: any LibertySourceResourceAccounting, json: any TimingBoundedJSONDecoding)
        throws -> TimingTransformValue<TimingDesign> {
        throw TimingTransformError.unsupportedCapability("Design parser has no controlled transform")
    }
}
public extension TimingConstraintParsing {
    func parse(_ data: Data, modeID: String, resources: any LibertySourceResourceAccounting)
        throws -> TimingTransformValue<TimingConstraintSet> {
        throw TimingTransformError.unsupportedCapability("Constraint parser has no controlled transform")
    }
}
public extension TimingParasiticParsing {
    func parse(_ data: Data, resources: any LibertySourceResourceAccounting,
        json: any TimingBoundedJSONDecoding) throws -> TimingTransformValue<TimingParasitics> {
        throw TimingTransformError.unsupportedCapability("Parasitic parser has no controlled transform")
    }
}
public extension TimingParasiticReducing {
    func reduce(_ source: TimingParasitics, resources: any LibertySourceResourceAccounting)
        throws -> TimingTransformValue<TimingLumpedParasitics> {
        throw TimingTransformError.unsupportedCapability("Parasitic reducer has no controlled transform")
    }
}
