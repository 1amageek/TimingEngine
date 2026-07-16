import Foundation

public protocol TimingPDKEvidenceBuilding: Sendable {
    func build(for pdk: TimingPDKReference) throws -> TimingPDKEvidence
}
