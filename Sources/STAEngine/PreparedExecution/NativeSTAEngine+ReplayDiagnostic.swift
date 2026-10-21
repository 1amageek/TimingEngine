import TimingCore

extension NativeSTAEngine {
    /// Preserves the legacy diagnostic's order, exact bit tuples and clipping.
    internal static func controlledReplayMismatch(observed: STAPayload, actual: STAPayload,
        resources: any LibertySourceResourceAccounting) throws -> TimingTransformValue<String> {
        let checked = try TimingCheckedSourceResources(resources)
        let text = try NativeSTAControlledDiagnosticText(resources: checked)
        try text.append("Strict source consumption or actual operands differ from bounded replay; observed/actual: ")
        var hasField = false
        func field(_ name: String) throws {
            if hasField { try text.append("; ") }; hasField = true
            try text.append(name)
        }
        func firstDifference<T: Equatable>(_ lhs: [T], _ rhs: [T]) throws -> Int? {
            for index in 0..<min(lhs.count, rhs.count) {
                try checked.chargeWork(1)
                if lhs[index] != rhs[index] { return index }
            }
            return lhs.count == rhs.count ? nil : min(lhs.count, rhs.count)
        }
        func location<T>(_ name: String, _ index: Int, _ lhs: [T], _ rhs: [T]) throws {
            try text.append(name); try text.append("["); try text.integer(index)
            try text.append(";count="); try text.integer(lhs.count)
            try text.append("/"); try text.integer(rhs.count); try text.append("]")
        }
        func pair(_ name: String, _ a: Double, _ b: Double) throws {
            try text.append(" "); try text.append(name); try text.append("=")
            try text.bits(a); try text.append("/"); try text.bits(b)
        }
        func array<T: Equatable>(_ name: String, _ lhs: [T], _ rhs: [T]) throws {
            if let index = try firstDifference(lhs, rhs) {
                try field(""); try location(name, index, lhs, rhs)
            }
        }
        try checked.chargeWork(1)
        if actual.sourceEvidence != observed.sourceEvidence {
            try field("")
            if let lhs = observed.sourceEvidence, let rhs = actual.sourceEvidence {
                if lhs.version != rhs.version { try text.append("sourceEvidence.version") }
                else if lhs.executionInputIdentity != rhs.executionInputIdentity { try text.append("sourceEvidence.executionInputIdentity") }
                else if lhs.configurationDigest != rhs.configurationDigest { try text.append("sourceEvidence.configurationDigest") }
                else if let index = try firstDifference(lhs.roles, rhs.roles) { try location("sourceEvidence.roles", index, lhs.roles, rhs.roles) }
                else if let index = try firstDifference(lhs.coverage, rhs.coverage) { try location("sourceEvidence.coverage", index, lhs.coverage, rhs.coverage) }
                else if let index = try firstDifference(lhs.samples, rhs.samples) {
                    try location("sourceEvidence.samples", index, lhs.samples, rhs.samples)
                    if index < lhs.samples.count, index < rhs.samples.count {
                        let a = lhs.samples[index], b = rhs.samples[index]
                        try text.append(" role="); try text.integer(a.role); try text.append("/"); try text.integer(b.role)
                        try text.append(" receiver="); try text.clipped(a.receiver); try text.append("/"); try text.clipped(b.receiver)
                        try text.append(" context="); try text.append(a.context.rawValue); try text.append("/"); try text.append(b.context.rawValue)
                        try text.append(" edge="); try text.append(a.inputEdge.rawValue); try text.append("/"); try text.append(b.inputEdge.rawValue)
                        try pair("first", a.observation.firstInput, b.observation.firstInput)
                        try pair("second", a.observation.secondInput, b.observation.secondInput)
                        try pair("result", a.observation.result, b.observation.result)
                        if let ar = a.rangeObservation, let br = b.rangeObservation {
                            try pair("rangeInputLo", ar.firstInput.lowerBound, br.firstInput.lowerBound)
                            try pair("rangeInputHi", ar.firstInput.upperBound, br.firstInput.upperBound)
                            try pair("rangeResultLo", ar.result.lowerBound, br.result.lowerBound)
                            try pair("rangeResultHi", ar.result.upperBound, br.result.upperBound)
                        }
                    }
                } else if let index = try firstDifference(lhs.pulseWidthSamples, rhs.pulseWidthSamples) { try location("sourceEvidence.pulseWidthSamples", index, lhs.pulseWidthSamples, rhs.pulseWidthSamples) }
                else if let index = try firstDifference(lhs.staticStateSamples, rhs.staticStateSamples) { try location("sourceEvidence.staticStateSamples", index, lhs.staticStateSamples, rhs.staticStateSamples) }
                else if let index = try firstDifference(lhs.normalPowerSamples, rhs.normalPowerSamples) { try location("sourceEvidence.normalPowerSamples", index, lhs.normalPowerSamples, rhs.normalPowerSamples) }
                else { try text.append("sourceEvidence") }
            } else { try text.append("sourceEvidence") }
        }
        try checked.chargeWork(1)
        if observed.setupApplicability != actual.setupApplicability { try field("setupApplicability") }
        try array("endpoints", observed.endpoints, actual.endpoints)
        if observed.worstSetupSlack != actual.worstSetupSlack { try field("worstSetupSlack") }
        if observed.worstHoldSlack != actual.worstHoldSlack { try field("worstHoldSlack") }
        try array("criticalPaths", observed.criticalPaths, actual.criticalPaths)
        try array("violations", observed.violations, actual.violations)
        try array("unconstrainedEndpoints", observed.unconstrainedEndpoints, actual.unconstrainedEndpoints)
        try array("clockObservations", observed.clockObservations, actual.clockObservations)
        try array("wireCoverage", observed.wireCoverage, actual.wireCoverage)
        try array("wireObservations", observed.wireObservations, actual.wireObservations)
        if let index = try firstDifference(observed.conservativeWireObservations, actual.conservativeWireObservations) {
            try field(""); try location("conservativeWireObservations", index, observed.conservativeWireObservations, actual.conservativeWireObservations)
            if index < observed.conservativeWireObservations.count, index < actual.conservativeWireObservations.count {
                let a = observed.conservativeWireObservations[index], b = actual.conservativeWireObservations[index]
                try checked.chargeWork(UInt64(a.sourceAuthorities.count)); try checked.chargeWork(UInt64(b.sourceAuthorities.count))
                try text.append(" authorityEqual="); try text.append(a.sourceAuthorities == b.sourceAuthorities ? "true" : "false")
                try text.append(" query="); try text.clipped(a.net); try text.append(":"); try text.clipped(a.sink.name)
                try text.append(":"); try text.append(a.edge.rawValue); try text.append("/")
                try text.clipped(b.net); try text.append(":"); try text.clipped(b.sink.name)
                try text.append(":"); try text.append(b.edge.rawValue)
                try pair("sourceLo", a.sourceSlew.lowerBound, b.sourceSlew.lowerBound)
                try pair("sourceHi", a.sourceSlew.upperBound, b.sourceSlew.upperBound)
                try pair("admittedLo", a.admittedSourceSlew.lowerBound, b.admittedSourceSlew.lowerBound)
                try pair("admittedHi", a.admittedSourceSlew.upperBound, b.admittedSourceSlew.upperBound)
                try pair("delayLo", a.delay.lowerBound, b.delay.lowerBound); try pair("delayHi", a.delay.upperBound, b.delay.upperBound)
                try pair("slewLo", a.slew.lowerBound, b.slew.lowerBound); try pair("slewHi", a.slew.upperBound, b.slew.upperBound)
                try pair("error", a.voltageErrorUpperBound, b.voltageErrorUpperBound)
                try pair("derivativeMin", a.minimumCrossingDerivative, b.minimumCrossingDerivative)
                try pair("derivativeMax", a.maximumAbsoluteDerivative, b.maximumAbsoluteDerivative)
            }
        }
        return try text.finish(limit: 4096)
    }
}
