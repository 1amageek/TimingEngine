import CircuiteFoundation
import PDKProfileAdmission
import TimingCore

/// Immutable catalog retains the checked capture, grammar and accounting owners.
public struct TimingInspectedLibertySources: Sendable {
    internal struct Entry: Sendable {
        let input: PDKProfileSourceInput
        let policyIdentity: String
        let source: OwnedLibertySource
    }
    internal let entries: [Entry]
    public let admittedProfile: AdmittedPDKProfile
    public var sourceInputs: PDKAdmissionCollection<PDKProfileSourceInput> { admittedProfile.sourceInputs }
    internal let owners: [LibertySourceStorageReservation]
    internal init(entries: [Entry], owners: [LibertySourceStorageReservation], admitted: AdmittedPDKProfile) { self.entries = entries; self.owners = owners; admittedProfile = admitted }
    public var references: [ArtifactReference] { entries.map { $0.input.reference } }
    public static let parserIdentity = "timing.liberty.owned.v1"
    public func source(for reference: ArtifactReference) throws(TimingProfileInspectionError) -> OwnedLibertySource {
        guard let entry = entries.first(where: { $0.input.reference == reference }) else { throw .unadmittedSource }
        return entry.source
    }
}
