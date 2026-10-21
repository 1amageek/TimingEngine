import Foundation
import PDKCore
import PDKDiscovery
import TimingCore

/// Audited Timing schema specialization of the existing PDK raw-byte decoder.
internal struct NativeSTABoundedJSONDecoder: TimingBoundedJSONDecoding {
    let maximumNesting: Int

    func decodeDesign(_ data: Data, resources: any LibertySourceResourceAccounting)
        throws -> TimingTransformValue<TimingDesign> {
        let accounting = try NativeSTAPDKAccounting(resources: resources, maximumNesting: maximumNesting)
        do {
            let document = try data.withUnsafeBytes { raw in
                // Data owns initialized byte storage; the typed borrow stays in
                // this synchronous closure. No pointer is retained by the decoder.
                try NativePDKBoundedDocumentDecoder().decodeAudited(TimingDesign.self,
                    bytes: raw.bindMemory(to: UInt8.self).span, accounting: accounting,
                    rejectUnknownFields: false) { decoder in
                        let fields = try decoder.container(keyedBy: DesignKey.self)
                        let version = try fields.decode(Int.self, forKey: .schemaVersion)
                        if version == 1 {
                            // TimingDesign's custom v1 admission scans these two
                            // arrays with allSatisfy; charge those visits before init.
                            let ports = try fields.nestedUnkeyedContainer(forKey: .ports)
                            let nets = try fields.nestedUnkeyedContainer(forKey: .nets)
                            guard let portCount = ports.count, let netCount = nets.count else {
                                throw TimingTransformError.unsupportedCapability("Audited JSON array count is unavailable")
                            }
                            let count = portCount.addingReportingOverflow(netCount)
                            guard !count.overflow else { throw LibertySourceError.arithmeticOverflow }
                            if count.partialValue > 0 {
                                try accounting.charge(.init(dimension: .parserWork,
                                    amount: UInt64(count.partialValue)))
                            }
                        }
                    }
            }
            try resources.check()
            guard document.value.schemaVersion == TimingDesign.currentSchemaVersion else {
                throw TimingError.invalidInput("Unsupported timing design schema version")
            }
            return try TimingTransformValue(value: document.value, retaining: document,
                resources: resources)
        } catch { throw accounting.preservingCause(error) }
    }

    func decodeParasitics(_ data: Data, resources: any LibertySourceResourceAccounting)
        throws -> TimingTransformValue<TimingParasitics> {
        let accounting = try NativeSTAPDKAccounting(resources: resources, maximumNesting: maximumNesting)
        do {
            let document = try data.withUnsafeBytes { raw in
                try NativePDKBoundedDocumentDecoder().decodeAudited(TimingParasitics.self,
                    bytes: raw.bindMemory(to: UInt8.self).span, accounting: accounting,
                    rejectUnknownFields: false) { decoder in
                        // The custom root/network Decodable initializers only
                        // decode fields and apply static empty/colon defaults;
                        // they construct no derived collection or normalization.
                        let fields = try decoder.container(keyedBy: ParasiticKey.self)
                        let networks = try fields.nestedUnkeyedContainer(forKey: .networks)
                        guard let networkCount = networks.count else {
                            throw TimingTransformError.unsupportedCapability("Audited JSON array count is unavailable")
                        }
                        let count = networkCount.addingReportingOverflow(1)
                        guard !count.overflow else { throw LibertySourceError.arithmeticOverflow }
                        try accounting.charge(.init(dimension: .parserWork,
                            amount: UInt64(count.partialValue)))
                    }
            }
            try resources.check()
            return try TimingTransformValue(value: document.value, retaining: document,
                resources: resources)
        } catch { throw accounting.preservingCause(error) }
    }

    private enum DesignKey: String, CodingKey { case schemaVersion, ports, nets }
    private enum ParasiticKey: String, CodingKey { case networks }
}
