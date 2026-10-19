import TimingCore

extension STAPayload {
    /// Checks saved value consistency only; exact prepared replay still owns source qualification.
    public func validateSetupApplicabilityStructure() throws(STASetupApplicabilityError) {
        guard setupApplicability == (try derivedSetupApplicability()) else {
            throw STASetupApplicabilityError.invalidStructure
        }
    }

    internal func setupApplicabilityValidationWork() throws(STASetupApplicabilityError) -> UInt64 {
        guard let evidence = sourceEvidence, let configuration = effectiveConfiguration,
              configuration.requireStrictSourceEvidence else { throw STASetupApplicabilityError.invalidStructure }
        guard configuration.analysisKinds.count <= 5 else { throw STASetupApplicabilityError.capacity }
        var slots = 1, work = 1
        for count in [evidence.roles.count, evidence.coverage.count, endpoints.count, criticalPaths.count] {
            let nextSlots = slots.addingReportingOverflow(count), nextWork = work.addingReportingOverflow(count)
            guard !nextSlots.overflow, !nextWork.overflow else { throw STASetupApplicabilityError.capacity }
            slots = nextSlots.partialValue; work = nextWork.partialValue
        }
        let roleWork = evidence.roles.count.multipliedReportingOverflow(by:2)
        let total = work.addingReportingOverflow(roleWork.partialValue)
        guard !roleWork.overflow, !total.overflow, slots <= configuration.maximumPathStates,
              UInt64(total.partialValue) <= configuration.maximumPathWorkUnits else { throw STASetupApplicabilityError.capacity }
        return UInt64(total.partialValue)
    }

    internal func derivedSetupApplicability() throws(STASetupApplicabilityError) -> STASetupApplicability {
        _ = try setupApplicabilityValidationWork()
        guard let evidence = sourceEvidence, let configuration = effectiveConfiguration,
              evidence.version == 3, evidence.configurationDigest == configuration.digest,
              evidence.coverage.count == evidence.roles.count else { throw STASetupApplicabilityError.invalidStructure }
        var dispositions: [Int: STASourceEvidence.Coverage.Disposition] = [:]
        dispositions.reserveCapacity(evidence.coverage.count)
        for entry in evidence.coverage {
            guard evidence.roles.indices.contains(entry.role), dispositions.updateValue(entry.disposition,forKey:entry.role) == nil else {
                throw STASetupApplicabilityError.invalidStructure
            }
        }
        var actualWorst: Double?, staticEndpoint = false
        for endpoint in endpoints {
            let staticChecks = endpoint.staticChecks ?? [], notApplicableChecks = endpoint.notApplicableChecks ?? []
            guard staticChecks.count <= 5, notApplicableChecks.count <= 5 else { throw STASetupApplicabilityError.capacity }
            guard Set(staticChecks).count == staticChecks.count,
                  Set(notApplicableChecks).count == notApplicableChecks.count else { throw STASetupApplicabilityError.invalidStructure }
            if let slack = endpoint.setupSlack {
                guard slack.isFinite else { throw STASetupApplicabilityError.invalidStructure }
                actualWorst = min(actualWorst ?? slack,slack)
            }
            if staticChecks.contains(.setup) {
                guard endpoint.staticValue != nil, endpoint.setupSlack == nil else { throw STASetupApplicabilityError.invalidStructure }
                staticEndpoint = true
            }
            if notApplicableChecks.contains(.setup) {
                guard endpoint.setupSlack == nil else { throw STASetupApplicabilityError.invalidStructure }
                staticEndpoint = true
            }
        }
        guard actualWorst == worstSetupSlack else { throw STASetupApplicabilityError.invalidStructure }
        if actualWorst != nil { return .measured }
        guard configuration.analysisKinds.contains(.setup), unconstrainedEndpoints.isEmpty,
              !criticalPaths.contains(where: { $0.analysisKind == .setup }), staticEndpoint else { return .unknown }
        for (index,role) in evidence.roles.enumerated() where role.analysisKind == .setup {
            guard let disposition = dispositions[index] else { throw STASetupApplicabilityError.invalidStructure }
            let status = STASourceEvidence.status(role:role,disposition:disposition)
            guard status == .staticDataNotApplicable || status == .staticStateNotApplicable || status == .sourceNotApplicable else { return .unknown }
        }
        return .sourceNotApplicable
    }
}
