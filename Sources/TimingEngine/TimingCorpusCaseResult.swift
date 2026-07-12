import Foundation
import TimingCore
import XcircuitePackage

public struct TimingCorpusCaseResult: Sendable, Hashable, Codable {
    public var caseID: String
    public var expectedOutcome: TimingCorpusExpectedOutcome
    public var observedOutcome: TimingCorpusExpectedOutcome
    public var passed: Bool
    public var expectedDiagnosticCodes: [String]
    public var observedDiagnosticCodes: [String]
    public var missingExpectedDiagnosticCodes: [String]
    public var nativeWorstSetupSlack: Double?
    public var nativeWorstHoldSlack: Double?
    public var provenance: TimingArtifactProvenance
    public var correlation: TimingCorrelationResult?

    public init(
        caseID: String,
        expectedOutcome: TimingCorpusExpectedOutcome,
        observedOutcome: TimingCorpusExpectedOutcome,
        passed: Bool,
        expectedDiagnosticCodes: [String] = [],
        observedDiagnosticCodes: [String] = [],
        missingExpectedDiagnosticCodes: [String] = [],
        nativeWorstSetupSlack: Double? = nil,
        nativeWorstHoldSlack: Double? = nil,
        provenance: TimingArtifactProvenance = TimingArtifactProvenance(),
        correlation: TimingCorrelationResult? = nil
    ) {
        self.caseID = caseID
        self.expectedOutcome = expectedOutcome
        self.observedOutcome = observedOutcome
        self.passed = passed
        self.expectedDiagnosticCodes = expectedDiagnosticCodes
        self.observedDiagnosticCodes = observedDiagnosticCodes
        self.missingExpectedDiagnosticCodes = missingExpectedDiagnosticCodes
        self.nativeWorstSetupSlack = nativeWorstSetupSlack
        self.nativeWorstHoldSlack = nativeWorstHoldSlack
        self.provenance = provenance
        self.correlation = correlation
    }
}
