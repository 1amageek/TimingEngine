import Foundation
import Testing
@testable import TimingCore

@Suite("Controlled JSON publication")
struct ControlledJSONEncodingTests {
    private struct Fixture: Encodable {
        let text: String
        let numbers: [Double]
        let integers: [Int]
        let nested: [[String?]]
    }

    @Test(arguments: [false, true])
    func actualFoundationBytesFitGrammarAndLastCopyOwnsPayload(pretty: Bool) throws {
        let resources = LibertyCodecTestResources(maximumLiveBytes: 2_000_000,
            maximumTemporaryBytes: 100_000, maximumWork: 2_000_000)
        let fixture = Fixture(text: String(repeating: "/\\\"\n\u{0}\u{2028}あ", count: 128),
            numbers: [.leastNonzeroMagnitude, -.greatestFiniteMagnitude, -0.0, 1],
            integers: [.min, .max], nested: [[], [nil, "value"]])
        let formatting: JSONEncoder.OutputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        let encoder = JSONEncoder(); encoder.outputFormatting = formatting
        let expected = try encoder.encode(fixture)
        var first: TimingTransformValue<Data>? = try TimingJSONEncoding.encode(fixture, formatting: formatting, resources: resources)
        #expect(first?.value == expected)
        var copy = first
        first = nil
        #expect(copy?.value == expected)
        #expect(resources.liveBytes > 0)
        copy = nil
        #expect(resources.liveBytes == 0)
        #expect(resources.temporaryBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test func exactStaticPrefixAndBothSimultaneousBuffers() throws {
        let resources = LibertyCodecTestResources(maximumLiveBytes: 100_000,
            maximumTemporaryBytes: 100_000, maximumWork: 100_000)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var expected = Data("timing.sta.execution.inputs.v1\0".utf8)
        expected.append(try encoder.encode(["a/b", "x"]))
        do {
            let result = try TimingJSONEncoding.encode(["a/b", "x"], prefix: "timing.sta.execution.inputs.v1\0",
                formatting: [.sortedKeys], resources: resources)
            #expect(result.value == expected)
            #expect(resources.liveBytes > 0)
        }
        #expect(resources.liveBytes == 0)
        #expect(resources.temporaryBytes == 0)
    }

    @Test func workAndStorageRefuseWithoutOutputAndRefund() throws {
        for resources in [
            LibertyCodecTestResources(maximumLiveBytes: 1, maximumTemporaryBytes: 100_000, maximumWork: 100_000),
            LibertyCodecTestResources(maximumLiveBytes: 100_000, maximumTemporaryBytes: 100_000, maximumWork: 1)
        ] {
            do {
                _ = try TimingJSONEncoding.encode(["bounded"], formatting: [.sortedKeys], resources: resources)
                Issue.record("Expected original caller refusal")
            } catch let error as LibertyCodecTestResources.Failure {
                switch error {
                case .quota(.liveOwnedBytes), .work: break
                default: Issue.record("Unexpected caller refusal: \(error)")
                }
            }
            #expect(resources.liveBytes == 0)
            #expect(resources.temporaryBytes == 0)
        }
    }

    @Test func nonfiniteFailureRemainsFoundationFailure() throws {
        let resources = LibertyCodecTestResources(maximumLiveBytes: 100_000,
            maximumTemporaryBytes: 100_000, maximumWork: 100_000)
        do {
            _ = try TimingJSONEncoding.encode([Double.infinity], formatting: [.sortedKeys], resources: resources)
            Issue.record("Expected original nonfinite JSON refusal")
        } catch is EncodingError {}
        #expect(resources.liveBytes == 0)
        #expect(resources.temporaryBytes == 0)
    }
}
