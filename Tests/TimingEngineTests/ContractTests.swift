import Testing
@testable import TimingCore
@testable import STAEngine
@testable import SignalIntegrityEngine
@testable import TimingEngine

@Suite("TimingEngine contract")
struct ContractTests {
    @Test("contract version starts at one")
    func contractVersion() {
        #expect(TimingEngineAPI.contractVersion == 1)
        #expect(TimingEngineService().corpus is LocalTimingCorpusRunner)
        #expect(TimingEngineService().foundationSTA is NativeSTAFoundationEngine)
        #expect(TimingEngineService().foundationSignalIntegrity is NativeSignalIntegrityFoundationEngine)
    }
}
