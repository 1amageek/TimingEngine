public struct TimingCanonicalValidationReport: Sendable, Hashable {
    public let findings: [TimingCanonicalValidationFinding]

    public init(findings: [TimingCanonicalValidationFinding]) {
        self.findings = findings
    }

    public var isValid: Bool {
        findings.isEmpty
    }
}
