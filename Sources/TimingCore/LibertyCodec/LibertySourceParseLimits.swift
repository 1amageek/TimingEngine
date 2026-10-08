/// Caller-selected grammar stack bound; no implicit production quota.
public struct LibertySourceParseLimits: Sendable, Hashable {
    public let maximumNestingDepth: Int
    public init(maximumNestingDepth: Int) throws(LibertySourceError) {
        guard maximumNestingDepth > 0 else { throw .invalidLimit }
        self.maximumNestingDepth = maximumNestingDepth
    }
}
