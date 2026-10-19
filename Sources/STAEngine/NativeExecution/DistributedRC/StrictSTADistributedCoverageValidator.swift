import TimingCore

/// Completeness and binding check only; tool qualification and required scope remain host-owned.
public struct StrictSTADistributedCoverageValidator: STADistributedCoverageValidating {
    public init() {}
    public func validate(_ result: STAExecutionResult, request: STARequest,
                         requiredNetNames: [String], requiredCornerIDs: [String]) throws(STADistributedCoverageError) {
        guard !requiredNetNames.isEmpty, !requiredCornerIDs.isEmpty,
              Set(requiredNetNames).count == requiredNetNames.count, Set(requiredCornerIDs).count == requiredCornerIDs.count,
              requiredNetNames.allSatisfy({ !$0.isEmpty }), requiredCornerIDs.allSatisfy({ !$0.isEmpty }) else { throw .invalidRequiredScope }
        guard result.status == .completed else { throw .incompleteExecution }
        guard result.runID == request.runID, result.inputBindings == request.artifactBindings,
              result.payload.provenance.designDigest == (request.canonicalDesignDigest ?? request.design.digest).hexadecimalValue,
              result.payload.provenance.parasiticsDigest == request.parasitics?.digest.hexadecimalValue,
              result.payload.processSelection?.manifest == request.pdkManifest.reference,
              result.payload.processSelection?.processID == request.processID,
              result.payload.processSelection?.pdkVersion == request.pdkVersion else { throw .candidateMismatch }
        let conservative = request.conservativeCoupledRC != nil
        guard request.distributedRC != nil || conservative, let config = result.payload.effectiveConfiguration,
              config.algorithmIdentity == (conservative ? "timing.sta.3.15.0" : "timing.sta.3.9.0"),
              config.reductionIdentity == (conservative ? STAConservativeCoupledRCOptions.modelIdentity : "prescribed-linear-ramp.ideal-quotient.backward-euler.v3"),
              config.distributedRC == request.distributedRC, config.conservativeCoupledRC == request.conservativeCoupledRC, config.analysisKinds == request.analysisKinds, config.maxPaths == request.maxPaths,
              config.requiresPostLayoutInputs == request.requiresPostLayoutInputs, config.variation == request.variation,
              config.requireStrictSourceEvidence == request.requireStrictSourceEvidence,
              config.controlPulseSources == request.controlPulseSources.sorted { [$0.modeID, $0.sourcePort].lexicographicallyPrecedes([$1.modeID, $1.sourcePort]) },
              config.operatingSupplyAssumptions == request.operatingSupplyAssumptions.sorted { [$0.cornerID, $0.instance, $0.pin].lexicographicallyPrecedes([$1.cornerID, $1.instance, $1.pin]) },
              config.characterizationPolicy == request.characterizationPolicy, config.characterizationBindings == request.characterizationBindings,
              request.configurationDigest == nil || request.configurationDigest == config.digest,
              !result.payload.analyzedModes.isEmpty, result.payload.analyzedModes == config.modeIDs,
              request.requestedModeIDs.isEmpty || request.requestedModeIDs == config.modeIDs else { throw .configurationMismatch }
        guard request.requestedCornerIDs == requiredCornerIDs, result.payload.analyzedCorners == requiredCornerIDs,
              config.cornerIDs == requiredCornerIDs,
              result.payload.processSelection?.corners.map(\.cornerID) == requiredCornerIDs else { throw .cornerMismatch }
        let expectedClocks = Set(config.clockReceiverScope.flatMap { scope in
            [TimingEdge.rise, .fall].map { [scope.modeID, scope.cornerID, scope.rootClock, scope.receiver, $0.rawValue] }
        })
        let observedClocks = result.payload.clockObservations.map { [$0.modeID, $0.cornerID, $0.rootClock, $0.receiver, $0.edge.rawValue] }
        guard Set(observedClocks) == expectedClocks, observedClocks.count == expectedClocks.count else {
            let missing = config.clockReceiverScope.first { scope in
                !result.payload.clockObservations.contains { $0.modeID == scope.modeID && $0.cornerID == scope.cornerID && $0.rootClock == scope.rootClock && $0.receiver == scope.receiver }
            } ?? config.clockReceiverScope.first
            throw .missingClockObservation(clock: missing?.rootClock ?? "unknown", mode: missing?.modeID ?? "unknown", corner: missing?.cornerID ?? "unknown")
        }
        for corner in requiredCornerIDs {
            guard let expected = request.libraries.first(where: { $0.cornerIDs.contains(corner) })?.artifact.reference,
                  result.payload.processSelection?.librariesByCorner[corner] == expected else { throw .candidateMismatch }
            for mode in result.payload.analyzedModes {
                for net in requiredNetNames {
                    let coverage = result.payload.wireCoverage.filter { $0.net == net && $0.modeID == mode && $0.cornerID == corner }
                    guard coverage.count == 1,
                          conservative ? coverage[0].model == .conservativeCoupledRC : (coverage[0].model == .distributedRC || coverage[0].model == .propagatedClock) else {
                        throw .missingModeledNet(net: net, mode: mode, corner: corner)
                    }
                    if conservative {
                        guard result.payload.conservativeWireObservations.contains(where: { $0.net == net && $0.modeID == mode && $0.cornerID == corner }) else {
                            throw .missingWireObservation(net: net, mode: mode, corner: corner)
                        }
                        continue
                    }
                    guard result.payload.wireObservations.contains(where: { $0.net == net && $0.modeID == mode && $0.cornerID == corner
                        && (coverage[0].model != .propagatedClock || $0.period != nil) }) else {
                        throw .missingWireObservation(net: net, mode: mode, corner: corner)
                    }
                }
            }
        }
    }
}
