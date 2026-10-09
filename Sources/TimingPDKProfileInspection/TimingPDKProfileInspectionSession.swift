import CircuiteFoundation
import PDKCore
import PDKProfileAdmission
import TimingCore

/// Inspection performs no suspension: actor ordering joins every parse before export/shutdown.
public actor TimingPDKProfileInspectionSession: PDKProfileSourceInspecting {
    private let parser: any LibertySourceParsing
    private let limits: LibertySourceParseLimits
    private var entries: [TimingInspectedLibertySources.Entry] = []
    private var owners: [LibertySourceStorageReservation] = []
    private var closed = false
    public init(parser: any LibertySourceParsing = LibertyParser(), limits: LibertySourceParseLimits) {
        self.parser = parser; self.limits = limits
    }
    public func inspect(_ request: PDKProfileSourceInspectionRequest,
        dependencies: any PDKProfileDependencyResolving, resources: any PDKAdmissionResourceAccounting)
        async throws(PDKProfileInspectionError) -> PDKProfileSourceFacts {
        guard !closed else { throw .unsupportedSemantics }
        guard request.input.reference.descriptor.format == .liberty else { throw .unsupportedFormat }
        guard request.input.context.selectedSection == nil,
              !request.demandedFactKinds.contains("sourcePVT"),
              request.demandedFactKinds.allSatisfy({ ["cells", "pins", "dependencyClosure"].contains($0) }) else {
            throw .unsupportedSemantics
        }
        let bridge = TimingPDKResourceBridge(resources: resources)
        do {
            try bridge.check()
            let source: OwnedLibertySource
            if let prior = entries.first(where: { $0.input.reference == request.input.reference }) {
                guard prior.policyIdentity == request.inspectionPolicyIdentity else { throw PDKProfileInspectionError.invalidFacts }
                source = prior.source
            } else {
                source = try request.input.capture.withBytes {
                    try parser.parseSource($0, limits: limits, resources: bridge)
                }
            }
            guard UInt64(source.byteCount) == request.input.capture.byteCount else { throw PDKProfileInspectionError.invalidFacts }
            try bridge.chargeWork(request.input.capture.byteCount)
            let matches = request.input.capture.withBytes { expected in
                source.withBytes { actual in
                    for index in 0..<actual.count { if actual[index] != expected[index] { return false } }
                    return true
                }
            }
            guard matches else { throw PDKProfileInspectionError.invalidFacts }
            var mappingCount = source.cells.count
            var scratchBytes = UInt64(MemoryLayout<PDKProfileSourceCoverage>.stride)
            for cell in source.cells {
                try bridge.chargeWork(1)
                let (count, overflow) = mappingCount.addingReportingOverflow(cell.pins.count)
                guard !overflow else { throw LibertySourceError.arithmeticOverflow }
                mappingCount = count
                let (terminals, terminalOverflow) = UInt64(cell.pins.count).multipliedReportingOverflow(by: UInt64(MemoryLayout<String>.stride))
                guard !terminalOverflow else { throw LibertySourceError.arithmeticOverflow }
                let (next, nextOverflow) = scratchBytes.addingReportingOverflow(terminals)
                guard !nextOverflow else { throw LibertySourceError.arithmeticOverflow }; scratchBytes = next
                for pin in cell.pins {
                    let (names, overflow) = UInt64(cell.name.utf8.count).addingReportingOverflow(UInt64(pin.name.utf8.count))
                    let (qualified, qualifiedOverflow) = names.addingReportingOverflow(1)
                    let (next, nextOverflow) = scratchBytes.addingReportingOverflow(qualified)
                    guard !overflow, !qualifiedOverflow, !nextOverflow else { throw LibertySourceError.arithmeticOverflow }
                    try bridge.chargeWork(qualified); scratchBytes = next
                }
            }
            let (mappingBytes, mappingOverflow) = UInt64(mappingCount).multipliedReportingOverflow(by: UInt64(MemoryLayout<PDKProfileMappingFact>.stride))
            let (totalBytes, totalOverflow) = scratchBytes.addingReportingOverflow(mappingBytes)
            guard !mappingOverflow, !totalOverflow else { throw LibertySourceError.arithmeticOverflow }
            let scratch = try bridge.reserveStorage(kind: .temporaryBytes, byteCount: totalBytes)
            defer { withExtendedLifetime(scratch) {} }
            var mappings: [PDKProfileMappingFact] = []; mappings.reserveCapacity(mappingCount)
            for cell in source.cells {
                try bridge.chargeWork(1)
                var terminals: [String] = []; terminals.reserveCapacity(cell.pins.count)
                for pin in cell.pins { try bridge.chargeWork(1); terminals.append(pin.name) }
                mappings.append(.init(input: request.input, factKind: "cells", name: cell.name, terminals: terminals))
                for pin in cell.pins {
                    try bridge.chargeWork(1)
                    mappings.append(.init(input: request.input, factKind: "pins", name: cell.name + "." + pin.name))
                }
            }
            // Unselected condition groups are raw characterization metadata, not operating/nominal PVT.
            let temperatures: [PDKSourceTemperatureFact] = []
            let facts = try PDKProfileSourceFacts(input: request.input,
                parserIdentity: TimingInspectedLibertySources.parserIdentity, policyIdentity: request.inspectionPolicyIdentity,
                mappings: mappings, pvt: [], temperatures: temperatures,
                coverage: [.init(input: request.input, meaning: .leaf, observedSection: nil,
                    evidenceIdentity: "liberty.grammar.leaf.v1", activeDependencies: [], inactiveStatementOffsets: [])],
                events: [], unsupportedFactKinds: [], lostFactKinds: [], resources: resources)
            let (entryCount, countOverflow) = entries.count.addingReportingOverflow(1)
            guard !countOverflow else { throw LibertySourceError.arithmeticOverflow }
            let (entryBytes, bytesOverflow) = UInt64(entryCount).multipliedReportingOverflow(by:
                UInt64(MemoryLayout<TimingInspectedLibertySources.Entry>.stride + MemoryLayout<LibertySourceStorageReservation>.stride) * 2)
            guard !countOverflow, !bytesOverflow else { throw LibertySourceError.arithmeticOverflow }
            let entryOwner = try bridge.reserveStorage(kind: .liveOwnedBytes, byteCount: entryBytes)
            entries.append(.init(input: request.input, policyIdentity: request.inspectionPolicyIdentity, source: source))
            owners.append(entryOwner)
            try bridge.check()
            return facts
        } catch let error as PDKProfileInspectionError { throw error }
        catch let error as PDKAdmissionResourceError { throw .resource(error) }
        catch let error as LibertySourceError {
            switch error {
            case .resource(let cause):
                if let resource = cause as? PDKAdmissionResourceError { throw .resource(resource) }
                throw .invalidFacts
            case .syntax, .invalidUTF8: throw .malformedSource
            default: throw .unsupportedSemantics
            }
        } catch { throw .invalidFacts }
    }
    public func retainedSources(for admitted: AdmittedPDKProfile)
        throws(TimingProfileInspectionError) -> TimingInspectedLibertySources {
        guard !closed else { throw .closedSession }
        guard !entries.isEmpty else { throw .emptyCatalog }
        for entry in entries {
            guard admitted.sourceFacts.contains(where: {
                $0.input.reference == entry.input.reference && $0.input.context == entry.input.context
                    && $0.parserIdentity == TimingInspectedLibertySources.parserIdentity
                    && $0.policyIdentity == entry.policyIdentity
            }) else { throw .unadmittedSource }
        }
        for fact in admitted.sourceFacts where fact.input.reference.descriptor.format == .liberty {
            guard entries.contains(where: { $0.input.reference == fact.input.reference && $0.input.context == fact.input.context }) else {
                throw .unadmittedSource
            }
        }
        return TimingInspectedLibertySources(entries: entries, owners: owners, admitted: admitted)
    }
    public func shutdown() { closed = true; entries = []; owners = [] }
}
