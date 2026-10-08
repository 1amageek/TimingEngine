/// Strict Liberty source intake; exact artifact identity remains caller-owned.
public protocol LibertySourceParsing: Sendable {
    func parseSource(_ bytes: borrowing Span<UInt8>, limits: LibertySourceParseLimits,
                     resources: any LibertySourceResourceAccounting)
        throws(LibertySourceError) -> OwnedLibertySource
}
