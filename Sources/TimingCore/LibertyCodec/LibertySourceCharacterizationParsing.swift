/// Strict source-backed NLDM admission using the caller's cumulative resource owner.
public protocol LibertySourceCharacterizationParsing: Sendable {
    func parseCharacterizedSource(_ bytes: borrowing Span<UInt8>, cellNames: [String], propagationCellNames: [String], sequentialPropagationCellNames: [String],
                                  limits: LibertySourceParseLimits, resources: any LibertySourceResourceAccounting)
        throws(LibertySourceError) -> CharacterizedTimingLibrary
}
