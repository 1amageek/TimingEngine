import Foundation
import PDKProfileAdmission
import PDKCore
import Testing
import TimingCore
import TimingPDKProfileInspection

struct InspectionBehaviorTests {
    @Test(.timeLimit(.minutes(1))) func realAdmissionCatalogRetainsActualFactsAfterShutdown() async throws {
        let fixture = try InspectionFixture(); defer { do { try fixture.remove() } catch { Issue.record(error) } }
        let session = TimingPDKProfileInspectionSession(limits: try .init(maximumNestingDepth: 64))
        let admitted = try await fixture.admit(session)
        let catalog = try await session.retainedSources(for: admitted)
        await session.shutdown()
        let owned = try catalog.source(for: fixture.sourceReference)
        #expect(owned.cells.first?.pins.map(\.name) == ["A", "Y"])
        #expect(owned.operatingConditions.first?.process == 1)
        #expect(owned.operatingConditions.first?.voltage == nil)
        #expect(admitted.sourceFacts.allSatisfy { $0.pvt.isEmpty })
        #expect(admitted.sourceFacts.contains { $0.mappings.contains { $0.factKind == "cells" && $0.name == "INV" } })
        await #expect(throws: TimingProfileInspectionError.self) { try await session.retainedSources(for: admitted) }
    }
    @Test(.timeLimit(.minutes(1))) func namedProcessDemandAndIncludeRefused() async throws {
        for fixture in [try InspectionFixture(demandPVT: true),
            try InspectionFixture(library: "library(l) { include(\"other.lib\"); cell(INV) { pin(A) { direction:input; } } }")] {
            defer { do { try fixture.remove() } catch { Issue.record(error) } }
            let session = TimingPDKProfileInspectionSession(limits: try .init(maximumNestingDepth: 64))
            await #expect(throws: PDKProfileAdmissionError.self) { try await fixture.admit(session) }
            await session.shutdown()
        }
    }
    @Test(.timeLimit(.minutes(1))) func receiptsSurviveShutdownUntilLastCatalogCopy() async throws {
        let fixture = try InspectionFixture(); defer { do { try fixture.remove() } catch { Issue.record(error) } }
        let resources = LocalPDKAdmissionResources(budget: fixture.request.budget)
        var catalog: TimingInspectedLibertySources?
        func export() async throws -> TimingInspectedLibertySources {
            let session = TimingPDKProfileInspectionSession(limits: try .init(maximumNestingDepth: 64))
            let admitted = try await fixture.admit(session, resources: resources)
            let result = try await session.retainedSources(for: admitted)
            await session.shutdown(); resources.close()
            return result
        }
        catalog = try await export()
        func live() throws -> UInt64 {
            let entry = try #require(resources.snapshot().dimensions.first { $0.dimension == .liveOwnedBytes })
            if case .live(let current, _) = entry.usage { return current }
            return 0
        }
        #expect(try live() > 0)
        var copy = catalog
        catalog = nil
        #expect(try live() > 0)
        #expect(try copy?.source(for: fixture.sourceReference).cells.count == 1)
        copy = nil
        #expect(try live() == 0)
    }

}
