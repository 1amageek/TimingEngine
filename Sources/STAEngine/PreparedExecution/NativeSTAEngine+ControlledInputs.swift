import Foundation
import TimingCore

extension NativeSTAEngine {
    internal func loadControlledInputs(_ request: STARequest, resources: STAExecutionResources) async throws -> LoadedInputs {
        guard !request.libraries.isEmpty else { throw TimingError.missingArtifact(role: "timing-library") }
        let sourceResources = try TimingCheckedSourceResources(resources.sourceResources)
        let budget = NativeSTAStateBudget(maximum: resources.limits.maximumPathStates, transformResources: sourceResources)
        let retained = NativeSTATransformStorage(budget: budget, kind: .liveOwnedBytes)
        let temporary = NativeSTATransformStorage(budget: budget, kind: .temporaryBytes)
        func check(_ count: UInt64) throws {
            try budget.chargeScheduledWork(1)
            guard count <= resources.limits.maximumInputBytes else {
                throw STAPreparationError.capacity("Native source transform byte ceiling exceeded")
            }
        }
        try check(request.design.byteCount); try check(request.constraints.byteCount); try check(request.pdkManifest.byteCount)
        for reference in request.libraries { try check(reference.artifact.byteCount) }
        if let reference = request.parasitics { try check(reference.byteCount) }
        let json = NativeSTABoundedJSONDecoder(maximumNesting: resources.sourceLimits.maximumNestingDepth)
        let readDesign = try await resources.reader.read(request.design, resources: sourceResources)
        let design = try designParser.parse(readDesign.data, topDesignName: request.topDesignName,
            resources: sourceResources, json: json)
        try retained.hold(design)
        let process = try await STATimingProcessInputs.load(request, reader: resources.reader,
            parser: libraryParser, resources: resources)
        try retained.hold(process.transformRetention)
        let readConstraints = try await resources.reader.read(request.constraints, resources: sourceResources)
        let requestedModes = request.requestedModeIDs
        let count = max(1, requestedModes.count)
        try retained.reserve(String.self, capacity: count)
        try temporary.reserveSet(String.self, capacity: count)
        var modes: [String] = []; modes.reserveCapacity(count)
        var seen: Set<String> = []; seen.reserveCapacity(count)
        if requestedModes.isEmpty { modes.append("default") }
        else {
            for mode in requestedModes {
                try budget.chargeScheduledWork(UInt64(mode.utf8.count))
                if seen.insert(mode).inserted { modes.append(mode) }
            }
        }
        let scenarios = modes.count.multipliedReportingOverflow(by: request.requestedCornerIDs.count)
        let designCount = design.value.instances.count.addingReportingOverflow(design.value.ports.count)
        let elements = designCount.partialValue.addingReportingOverflow(design.value.nets.count)
        guard !scenarios.overflow, !designCount.overflow, !elements.overflow,
              scenarios.partialValue <= resources.limits.maximumScenarios,
              elements.partialValue <= resources.limits.maximumDesignElements else {
            throw STAPreparationError.capacity("Native design/scenario transform ceiling exceeded")
        }
        try retained.reserveDictionary(String.self, TimingConstraintSet.self, capacity: modes.count)
        var constraints: [String:TimingConstraintSet] = [:]; constraints.reserveCapacity(modes.count)
        for mode in modes {
            try budget.chargeScheduledWork(1)
            let parsed = try constraintParser.parse(readConstraints.data, modeID: mode, resources: sourceResources)
            try retained.hold(parsed); constraints[mode] = parsed.value
        }
        let parasitics: TimingParasitics?
        if let reference = request.parasitics {
            let bytes = try await resources.reader.read(reference, resources: sourceResources)
            let parsed = try parasiticParser.parse(bytes.data, resources: sourceResources, json: json)
            try retained.hold(parsed); parasitics = parsed.value
            withExtendedLifetime(bytes) {}
        } else {
            guard !request.requiresPostLayoutInputs else {
                throw TimingError.unsupportedSemantic(format: "STA", semantic: "post-layout signoff without parasitics")
            }
            parasitics = nil
        }
        var result = LoadedInputs(design: design.value, processInputs: process, constraints: constraints,
            parasitics: parasitics, cornerIDs: request.requestedCornerIDs, modeIDs: modes)
        result.transformRetention = try retained.finish()
        withExtendedLifetime((temporary, readDesign, readConstraints)) {}
        return result
    }
}
