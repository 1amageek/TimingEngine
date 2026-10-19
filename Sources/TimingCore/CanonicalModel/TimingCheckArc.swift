import Foundation

/// Source-bound sequential constraint; both table axes are transition times.
public struct TimingCheckArc: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable { case setup, hold, recovery, removal }
    public let kind: Kind
    public let constrainedPin: String
    public let relatedPin: String
    public let relatedEdge: TimingEdge
    public let constrainedEdge: TimingEdge
    public let table: TimingLUT
    public let sourceIdentity: LibertyTimingSourceIdentity?

    public init(kind: Kind, constrainedPin: String, relatedPin: String, relatedEdge: TimingEdge,
                constrainedEdge: TimingEdge, table: TimingLUT, sourceIdentity: LibertyTimingSourceIdentity? = nil) {
        self.kind = kind; self.constrainedPin = constrainedPin; self.relatedPin = relatedPin
        self.relatedEdge = relatedEdge; self.constrainedEdge = constrainedEdge; self.table = table
        self.sourceIdentity = sourceIdentity
    }

    public func value(constrainedSlew: Double, relatedSlew: Double) throws -> Double {
        guard constrainedSlew.isFinite, constrainedSlew >= 0, relatedSlew.isFinite, relatedSlew >= 0 else {
            throw TimingError.invalidInput("Invalid sequential constraint slew")
        }
        let value = table.lookup(inputSlew: constrainedSlew, outputLoad: relatedSlew)
        guard value.isFinite else { throw TimingError.invalidInput("Nonfinite sequential constraint") }
        return value
    }
}
