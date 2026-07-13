import Foundation

public protocol TimingPDKQualificationEvidenceBuilding: Sendable {
    func build(for pdk: TimingPDKReference) throws -> TimingPDKQualificationEvidence
}
