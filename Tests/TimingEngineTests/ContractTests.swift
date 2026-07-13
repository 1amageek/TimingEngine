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
        #expect(TimingEngineService().sta is NativeSTAEngine)
        #expect(TimingEngineService().signalIntegrity is NativeSignalIntegrityEngine)
        #expect(TimingEngineAPI.nativeCapabilities.first?.supportedInputFormats.contains { $0.rawValue == "sdc" } == true)
        #expect(TimingEngineAPI.nativeCapabilities.first?.supportedOutputFormats == [.json])
    }
}
