import TimingCore
internal struct STAPathAnalysisResult {
    let clockObservations: [STAClockObservation]
    let rcSteps: UInt64
    let wireCoverage: [STAWireCoverage]
    let wireObservations: [STADistributedRCObservation]
    let conservativeWireObservations: [STAConservativeWireObservation]
    let workUnits: UInt64
    let endpoints: [STAEndpoint]
    let unconstrainedEndpoints: [STAEndpoint]
    let paths: [STAPath]
    let violations: [STAViolation]
    let sourceCoverage: [STASourceEvidence.Coverage]
    let sourceSamples: [STASourceEvidence.Sample]
    let pulseWidthSamples: [STASourceEvidence.PulseWidthSample]
    let staticStateSamples: [STASourceEvidence.StaticStateSample]
    let normalPowerSamples: [STASourceEvidence.NormalPowerSample]
    let normalPowerOwners: [CheckedLibertyNormalPower]
}
