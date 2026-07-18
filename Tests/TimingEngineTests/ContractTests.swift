import Foundation
import Testing
@testable import TimingCore
@testable import STAEngine
@testable import SignalIntegrityEngine
@testable import TimingEngine

@Suite("TimingEngine contract")
struct ContractTests {
    @Test("native service exposes concrete engines and versioned capabilities")
    func nativeServiceContract() throws {
        #expect(TimingEngineService().corpus is LocalTimingCorpusRunner)
        #expect(TimingEngineService().sta is NativeSTAEngine)
        #expect(TimingEngineService().signalIntegrity is NativeSignalIntegrityEngine)
        #expect(TimingEngineService.nativeCapabilities.first?.schemaVersion == TimingCapability.currentSchemaVersion)
        #expect(TimingEngineService.nativeCapabilities.first?.supportedInputFormats.contains { $0.rawValue == "sdc" } == true)
        #expect(TimingEngineService.nativeCapabilities.first?.supportedOutputFormats == [.json])

        let encoded = try JSONEncoder().encode(NativeSTAEngine.capability)
        let decoded = try JSONDecoder().decode(TimingCapability.self, from: encoded)
        #expect(decoded == NativeSTAEngine.capability)

        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == TimingCapability.currentSchemaVersion)
        object["schemaVersion"] = TimingCapability.currentSchemaVersion + 1
        let unsupported = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TimingCapability.self, from: unsupported)
        }
    }
}
