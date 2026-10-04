import Foundation
import STAEngine
import Testing

@Suite("STA process and corner admission")
struct STAProcessCornerTests {
    @Test("each exact corner uses its own Liberty delay and retains process/PVT identity")
    func usesDistinctCornerLibraries() async throws {
        let fixture = try STAProcessTestFixture()
        let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        #expect(result.status == .completed)
        #expect(result.payload.analyzedCorners == ["typical", "slow"])
        let typical = try #require(result.payload.endpoints.first { $0.cornerID == "typical" }?.setupSlack)
        let slow = try #require(result.payload.endpoints.first { $0.cornerID == "slow" }?.setupSlack)
        #expect(abs(typical - 6e-9) < 1e-20)
        #expect(abs(slow - 4e-9) < 1e-20)
        let selection = try #require(result.payload.processSelection)
        #expect(selection.processID == "test")
        #expect(selection.pdkVersion == "1")
        #expect(selection.manifest == fixture.request.pdkManifest.reference)
        #expect(selection.corners.map(\.cornerID) == ["typical", "slow"])
        #expect(selection.corners.allSatisfy { $0.pvt.voltage == 1 && $0.pvt.temperatureCelsius == 25 })
        #expect(selection.librariesByCorner["typical"] == fixture.request.libraries[0].artifact.reference)
        #expect(selection.librariesByCorner["slow"] == fixture.request.libraries[1].artifact.reference)
        #expect(try JSONDecoder().decode(STAExecutionResult.self, from: JSONEncoder().encode(result)) == result)
    }

    @Test("explicit subset selection retains only the exact requested corner")
    func usesRequestedSubset() async throws {
        let fixture = try STAProcessTestFixture(selectedCorners: ["slow"])
        let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        #expect(result.status == .completed)
        #expect(result.payload.analyzedCorners == ["slow"])
        #expect(result.payload.processSelection?.corners.map(\.cornerID) == ["slow"])
        #expect(result.payload.processSelection?.librariesByCorner.keys.sorted() == ["slow"])
        #expect(abs(try #require(result.payload.worstSetupSlack) - 4e-9) < 1e-20)
    }

    @Test("missing and mismatched process/corner inputs block without a report", arguments: [
        "process", "version", "missing-selection", "unknown-selection", "unknown-source-corner",
        "missing-source-corner", "duplicate-source-corner", "missing-digest", "wrong-digest",
        "missing-size", "wrong-size", "missing-view", "missing-cross-view", "nonmember-view",
        "wrong-format", "invalid-pvt", "duplicate-manifest-corner", "malformed",
        "ambiguous-source", "missing-library"
    ])
    func rejectsProcessMismatch(_ failure: String) async throws {
        let fixture = try STAProcessTestFixture(failure: failure)
        let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        #expect(result.status == .blocked)
        #expect(result.payload.worstSetupSlack == nil)
        #expect(result.payload.analyzedCorners.isEmpty)
        #expect(result.payload.processSelection == nil)
        #expect(result.artifactBindings.isEmpty)
        #expect(result.diagnostics.first?.code.rawValue == (failure == "malformed"
            ? "timing.sta.parse_failed" : "timing.sta.invalid_input"))
    }
}
