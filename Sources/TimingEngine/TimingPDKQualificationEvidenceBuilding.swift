import Foundation
import PDKCore

public protocol TimingPDKQualificationEvidenceBuilding: Sendable {
    func build(for pdk: PDKReference) throws -> TimingPDKQualificationEvidence
}
