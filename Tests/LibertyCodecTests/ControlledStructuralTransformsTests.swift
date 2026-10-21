import Foundation
import Testing
@testable import TimingCore

@Suite("Controlled structural timing transforms")
struct ControlledStructuralTransformsTests {
    private struct NoJSON: TimingBoundedJSONDecoding {
        func decodeDesign(_ data: Data, resources: any LibertySourceResourceAccounting) throws -> TimingTransformValue<TimingDesign> {
            throw TimingTransformError.unsupportedCapability("Unexpected JSON route")
        }
        func decodeParasitics(_ data: Data, resources: any LibertySourceResourceAccounting) throws -> TimingTransformValue<TimingParasitics> {
            throw TimingTransformError.unsupportedCapability("Unexpected JSON route")
        }
    }

    private let spef = Data("""
    *SPEF "IEEE 1481-1998"
    *C_UNIT 1 PF
    *R_UNIT 1 OHM
    *NAME_MAP
    *1 a
    *2 b
    *D_NET *1 2
    *CONN
    *P *1 I
    *CAP
    1 *1 1
    2 *1 *2 1
    *RES
    1 *1 *1:1 2
    *END
    *D_NET *2 1
    *CONN
    *P *2 O
    *CAP
    1 *2 *1 1
    *END
    """.utf8)

    @Test func actualSPEFAndReductionMatchLegacyWithCopiedOwner() throws {
        let resources = LibertyCodecTestResources(maximumLiveBytes: 4_000_000,
            maximumTemporaryBytes: 4_000_000, maximumWork: 2_000_000)
        let expected = try SPEFParser().parse(spef)
        let expectedReduction = try EquipotentialTimingParasiticReducer().reduce(expected)
        do {
            var parsed: TimingTransformValue<TimingParasitics>? = try SPEFParser().parse(spef, resources: resources, json: NoJSON())
            #expect(parsed?.value == expected)
            var copy = parsed; parsed = nil
            let reduction = try EquipotentialTimingParasiticReducer().reduce(try #require(copy?.value), resources: resources)
            #expect(reduction.value == expectedReduction)
            #expect(reduction.value.evidence.mirroredSourceGroups.count == 1)
            #expect(resources.liveBytes > 0)
            copy = nil
            withExtendedLifetime(reduction) {}
        }
        #expect(resources.liveBytes == 0)
        #expect(resources.temporaryBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test func controlledVerilogPreservesConnectionsAndExactNetText() throws {
        let bytes = Data("module top(input a, output z); wire long_net; BUF u0 (.A(a), .Y(long_net)); BUF u1 (.A(long_net), .Y(z)); endmodule".utf8)
        let resources = LibertyCodecTestResources(maximumLiveBytes: 4_000_000,
            maximumTemporaryBytes: 4_000_000, maximumWork: 2_000_000)
        let expected = try TimingDesignParser().parse(bytes, topDesignName: "top")
        do {
            let actual = try TimingDesignParser().parse(bytes, topDesignName: "top", resources: resources, json: NoJSON())
            #expect(actual.value == expected)
            #expect(actual.value.instances[0].connections["Y"] == "long_net")
        }
        #expect(resources.liveBytes == 0)
        #expect(resources.temporaryBytes == 0)
    }

    @Test func sourceFailureKeepsRichTextAndLeaseUntilLastCopy() throws {
        let bytes = Data("module top; BUF source_instance (.A()); endmodule".utf8)
        let resources = LibertyCodecTestResources(maximumLiveBytes: 1_000_000,
            maximumTemporaryBytes: 1_000_000, maximumWork: 1_000_000)
        var held: TimingControlledTransformFailure?
        do {
            _ = try TimingDesignParser().parse(bytes, topDesignName: "top", resources: resources, json: NoJSON())
            Issue.record("Expected original no-connection failure")
        } catch let error as TimingControlledTransformFailure { held = error }
        var copy = held; held = nil
        let cause = try #require(copy?.cause as? TimingError)
        guard case .parseFailure(_, _, let message) = cause else { Issue.record("Expected original rich parse error"); return }
        #expect(message == "Cell instance 'source_instance' has no connections.")
        #expect(resources.liveBytes > 0)
        copy = nil
        #expect(resources.liveBytes == 0)
        #expect(resources.temporaryBytes == 0)
    }
}
