import TimingCore

internal enum NativeSTAConservativeCouplingError: Error, Sendable, Equatable {
    case invalidSourceAuthority(String)
    case invalidPrimitive(String)
    case unsupportedCapacitanceProfile(String)
    case invalidCertificate(String)
    case unsupportedNativeCapability(String)
    case nativeBackendFailure(String)
    case unprovedCrossing(source: TimingParasitics.Endpoint, sink: TimingParasitics.Endpoint, edge: TimingEdge)
    case unprovedUniqueTransition(source: TimingParasitics.Endpoint, sink: TimingParasitics.Endpoint, edge: TimingEdge,
        diagnostic: NativeSTAConservativeTransitionDiagnostic? = nil)
    case inconsistentBounds(String)
}

internal protocol NativeSTAConservativeCouplingSolving: Sendable {
    func prepare(parasitics: TimingParasitics, sources: [NativeSTAConservativeCoupling.Source],
        receiverLoads: [TimingParasitics.Endpoint: Double], thresholds: TimingCharacterizationThresholds,
        options: STAConservativeCoupledRCOptions, limits: STAExecutionLimits, stateBudget: NativeSTAStateBudget,
        sourceResources: (any LibertySourceResourceAccounting)?, work: inout UInt64) throws -> NativeSTAConservativeCoupling.Prepared
    func bounds(prepared: NativeSTAConservativeCoupling.Prepared, source: TimingParasitics.Endpoint,
        sink: TimingParasitics.Endpoint, edge: TimingEdge, sourceSlew: ClosedRange<Double>,
        work: inout UInt64) throws -> NativeSTAConservativeCoupling.Bounds
}

/// Certifies all bounded operating histories of prescribed normalized full-rail ramps.
internal struct NativeSTAConservativeCoupling: NativeSTAConservativeCouplingSolving {
    typealias N = NativeSTAConservativeNumerics
    typealias S = NativeSTAConservativeSparseNumerics
    typealias I = TimingNumericInterval
    typealias E = TimingParasitics.Endpoint
    internal enum Source: Sendable {
        case constant(endpoint: E, voltage: Double)
        case dynamic(endpoint: E, sourceIsPort: Bool, riseSlew: ClosedRange<Double>, fallSlew: ClosedRange<Double>)
        var endpoint: E {
            switch self { case .constant(let e, _), .dynamic(let e, _, _, _): return e }
        }
    }
    internal enum Prepared: Sendable {
        case comparison(ComparisonPrepared)
        case residual(ResidualPrepared)
    }
    internal struct ResidualPrepared: Sendable {
        let parasitics: TimingParasitics
        let sources: [Source]
        let receiverLoads: [E: Double]
        let endpointRows: [E: Int]
        let endpointSource: [E: Int]
        let sourceIndices: [E: Int]
        let sourceSlopes: N.Matrix
        let dcIncidence: S.CSR
        let thresholds: TimingCharacterizationThresholds
        let options: STAConservativeCoupledRCOptions
        let numerics: N
        let facts: NativeSTAConservativeResidualResponse.Facts
        let sourceHistories: [E: NativeSTAConservativeSourceHistory]
        init(parasitics: TimingParasitics, sources: [Source], receiverLoads: [E: Double], endpointRows: [E: Int],
            endpointSource: [E: Int], sourceIndices: [E: Int], sourceSlopes: N.Matrix, dcIncidence: S.CSR,
            thresholds: TimingCharacterizationThresholds, options: STAConservativeCoupledRCOptions,
            numerics: N, facts: NativeSTAConservativeResidualResponse.Facts,
            sourceHistories: [E: NativeSTAConservativeSourceHistory] = [:]) {
            self.parasitics = parasitics; self.sources = sources; self.receiverLoads = receiverLoads
            self.endpointRows = endpointRows; self.endpointSource = endpointSource; self.sourceIndices = sourceIndices
            self.sourceSlopes = sourceSlopes; self.dcIncidence = dcIncidence; self.thresholds = thresholds
            self.options = options; self.numerics = numerics; self.facts = facts; self.sourceHistories = sourceHistories
        }
    }
    internal struct ComparisonPrepared: Sendable {
        let parasitics: TimingParasitics
        let sources: [Source]
        let receiverLoads: [E: Double]
        let endpointRows: [E: Int]
        let endpointSource: [E: Int]
        let sourceIndices: [E: Int]
        let dynamicRows: [Int]
        let reconstruction: S.CSR
        let operatorA: S.CSR
        let forcingJ: S.CSR
        let comparison: S.CSR
        let weight: N.Matrix
        let alpha: Double
        let radius: N.Matrix
        let voltageError: N.Matrix
        let sourceSlopes: N.Matrix
        let dcIncidence: S.CSR
        let thresholds: TimingCharacterizationThresholds
        let options: STAConservativeCoupledRCOptions
        let numerics: N
        let sourceCertificates: SourceCertificates?
        let sourceHistories: [E: NativeSTAConservativeSourceHistory]
        fileprivate init(parasitics: TimingParasitics, sources: [Source], receiverLoads: [E: Double], endpointRows: [E: Int], endpointSource: [E: Int],
            sourceIndices: [E: Int], dynamicRows: [Int], reconstruction: S.CSR, operatorA: S.CSR, forcingJ: S.CSR,
            comparison: S.CSR, weight: N.Matrix, alpha: Double, radius: N.Matrix, voltageError: N.Matrix,
            sourceSlopes: N.Matrix, dcIncidence: S.CSR, thresholds: TimingCharacterizationThresholds,
            options: STAConservativeCoupledRCOptions, numerics: N, sourceCertificates: SourceCertificates? = nil,
            sourceHistories: [E: NativeSTAConservativeSourceHistory] = [:]) {
            self.parasitics = parasitics; self.sources = sources; self.receiverLoads = receiverLoads; self.endpointRows = endpointRows
            self.endpointSource = endpointSource; self.sourceIndices = sourceIndices; self.dynamicRows = dynamicRows
            self.reconstruction = reconstruction; self.operatorA = operatorA; self.forcingJ = forcingJ
            self.comparison = comparison; self.weight = weight; self.alpha = alpha; self.radius = radius
            self.voltageError = voltageError; self.sourceSlopes = sourceSlopes; self.dcIncidence = dcIncidence
            self.thresholds = thresholds; self.options = options; self.numerics = numerics; self.sourceCertificates = sourceCertificates
            self.sourceHistories = sourceHistories
        }
    }
    internal struct SourceCertificates: Sendable {
        let ownRadius: N.Matrix
        let aggressorRadius: N.Matrix
        let unitEquilibrium: N.Matrix
        let aggressorForcing: N.Matrix
    }
    internal struct Bounds: Sendable {
        let delay: ClosedRange<Double>
        let slew: ClosedRange<Double>
        let voltageErrorUpperBound: Double
        let minimumCrossingDerivative: Double
        let maximumAbsoluteDerivative: Double
        let admittedSourceSlew: ClosedRange<Double>
    }

    func prepare(parasitics: TimingParasitics, sources: [Source], receiverLoads: [E: Double],
        thresholds: TimingCharacterizationThresholds, options: STAConservativeCoupledRCOptions,
        limits: STAExecutionLimits, stateBudget: NativeSTAStateBudget,
        sourceResources: (any LibertySourceResourceAccounting)?, work: inout UInt64) throws -> Prepared {
        let numerical = N(limits: limits, budget: stateBudget, resources: sourceResources)
        try numerical.tick(&work); try numerical.slots(8)
        guard parasitics.hasDistributedTopology else { throw NativeSTAConservativeCouplingError.invalidPrimitive("exact resistance topology required") }
        let rise = try thresholdSpan(thresholds, rising: true), fall = try thresholdSpan(thresholds, rising: false)
        for value in [thresholds.inputRise, thresholds.inputFall, thresholds.outputRise, thresholds.outputFall] {
            guard value.isFinite, value > 0, value < 100 else { throw NativeSTAConservativeCouplingError.invalidSourceAuthority("invalid input/output threshold") }
        }
        var endpoints: [E] = [], index: [E: Int] = [:], netNames: Set<String> = [], sourceIndex: [E: Int] = [:]
        var endpointNames: [String: String] = [:]
        func admit(_ endpoint: E) throws {
            try numerical.tick(&work)
            guard !endpoint.name.isEmpty, !endpoint.ownerNet.isEmpty else { throw NativeSTAConservativeCouplingError.invalidPrimitive("empty endpoint") }
            if let owner = endpointNames[endpoint.name], owner != endpoint.ownerNet { throw NativeSTAConservativeCouplingError.invalidPrimitive("conflicting endpoint owner") }
            if index[endpoint] == nil {
                try numerical.slots(5)
                index[endpoint] = endpoints.count; endpoints.append(endpoint); endpointNames[endpoint.name] = endpoint.ownerNet
            }
        }
        var primitiveCount = 0, capacitanceCount = 0
        for network in parasitics.networks {
            try numerical.tick(&work); try numerical.slots(1)
            guard !network.name.isEmpty, netNames.insert(network.name).inserted,
                network.declaredCapacitance.isFinite, network.declaredCapacitance >= 0,
                network.resistanceInventory.isFinite, network.resistanceInventory >= 0 else {
                throw NativeSTAConservativeCouplingError.invalidPrimitive("invalid network declaration")
            }
            var connectionSet: Set<E> = []
            for endpoint in network.connections {
                guard endpoint.ownerNet == network.name, connectionSet.insert(endpoint).inserted else { throw NativeSTAConservativeCouplingError.invalidPrimitive("connection ownership or duplicate") }
                try numerical.slots(1); try admit(endpoint)
            }
            for resistor in network.resistances { try admit(resistor.first); try admit(resistor.second); primitiveCount += 1 }
            for cap in network.capacitances { try admit(cap.first); if let second = cap.second { try admit(second) }
                capacitanceCount += 1; primitiveCount += 1 }
        }
        for endpoint in endpoints where !netNames.contains(endpoint.ownerNet) { throw NativeSTAConservativeCouplingError.invalidPrimitive("endpoint references absent network: " + endpoint.ownerNet) }
        var slopes = try numerical.matrix(sources.count, 1)
        for (j, source) in sources.enumerated() {
            try numerical.tick(&work, parasitics.networks.count); try numerical.slots(1)
            guard let network = parasitics.networks.first(where: { $0.name == source.endpoint.ownerNet }),
                  network.connections.contains(source.endpoint), sourceIndex.updateValue(j, forKey: source.endpoint) == nil else {
                throw NativeSTAConservativeCouplingError.invalidSourceAuthority("missing or repeated canonical source endpoint")
            }
            switch source {
            case .constant(_, let voltage):
                guard voltage.isFinite, (0...1).contains(voltage) else { throw NativeSTAConservativeCouplingError.invalidSourceAuthority("constant outside normalized rails") }
            case .dynamic(_, _, let r, let f):
                guard r.lowerBound.isFinite, r.upperBound.isFinite, f.lowerBound.isFinite, f.upperBound.isFinite,
                      r.lowerBound > 0, f.lowerBound > 0 else { throw NativeSTAConservativeCouplingError.invalidSourceAuthority("nonpositive global slew domain") }
                slopes[j, 0] = try I(point: max(rise.divided(by: I(point: r.lowerBound)).upperBound,
                                              fall.divided(by: I(point: f.lowerBound)).upperBound))
            }
        }
        guard !sources.isEmpty else { throw NativeSTAConservativeCouplingError.invalidSourceAuthority("no canonical sources") }
        try numerical.slots(endpoints.count, times: 9)
        var ideal = Array(endpoints.indices), resistive = ideal, coupled = ideal
        func root(_ i: Int, _ parent: [Int]) throws -> Int {
            var node = i
            while parent[node] != node { try numerical.tick(&work); node = parent[node] }
            return node
        }
        func join(_ i: Int, _ j: Int, _ parent: inout [Int]) throws {
            let a = try root(i, parent), b = try root(j, parent)
            if a != b { parent[max(a, b)] = min(a, b) }
        }
        for network in parasitics.networks {
            var resistanceIDs: Set<UInt64> = []
            for r in network.resistances {
                try numerical.tick(&work); try numerical.slots(1)
                guard r.source.declaringNet == network.name, r.source.identifier > 0, r.source.line > 0,
                      resistanceIDs.insert(r.source.identifier).inserted, r.resistance.isFinite, r.resistance >= 0,
                      r.first.ownerNet == network.name, r.second.ownerNet == network.name else {
                    throw NativeSTAConservativeCouplingError.invalidPrimitive("invalid resistor identity, ownership or value")
                }
                let a = index[r.first]!, b = index[r.second]!
                try join(a, b, &resistive); try join(a, b, &coupled)
                if r.resistance == 0 { try join(a, b, &ideal) }
            }
            for c in network.capacitances {
                try numerical.tick(&work)
                if let second = c.second, c.capacitance > 0 { try join(index[c.first]!, index[second]!, &coupled) }
            }
        }
        var componentCounts: [Int: Int] = [:]
        for i in endpoints.indices {
            try numerical.tick(&work)
            ideal[i] = try root(i, ideal); resistive[i] = try root(i, resistive); coupled[i] = try root(i, coupled)
            componentCounts[coupled[i], default: 0] += 1
            guard componentCounts[coupled[i]]! <= options.maximumNodes else {
                throw STAPathAnalysisError.capacity(resource: "conservative RC component nodes", limit: UInt64(options.maximumNodes))
            }
        }
        var componentSource: [Int: Int] = [:], idealSource: [Int: Int] = [:]
        for (j, source) in sources.enumerated() {
            try numerical.tick(&work)
            let i = index[source.endpoint]!, rc = resistive[i]
            guard componentSource[rc] == nil, idealSource[ideal[i]] == nil else { throw NativeSTAConservativeCouplingError.invalidSourceAuthority("multiple canonical drivers in a resistive component") }
            componentSource[rc] = j; idealSource[ideal[i]] = j
        }
        for i in endpoints.indices {
            try numerical.tick(&work)
            guard componentSource[resistive[i]] != nil else { throw NativeSTAConservativeCouplingError.invalidSourceAuthority("resistively unanchored endpoint") }
        }
        // Reuse the canonical owned-mirror contract, never its equipotential load projection.
        let lowerCountA = capacitanceCount.multipliedReportingOverflow(by: 3)
        let lowerCountB = lowerCountA.partialValue.addingReportingOverflow(parasitics.networks.count)
        guard !lowerCountA.overflow, !lowerCountB.overflow else { throw NativeSTAConservativeCouplingError.invalidPrimitive("inventory count overflow") }
        let lowerCount = lowerCountB.partialValue
        let normalizerWork = lowerCount.multipliedReportingOverflow(by: max(1, lowerCount))
        guard !normalizerWork.overflow else { throw NativeSTAConservativeCouplingError.invalidPrimitive("inventory work overflow") }
        let normalizerSlots = lowerCount.multipliedReportingOverflow(by: 32)
        guard !normalizerSlots.overflow else { throw NativeSTAConservativeCouplingError.invalidPrimitive("inventory workspace overflow") }
        try numerical.slots(normalizerSlots.partialValue)
        try numerical.tick(&work, normalizerWork.partialValue)
        let mirrorGroups = try EquipotentialTimingParasiticReducer().reduce(parasitics).evidence.mirroredSourceGroups
        try numerical.tick(&work)
        var skipped: Set<TimingParasitics.SourceID> = []
        for group in mirrorGroups {
            try numerical.tick(&work)
            guard group.count == 2 else { throw NativeSTAConservativeCouplingError.invalidPrimitive("invalid canonical mirror group") }
            try numerical.slots(1); skipped.insert(max(group[0], group[1]))
        }
        var classRows: [Int: Int] = [:], rows: [E: Int] = [:], endpointSource: [E: Int] = [:]
        for i in endpoints.indices where idealSource[ideal[i]] == nil {
            try numerical.tick(&work)
            if classRows[ideal[i]] == nil { try numerical.slots(1); classRows[ideal[i]] = classRows.count }
        }
        let n = classRows.count, s = sources.count
        var p = try numerical.matrix(n, s)
        for i in endpoints.indices {
            try numerical.tick(&work); try numerical.slots(2)
            endpointSource[endpoints[i]] = componentSource[resistive[i]]!
            if let row = classRows[ideal[i]] { rows[endpoints[i]] = row; p[row, componentSource[resistive[i]]!] = try I(point: 1) }
        }
        let square = n.multipliedReportingOverflow(by: n)
        let denseSlots = square.partialValue.multipliedReportingOverflow(by: 64)
        let cube = square.partialValue.multipliedReportingOverflow(by: n)
        if square.overflow || denseSlots.overflow || cube.overflow
            || denseSlots.partialValue > limits.maximumPathStates
            || UInt64(cube.partialValue) > limits.maximumPathWorkUnits {
            let reduced = try NativeSTAConservativeSparseGraph(numerical: numerical).reduce(
                parasitics: parasitics, originalIndex: index, ideal: ideal, idealSource: idealSource,
                rows: rows, sourceIndex: sourceIndex, receiverLoads: receiverLoads, skipped: skipped,
                dcIncidence: p, work: &work)
            var nontrivial = false
            for block in reduced.capBlocks { try numerical.tick(&work); if block.count > 1 { nontrivial = true } }
            try numerical.slots(options.maximumCertificateAttempts >= 4 ? 7 : 6)
            let candidates: [NativeSTAConservativeSparseBasis.Candidate] = nontrivial
                ? [.localModal, .whitening, .identity] : [.identity]
            var failures: [String] = []
            for candidate in candidates.prefix(options.maximumCertificateAttempts) {
                try numerical.tick(&work)
                do {
                    let operators = try NativeSTAConservativeSparseBasis(numerical: numerical).transform(reduced,
                        candidate: candidate, maximumSweeps: options.maximumBasisSweeps, work: &work)
                    return .comparison(try prepareSparse(operators: operators, parasitics: parasitics, sources: sources,
                        receiverLoads: receiverLoads, rows: rows, endpointSource: endpointSource, sourceIndex: sourceIndex,
                        slopes: slopes, thresholds: thresholds, options: options, numerical: numerical,
                        monotoneWeight: candidate == .whitening, work: &work))
                } catch let rejected as NativeSTAConservativeCandidateNotCertified {
                    failures.append("\(candidate): \(rejected.reason)")
                }
            }
            if options.maximumCertificateAttempts >= 4 {
                try numerical.tick(&work)
                do {
                    let receiverRows = try residualReceiverRows(receiverLoads: receiverLoads,
                        endpointRows: rows, numerical: numerical, work: &work)
                    let times = try residualTimes(reduced: reduced, sources: sources, thresholds: thresholds,
                        numerical: numerical, work: &work)
                    let certificate = try NativeSTAConservativeResidualCertificate(numerical: numerical)
                        .prepare(reduced, receiverRows: receiverRows, times: times, work: &work)
                    let facts = try NativeSTAConservativeResidualResponse(numerical: numerical).prepare(certificate, work: &work)
                    return .residual(ResidualPrepared(parasitics: parasitics, sources: sources, receiverLoads: receiverLoads,
                        endpointRows: rows, endpointSource: endpointSource, sourceIndices: sourceIndex,
                        sourceSlopes: slopes, dcIncidence: reduced.dcIncidence, thresholds: thresholds,
                        options: options, numerics: numerical, facts: facts))
                } catch let rejected as NativeSTAConservativeCandidateNotCertified {
                    failures.append("residual: \(rejected.reason)")
                }
            }
            throw NativeSTAConservativeCouplingError.invalidCertificate("sparse coordinate candidates exhausted [" + failures.joined(separator: " | ") + "]")
        }
        var g = try numerical.matrix(n, n), c = try numerical.matrix(n, n), cs = try numerical.matrix(n, s), gs = try numerical.matrix(n, s)
        try numerical.slots(n)
        var hasCapacitance = Array(repeating: false, count: n)
        func stamp(_ a: E, _ b: E?, _ value: I, capacitance: Bool) throws {
            try numerical.tick(&work)
            let ai = index[a]!, bi = b.flatMap { index[$0] }
            if let bi, ideal[ai] == ideal[bi] { return }
            let ar = rows[a], br = b.flatMap { rows[$0] }
            if capacitance {
                if let ar { c[ar, ar] = try c[ar, ar].adding(value); if value.upperBound > 0 { hasCapacitance[ar] = true } }
                if let br { c[br, br] = try c[br, br].adding(value); if value.upperBound > 0 { hasCapacitance[br] = true } }
                if let ar, let br { c[ar, br] = try c[ar, br].subtracting(value); c[br, ar] = try c[br, ar].subtracting(value) }
                else if let ar, let bi, let source = idealSource[ideal[bi]] { cs[ar, source] = try cs[ar, source].subtracting(value) }
                else if let br, let source = idealSource[ideal[ai]] { cs[br, source] = try cs[br, source].subtracting(value) }
            } else {
                if let ar { g[ar, ar] = try g[ar, ar].adding(value) }
                if let br { g[br, br] = try g[br, br].adding(value) }
                if let ar, let br { g[ar, br] = try g[ar, br].subtracting(value); g[br, ar] = try g[br, ar].subtracting(value) }
                else if let ar, let bi, let source = idealSource[ideal[bi]] { gs[ar, source] = try gs[ar, source].subtracting(value) }
                else if let br, let source = idealSource[ideal[ai]] { gs[br, source] = try gs[br, source].subtracting(value) }
            }
        }
        for network in parasitics.networks {
            for r in network.resistances where r.resistance > 0 { try stamp(r.first, r.second, I(point: 1).divided(by: I(point: r.resistance)), capacitance: false) }
            for cap in network.capacitances where !skipped.contains(cap.source) { try stamp(cap.first, cap.second, I(point: cap.capacitance), capacitance: true) }
        }
        for (endpoint, load) in receiverLoads {
            try numerical.tick(&work)
            guard index[endpoint] != nil, load.isFinite, load >= 0 else { throw NativeSTAConservativeCouplingError.invalidPrimitive("invalid receiver load binding") }
            guard sourceIndex[endpoint] == nil else { throw NativeSTAConservativeCouplingError.invalidPrimitive("driver pin load supplied as receiver") }
            try stamp(endpoint, nil, I(point: load), capacitance: true)
        }
        try numerical.positiveDefinite(g, work: &work)
        // Incidence construction and one-driver resistive closure establish exact G P = -Gs.
        // The independent stamps must also retain zero in every outward residual entry.
        let dcProduct = try numerical.product(g, p, work: &work)
        for i in dcProduct.values.indices {
            try numerical.tick(&work)
            let residual = try dcProduct.values[i].adding(gs.values[i])
            guard residual.lowerBound <= 0, residual.upperBound >= 0 else {
                throw NativeSTAConservativeCouplingError.invalidCertificate("DC source incidence identity failed")
            }
        }
        var l = try numerical.product(c, p, work: &work)
        for i in l.values.indices { try numerical.tick(&work); l.values[i] = try l.values[i].adding(cs.values[i]) }
        try numerical.slots(n, times: 2)
        var dynamic: [Int] = [], algebraic: [Int] = []
        dynamic.reserveCapacity(n); algebraic.reserveCapacity(n)
        for row in 0..<n {
            try numerical.tick(&work)
            if hasCapacitance[row] { dynamic.append(row) } else { algebraic.append(row) }
        }
        let d = dynamic.count
        var cr = try numerical.matrix(d, d), gr = try numerical.matrix(d, d), lr = try numerical.matrix(d, s)
        var reconstruction = try numerical.matrix(n, d)
        for (i, row) in dynamic.enumerated() {
            reconstruction[row, i] = try I(point: 1)
            for (j, column) in dynamic.enumerated() { try numerical.tick(&work); cr[i, j] = c[row, column]; gr[i, j] = g[row, column] }
            for j in 0..<s { try numerical.tick(&work); lr[i, j] = l[row, j] }
        }
        if !algebraic.isEmpty {
            var gaa = try numerical.matrix(algebraic.count, algebraic.count), gad = try numerical.matrix(algebraic.count, d)
            for (i, row) in algebraic.enumerated() {
                for (j, column) in algebraic.enumerated() { try numerical.tick(&work); gaa[i, j] = g[row, column] }
                for (j, column) in dynamic.enumerated() { try numerical.tick(&work); gad[i, j] = g[row, column] }
            }
            let elimination = try numerical.solve(gaa, gad, work: &work)
            gr = try numerical.difference(gr, numerical.product(numerical.transpose(gad, work: &work), elimination, work: &work), work: &work)
            for (i, row) in algebraic.enumerated() { for j in 0..<d { try numerical.tick(&work); reconstruction[row, j] = try elimination[i, j].negated() } }
        }
        if d == 0 {
            return .comparison(ComparisonPrepared(parasitics: parasitics, sources: sources, receiverLoads: receiverLoads, endpointRows: rows, endpointSource: endpointSource,
                sourceIndices: sourceIndex, dynamicRows: dynamic, reconstruction: try sparse(reconstruction, numerical: numerical, work: &work),
                operatorA: try sparse(numerical.matrix(0, 0), numerical: numerical, work: &work), forcingJ: try sparse(numerical.matrix(0, s), numerical: numerical, work: &work), comparison: try sparse(numerical.matrix(0, 0), numerical: numerical, work: &work),
                weight: try numerical.matrix(0, 1), alpha: 1, radius: try numerical.matrix(0, 1),
                voltageError: try numerical.matrix(n, 1), sourceSlopes: slopes, dcIncidence: try sparse(p, numerical: numerical, work: &work),
                thresholds: thresholds, options: options, numerics: numerical))
        }
        try numerical.positiveDefinite(cr, capacitance: true, work: &work); try numerical.positiveDefinite(gr, work: &work)
        var failure = NativeSTAConservativeCouplingError.invalidCertificate("coordinate candidates exhausted")
        for attempt in 0..<min(2, options.maximumCertificateAttempts) {
            try numerical.tick(&work)
            do {
                let q = try attempt == 0 ? numerical.identity(d, work: &work)
                    : numerical.basis(cr, gr, sweeps: options.maximumBasisSweeps, work: &work)
                let qt = try numerical.transpose(q, work: &work)
                let mass = try numerical.product(qt, numerical.product(cr, q, work: &work), work: &work)
                try numerical.positiveDefinite(mass, work: &work)
                let stiffness = try numerical.product(qt, numerical.product(gr, q, work: &work), work: &work)
                let a = try numerical.negated(numerical.solve(mass, stiffness, work: &work), work: &work)
                let j = try numerical.negated(numerical.solve(mass, numerical.product(qt, lr, work: &work), work: &work), work: &work)
                let t = try numerical.product(reconstruction, q, work: &work)
                var f = try numerical.matrix(d, d)
                for i in 0..<d { for k in 0..<d { try numerical.tick(&work); f[i, k] = try I(point: i == k ? a[i, k].upperBound : a[i, k].absolute().upperBound) } }
                var one = try numerical.matrix(d, 1)
                for i in 0..<d { try numerical.tick(&work); one[i, 0] = try I(point: 1) }
                let proposedWeight = try numerical.solve(numerical.negated(f, work: &work), one, work: &work)
                var w = try numerical.matrix(d, 1)
                for i in 0..<d {
                    try numerical.tick(&work)
                    let value = proposedWeight[i, 0].lowerBound / 2 + proposedWeight[i, 0].upperBound / 2
                    guard value > 0 else { throw NativeSTAConservativeCouplingError.invalidCertificate("nonpositive comparison weight") }
                    w[i, 0] = try I(point: value)
                }
                let fw = try numerical.product(f, w, work: &work)
                var alpha = Double.greatestFiniteMagnitude
                for i in 0..<d {
                    try numerical.tick(&work)
                    let ratio = try fw[i, 0].negated().divided(by: w[i, 0])
                    guard ratio.lowerBound > 0 else { throw NativeSTAConservativeCouplingError.invalidCertificate("comparison stability inequality failed") }
                    alpha = min(alpha, ratio.lowerBound)
                }
                let forcing = try numerical.product(numerical.magnitude(j, work: &work), slopes, work: &work)
                let sparseF = try sparse(f, numerical: numerical, work: &work)
                let radius = try invariantRadius(f: sparseF, w: w, forcing: forcing, numerical: numerical, maximumIterations: iterations(d, options: options), work: &work)
                let error = try numerical.product(numerical.magnitude(t, work: &work), radius, work: &work)
                return .comparison(ComparisonPrepared(parasitics: parasitics, sources: sources, receiverLoads: receiverLoads, endpointRows: rows, endpointSource: endpointSource,
                    sourceIndices: sourceIndex, dynamicRows: dynamic, reconstruction: try sparse(t, numerical: numerical, work: &work), operatorA: try sparse(a, numerical: numerical, work: &work), forcingJ: try sparse(j, numerical: numerical, work: &work),
                    comparison: sparseF, weight: w, alpha: alpha, radius: radius, voltageError: error, sourceSlopes: slopes,
                    dcIncidence: try sparse(p, numerical: numerical, work: &work), thresholds: thresholds, options: options, numerics: numerical))
            } catch let rejected as NativeSTAConservativeCandidateNotCertified {
                failure = .invalidCertificate(rejected.reason)
            } catch let error as NativeSTAConservativeCouplingError {
                switch error {
                case .invalidCertificate: failure = error
                default: throw error
                }
            }
        }
        throw failure
    }

    /// Narrows only admitted source histories; immutable numerical certificates keep their owners.
    func restrictSources(prepared: Prepared, to sources: [Source], work: inout UInt64) throws -> Prepared {
        let previous: [Source], thresholds: TimingCharacterizationThresholds, numerical: N
        switch prepared {
        case .comparison(let model): previous = model.sources; thresholds = model.thresholds; numerical = model.numerics
        case .residual(let model): previous = model.sources; thresholds = model.thresholds; numerical = model.numerics
        }
        try numerical.tick(&work)
        guard sources.count == previous.count else {
            throw NativeSTAConservativeCouplingError.invalidSourceAuthority("source restriction changes source count")
        }
        var changed = false
        for index in sources.indices {
            try numerical.tick(&work)
            guard sources[index].endpoint == previous[index].endpoint else {
                throw NativeSTAConservativeCouplingError.invalidSourceAuthority("source restriction changes endpoint or order")
            }
            switch (previous[index], sources[index]) {
            case (.constant(_, let old), .constant(_, let next)):
                guard next == old else {
                    throw NativeSTAConservativeCouplingError.invalidSourceAuthority("source restriction changes constant voltage")
                }
            case (.dynamic(_, let oldPort, let oldRise, let oldFall), .dynamic(_, let nextPort, let rise, let fall)):
                guard oldPort == nextPort, rise.lowerBound.isFinite, rise.upperBound.isFinite,
                      fall.lowerBound.isFinite, fall.upperBound.isFinite, rise.lowerBound > 0, fall.lowerBound > 0,
                      rise.lowerBound >= oldRise.lowerBound, rise.upperBound <= oldRise.upperBound,
                      fall.lowerBound >= oldFall.lowerBound, fall.upperBound <= oldFall.upperBound else {
                    throw NativeSTAConservativeCouplingError.invalidSourceAuthority("source restriction changes role or widens a transition domain")
                }
                changed = changed || rise != oldRise || fall != oldFall
            default:
                throw NativeSTAConservativeCouplingError.invalidSourceAuthority("source restriction changes constant/dynamic kind")
            }
        }
        guard changed else { return prepared }
        let rise = try thresholdSpan(thresholds, rising: true), fall = try thresholdSpan(thresholds, rising: false)
        var slopes = try numerical.matrix(sources.count, 1)
        try numerical.slots(sources.count)
        for (index, source) in sources.enumerated() {
            try numerical.tick(&work)
            if case .dynamic(_, _, let r, let f) = source {
                slopes[index, 0] = try I(point: max(rise.divided(by: I(point: r.lowerBound)).upperBound,
                    fall.divided(by: I(point: f.lowerBound)).upperBound))
            }
        }
        switch prepared {
        case .comparison(let model):
            // Previous-box radii and forcing certificates remain safe upper bounds for the subset.
            return .comparison(ComparisonPrepared(parasitics: model.parasitics, sources: sources,
                receiverLoads: model.receiverLoads, endpointRows: model.endpointRows, endpointSource: model.endpointSource,
                sourceIndices: model.sourceIndices, dynamicRows: model.dynamicRows, reconstruction: model.reconstruction,
                operatorA: model.operatorA, forcingJ: model.forcingJ, comparison: model.comparison, weight: model.weight,
                alpha: model.alpha, radius: model.radius, voltageError: model.voltageError, sourceSlopes: slopes,
                dcIncidence: model.dcIncidence, thresholds: model.thresholds, options: model.options,
                numerics: model.numerics, sourceCertificates: model.sourceCertificates, sourceHistories: model.sourceHistories))
        case .residual(let model):
            return .residual(ResidualPrepared(parasitics: model.parasitics, sources: sources,
                receiverLoads: model.receiverLoads, endpointRows: model.endpointRows, endpointSource: model.endpointSource,
                sourceIndices: model.sourceIndices, sourceSlopes: slopes, dcIncidence: model.dcIncidence,
                thresholds: model.thresholds, options: model.options, numerics: model.numerics, facts: model.facts,
                sourceHistories: model.sourceHistories))
        }
    }

    func addingSourceHistory(prepared: Prepared, histories: [E: NativeSTAConservativeSourceHistory],
        work: inout UInt64) throws -> Prepared {
        let old: [E: NativeSTAConservativeSourceHistory], sources: [Source], indices: [E: Int]
        let numerical: N, thresholds: TimingCharacterizationThresholds
        switch prepared {
        case .comparison(let model):
            old = model.sourceHistories; sources = model.sources; indices = model.sourceIndices
            numerical = model.numerics; thresholds = model.thresholds
        case .residual(let model):
            old = model.sourceHistories; sources = model.sources; indices = model.sourceIndices
            numerical = model.numerics; thresholds = model.thresholds
        }
        try numerical.tick(&work)
        guard !histories.isEmpty else { return prepared }
        let capacity = old.count.addingReportingOverflow(histories.count)
        guard !capacity.overflow else { throw NativeSTAConservativeCouplingError.invalidPrimitive("source history inventory overflow") }
        try numerical.slots(capacity.partialValue, times: 10)
        var merged = old, periods: [String: Double] = [:]
        for value in old.values {
            try numerical.tick(&work)
            if case .clock(let clock) = value { periods[clock.rootIdentity] = clock.period }
        }
        for (endpoint, history) in histories {
            try numerical.tick(&work)
            guard let index = indices[endpoint], sources.indices.contains(index), sources[index].endpoint == endpoint,
                  case .dynamic = sources[index] else {
                throw NativeSTAConservativeCouplingError.invalidSourceAuthority("history has no canonical dynamic source")
            }
            switch history {
            case .clock(let clock):
                guard !clock.rootIdentity.isEmpty, clock.period.isFinite, clock.period > 0,
                      clock.riseReference.lowerBound.isFinite, clock.riseReference.upperBound.isFinite,
                      clock.fallReference.lowerBound.isFinite, clock.fallReference.upperBound.isFinite else {
                    throw NativeSTAConservativeCouplingError.invalidSourceAuthority("invalid periodic source history")
                }
                if let period = periods[clock.rootIdentity], period != clock.period {
                    throw NativeSTAConservativeCouplingError.invalidSourceAuthority("source histories disagree on root period")
                }
                periods[clock.rootIdentity] = clock.period
                try numerical.tick(&work, 4)
                let ramps = try clock.ramps(source: sources[index], thresholds: thresholds)
                let nextRise = try ramps.rise.start.adding(I(point: clock.period))
                guard ramps.rise.end.upperBound < ramps.fall.start.lowerBound,
                      ramps.fall.end.upperBound < nextRise.lowerBound else {
                    throw NativeSTAConservativeCouplingError.invalidSourceAuthority("periodic source ramps are not strictly separated")
                }
                if let previous = old[endpoint] {
                    guard case .clock(let prior) = previous, clock.rootIdentity == prior.rootIdentity,
                          clock.period == prior.period,
                          clock.riseReference.lowerBound >= prior.riseReference.lowerBound,
                          clock.riseReference.upperBound <= prior.riseReference.upperBound,
                          clock.fallReference.lowerBound >= prior.fallReference.lowerBound,
                          clock.fallReference.upperBound <= prior.fallReference.upperBound else {
                        throw NativeSTAConservativeCouplingError.invalidSourceAuthority("source clock history is not a restriction")
                    }
                }
            case .minimumPlateau(let seconds):
                guard seconds.isFinite, seconds > 0 else {
                    throw NativeSTAConservativeCouplingError.invalidSourceAuthority("invalid source minimum plateau")
                }
                if let previous = old[endpoint] {
                    guard case .minimumPlateau(let prior) = previous, seconds >= prior else {
                        throw NativeSTAConservativeCouplingError.invalidSourceAuthority("source plateau history is not a restriction")
                    }
                }
            }
            merged[endpoint] = history
        }
        try numerical.tick(&work, 0)
        switch prepared {
        case .comparison(let model):
            return .comparison(ComparisonPrepared(parasitics: model.parasitics, sources: model.sources,
                receiverLoads: model.receiverLoads, endpointRows: model.endpointRows, endpointSource: model.endpointSource,
                sourceIndices: model.sourceIndices, dynamicRows: model.dynamicRows, reconstruction: model.reconstruction,
                operatorA: model.operatorA, forcingJ: model.forcingJ, comparison: model.comparison, weight: model.weight,
                alpha: model.alpha, radius: model.radius, voltageError: model.voltageError, sourceSlopes: model.sourceSlopes,
                dcIncidence: model.dcIncidence, thresholds: model.thresholds, options: model.options,
                numerics: model.numerics, sourceCertificates: model.sourceCertificates, sourceHistories: merged))
        case .residual(let model):
            return .residual(ResidualPrepared(parasitics: model.parasitics, sources: model.sources,
                receiverLoads: model.receiverLoads, endpointRows: model.endpointRows, endpointSource: model.endpointSource,
                sourceIndices: model.sourceIndices, sourceSlopes: model.sourceSlopes, dcIncidence: model.dcIncidence,
                thresholds: model.thresholds, options: model.options, numerics: model.numerics, facts: model.facts,
                sourceHistories: merged))
        }
    }

    func residualReceiverRows(receiverLoads: [E: Double],
        endpointRows: [E: Int], numerical: N, work: inout UInt64) throws -> [Int] {
        var selected: Set<Int> = []
        func select(_ endpoint: E) throws {
            try numerical.tick(&work)
            // Prescribed terminals and their exact ideal aliases need no trajectory certificate.
            guard let row = endpointRows[endpoint], !selected.contains(row) else { return }
            try numerical.slots(1); selected.insert(row)
        }
        // The host includes every queried terminal, including zero-load outputs; SPEF connections also contain internal nodes.
        for endpoint in receiverLoads.keys { try select(endpoint) }
        try numerical.slots(selected.count)
        return try selected.sorted { left, right in try numerical.tick(&work); return left < right }
    }

    private func residualTimes(reduced: NativeSTAConservativeSparseGraph.Reduced, sources: [Source],
        thresholds: TimingCharacterizationThresholds, numerical: N, work: inout UInt64) throws -> [Double] {
        let rise = try thresholdSpan(thresholds, rising: true), fall = try thresholdSpan(thresholds, rising: false)
        let riseSpan = rise.lowerBound / 2 + rise.upperBound / 2
        let fallSpan = fall.lowerBound / 2 + fall.upperBound / 2
        var minimumRail = Double.greatestFiniteMagnitude, maximumRail = 0.0
        for source in sources {
            try numerical.tick(&work)
            guard case .dynamic(_, _, let r, let f) = source else { continue }
            let lower = min(r.lowerBound / riseSpan, f.lowerBound / fallSpan)
            let upper = max(r.upperBound / riseSpan, f.upperBound / fallSpan)
            guard lower.isFinite, lower > 0, upper.isFinite, upper > 0 else {
                throw NativeSTAConservativeCandidateNotCertified(reason: "residual proposal full-rail time is not finite and positive")
            }
            minimumRail = min(minimumRail, lower); maximumRail = max(maximumRail, upper)
        }
        var minimumScale = minimumRail
        for row in 0..<reduced.capacitance.rows {
            var c = 0.0, g = 0.0
            for offset in reduced.capacitance.rowOffsets[row]..<reduced.capacitance.rowOffsets[row + 1] {
                try numerical.tick(&work)
                if reduced.capacitance.columnIndices[offset] == row {
                    let value = reduced.capacitance.values[offset]; c = value.lowerBound / 2 + value.upperBound / 2
                }
            }
            for offset in reduced.conductance.rowOffsets[row]..<reduced.conductance.rowOffsets[row + 1] {
                try numerical.tick(&work)
                if reduced.conductance.columnIndices[offset] == row {
                    let value = reduced.conductance.values[offset]; g = value.lowerBound / 2 + value.upperBound / 2
                }
            }
            let scale = c / g
            if scale.isFinite, scale > 0 { minimumScale = min(minimumScale, scale) }
        }
        let seed = minimumScale * Double.ulpOfOne, horizon = 2 * maximumRail
        guard seed.isFinite, seed > 0, horizon.isFinite, horizon > 0 else {
            throw NativeSTAConservativeCandidateNotCertified(reason: "residual proposal grid scale is not finite and positive")
        }
        try numerical.tick(&work, 2); try numerical.slots(2)
        var times = [0.0, min(seed, horizon)]
        while times[times.count - 1] < horizon {
            try numerical.tick(&work)
            let previous = times[times.count - 1], next = min(previous * (6.0 / 5.0).squareRoot().squareRoot(), horizon)
            guard next.isFinite, next > previous else {
                throw NativeSTAConservativeCandidateNotCertified(reason: "residual proposal grid cannot make finite progress")
            }
            try numerical.slots(1); times.append(next)
        }
        return times
    }

    func thresholdSpan(_ thresholds: TimingCharacterizationThresholds, rising: Bool) throws -> I {
        let lower = rising ? thresholds.slewLowerRise : thresholds.slewLowerFall
        let upper = rising ? thresholds.slewUpperRise : thresholds.slewUpperFall
        guard lower.isFinite, upper.isFinite, 0 < lower, lower < upper, upper < 100 else {
            throw NativeSTAConservativeCouplingError.invalidSourceAuthority("invalid slew threshold span")
        }
        return try I(point: upper).subtracting(I(point: lower)).divided(by: I(point: 100))
    }

    private func invariantRadius(f: S.CSR, w: N.Matrix, forcing: N.Matrix, numerical: N, maximumIterations: Int,
        work: inout UInt64) throws -> N.Matrix {
        let solver = S(numerical: numerical)
        let negativeF = try solver.negated(f, work: &work)
        let negativeFw = try solver.product(negativeF, w, work: &work)
        let proposed = try solver.approximateSolve(negativeF, forcing, maximumIterations: maximumIterations, work: &work)
        var radius = try numerical.matrix(f.rows, 1)
        for i in 0..<f.rows {
            try numerical.tick(&work)
            guard negativeFw[i, 0].lowerBound > 0 else { throw NativeSTAConservativeCandidateNotCertified(reason: "invalid invariant comparison") }
            let positive = max(0, proposed[i, 0].upperBound)
            radius[i, 0] = try I(point: I(point: positive).multiplied(by: I(point: 2)).upperBound)
        }
        // Componentwise solves retain sparse source influence. A verified w correction
        // repairs outward-rounding residuals without filling all components at full scale.
        let initial = try solver.product(negativeF, radius, work: &work)
        var correction = 0.0
        for i in 0..<f.rows {
            try numerical.tick(&work)
            let deficit = try forcing[i, 0].subtracting(initial[i, 0])
            if deficit.upperBound > 0 {
                correction = max(correction, try I(point: deficit.upperBound).divided(by: negativeFw[i, 0]).upperBound)
            }
        }
        if correction > 0 {
            let slack = try I(point: correction).multiplied(by: I(point: 2))
            for i in 0..<f.rows {
                try numerical.tick(&work)
                radius[i, 0] = try I(point: radius[i, 0].adding(w[i, 0].multiplied(by: slack)).upperBound)
            }
        }
        let admitted = try solver.product(negativeF, radius, work: &work)
        for i in 0..<f.rows {
            try numerical.tick(&work)
            guard admitted[i, 0].lowerBound >= forcing[i, 0].upperBound else { throw NativeSTAConservativeCandidateNotCertified(reason: "invariant radius inequality failed") }
        }
        return radius
    }
}

extension NativeSTAConservativeCoupling {
    func bounds(prepared: Prepared, source: E, sink: E, edge: TimingEdge,
        sourceSlew: ClosedRange<Double>, work: inout UInt64) throws -> Bounds {
        switch prepared {
        case .comparison(let model):
            return try comparisonBounds(prepared: model, source: source, sink: sink, edge: edge,
                sourceSlew: sourceSlew, work: &work)
        case .residual(let model):
            return try NativeSTAConservativeResidualResponse(numerical: model.numerics)
                .bounds(prepared: model, source: source, sink: sink, edge: edge, sourceSlew: sourceSlew, work: &work)
        }
    }

    private func comparisonBounds(prepared: ComparisonPrepared, source: E, sink: E, edge: TimingEdge,
        sourceSlew: ClosedRange<Double>, work: inout UInt64) throws -> Bounds {
        let numerical = prepared.numerics
        try numerical.tick(&work); try numerical.slots(8)
        guard let sourceColumn = prepared.sourceIndices[source],
              let sinkSource = prepared.endpointSource[sink], sinkSource == sourceColumn else {
            throw NativeSTAConservativeCouplingError.invalidPrimitive("requested source/receiver has no canonical resistive binding")
        }
        guard case .dynamic(_, let sourceIsPort, let rise, let fall) = prepared.sources[sourceColumn] else {
            throw NativeSTAConservativeCouplingError.invalidSourceAuthority("constant source cannot have a transition")
        }
        guard edge == .rise || edge == .fall else { throw NativeSTAConservativeCouplingError.invalidSourceAuthority("unknown requested edge") }
        let rising = edge == .rise, admitted = rising ? rise : fall
        guard sourceSlew.lowerBound.isFinite, sourceSlew.upperBound.isFinite,
            sourceSlew.lowerBound >= admitted.lowerBound, sourceSlew.upperBound <= admitted.upperBound else {
            throw NativeSTAConservativeCouplingError.invalidSourceAuthority("requested slew outside global source domain")
        }
        let thresholds = prepared.thresholds
        let span = try thresholdSpan(thresholds, rising: rising)
        let slope = try span.divided(by: I(sourceSlew))
        let physicalLower = try I(point: rising ? thresholds.slewLowerRise : thresholds.slewLowerFall).divided(by: I(point: 100))
        let physicalUpper = try I(point: rising ? thresholds.slewUpperRise : thresholds.slewUpperFall).divided(by: I(point: 100))
        let lower = rising ? physicalLower : try I(point: 1).subtracting(physicalUpper)
        let upper = rising ? physicalUpper : try I(point: 1).subtracting(physicalLower)
        let physicalReceiver = try I(point: rising ? thresholds.inputRise : thresholds.inputFall).divided(by: I(point: 100))
        let physicalDriver = try I(point: sourceIsPort
            ? (rising ? thresholds.inputRise : thresholds.inputFall)
            : (rising ? thresholds.outputRise : thresholds.outputFall)).divided(by: I(point: 100))
        let receiverThreshold = rising ? physicalReceiver : try I(point: 1).subtracting(physicalReceiver)
        let driverThreshold = rising ? physicalDriver : try I(point: 1).subtracting(physicalDriver)
        let row = prepared.endpointRows[sink]
        let error = row.map { prepared.voltageError[$0, 0].upperBound } ?? 0
        guard error < lower.lowerBound, error < 1 - upper.upperBound,
              error < receiverThreshold.lowerBound, error < 1 - receiverThreshold.upperBound else {
            throw NativeSTAConservativeCouplingError.unprovedCrossing(source: source, sink: sink, edge: edge)
        }
        let errorInterval = try I(lowerBound: -error, upperBound: error)
        let delay = try receiverThreshold.subtracting(driverThreshold).adding(errorInterval).divided(by: slope)
        let twiceError = try I(point: error).multiplied(by: I(point: 2))
        let slewTime = try span.adding(I(lowerBound: -twiceError.upperBound, upperBound: twiceError.upperBound)).divided(by: slope)
        if row == nil || prepared.dynamicRows.isEmpty {
            let analyticalSlew = sourceSlew
            guard delay.lowerBound.isFinite, delay.upperBound.isFinite else { throw NativeSTAConservativeCouplingError.inconsistentBounds("nonfinite analytical delay") }
            return Bounds(delay: delay.lowerBound...delay.upperBound, slew: analyticalSlew,
                voltageErrorUpperBound: 0, minimumCrossingDerivative: slope.lowerBound,
                maximumAbsoluteDerivative: slope.upperBound, admittedSourceSlew: admitted)
        }
        let d = prepared.operatorA.rows, receiverRow = row!
        let solver = S(numerical: numerical)
        let absA = try solver.magnitude(prepared.operatorA, work: &work)
        let absT = try solver.magnitude(prepared.reconstruction, work: &work)
        let sourceCertificates = try prepared.sourceCertificates ?? separatedCertificates(a: prepared.operatorA, j: prepared.forcingJ,
            f: prepared.comparison, w: prepared.weight, slopes: prepared.sourceSlopes, options: prepared.options,
            numerical: numerical, work: &work)
        let ownRadius = try column(sourceCertificates.ownRadius, sourceColumn, numerical: numerical, work: &work)
        let aggressorRadius = try column(sourceCertificates.aggressorRadius, sourceColumn, numerical: numerical, work: &work)
        let aggressorForcing = try column(sourceCertificates.aggressorForcing, sourceColumn, numerical: numerical, work: &work)
        var equilibrium = try column(sourceCertificates.unitEquilibrium, sourceColumn, numerical: numerical, work: &work)
        for i in 0..<d { try numerical.tick(&work); equilibrium[i, 0] = try equilibrium[i, 0].multiplied(by: slope) }
        var beta = 0.0
        for i in 0..<d {
            try numerical.tick(&work)
            beta = max(beta, try ownRadius[i, 0].adding(equilibrium[i, 0].absolute()).divided(by: prepared.weight[i, 0]).upperBound)
        }
        let earliestThreshold = try I(point: min(lower.lowerBound, receiverThreshold.lowerBound))
        let delta = try earliestThreshold.subtracting(I(point: error)).divided(by: slope)
        guard delta.lowerBound > 0 else { throw NativeSTAConservativeCouplingError.unprovedCrossing(source: source, sink: sink, edge: edge) }
        let stationaryAggressor = try solver.product(absA, aggressorRadius, work: &work)
        var aggressorDerivative = try numerical.matrix(d, 1)
        for i in 0..<d { try numerical.tick(&work); aggressorDerivative[i, 0] = try stationaryAggressor[i, 0].adding(aggressorForcing[i, 0]) }
        var minimumDerivative = 0.0, power = 1
        for _ in 0..<prepared.options.maximumCertificateAttempts {
            try numerical.tick(&work)
            let decay = try rationalDecayUpper(alpha: prepared.alpha, elapsed: delta.lowerBound, power: power, numerical: numerical, work: &work)
            var transient = try numerical.matrix(d, 1)
            for i in 0..<d {
                try numerical.tick(&work)
                transient[i, 0] = try prepared.weight[i, 0].multiplied(by: I(point: beta)).multiplied(by: I(point: decay))
            }
            var derivativeError = try solver.product(absA, transient, work: &work)
            for i in 0..<d { try numerical.tick(&work); derivativeError[i, 0] = try derivativeError[i, 0].adding(aggressorDerivative[i, 0]) }
            let receiverDerivativeError = try solver.product(absT, derivativeError, work: &work)
            minimumDerivative = try slope.subtracting(receiverDerivativeError[receiverRow, 0]).lowerBound
            if minimumDerivative > 0 { break }
            let next = power.multipliedReportingOverflow(by: 2)
            guard !next.overflow else { break }
            power = next.partialValue
        }
        guard minimumDerivative > 0 else { throw NativeSTAConservativeCouplingError.unprovedUniqueTransition(source: source, sink: sink, edge: edge) }
        let tj = try solver.product(prepared.reconstruction, dense(prepared.forcingJ, numerical: numerical, work: &work), work: &work)
        var direct = try dense(prepared.dcIncidence, numerical: numerical, work: &work)
        for i in direct.values.indices { try numerical.tick(&work); direct.values[i] = try direct.values[i].adding(tj.values[i]) }
        let directSlope = try numerical.product(numerical.magnitude(direct, work: &work), prepared.sourceSlopes, work: &work)
        let stateSlope = try solver.product(absT, solver.product(absA, prepared.radius, work: &work), work: &work)
        let maximumDerivative = try directSlope[receiverRow, 0].adding(stateSlope[receiverRow, 0]).upperBound
        guard maximumDerivative > 0 else { throw NativeSTAConservativeCouplingError.inconsistentBounds("nonpositive absolute derivative bound") }
        let minimumSlew = try span.divided(by: I(point: maximumDerivative)).lowerBound
        let slewLower = max(slewTime.lowerBound, minimumSlew)
        let slewUpper = slewTime.upperBound
        guard slewLower > 0, slewLower <= slewUpper else { throw NativeSTAConservativeCouplingError.inconsistentBounds("empty positive slew intersection") }
        return Bounds(delay: delay.lowerBound...delay.upperBound, slew: slewLower...slewUpper,
            voltageErrorUpperBound: error, minimumCrossingDerivative: minimumDerivative,
            maximumAbsoluteDerivative: maximumDerivative, admittedSourceSlew: admitted)
    }

    /// For x >= 0, (1 + x/n)^(-n) >= exp(-x); integer powers are enclosed outward.
    private func rationalDecayUpper(alpha: Double, elapsed: Double, power: Int, numerical: N, work: inout UInt64) throws -> Double {
        let x = try I(point: alpha).multiplied(by: I(point: elapsed))
        let base = try I(point: 1).adding(x.divided(by: I(point: Double(power))))
        var factor = try I(point: 1).divided(by: base), result = try I(point: 1), exponent = power
        while exponent > 0 {
            try numerical.tick(&work)
            if exponent & 1 == 1 { result = try result.multiplied(by: factor) }
            exponent /= 2
            if exponent > 0 { factor = try factor.multiplied(by: factor) }
        }
        return min(1, result.upperBound)
    }
}

extension NativeSTAConservativeCoupling {
    private func iterations(_ dimension: Int, options: STAConservativeCoupledRCOptions) throws -> Int {
        let count = max(1, dimension).multipliedReportingOverflow(by: options.maximumBasisSweeps)
        guard !count.overflow else { throw NativeSTAConservativeCouplingError.invalidPrimitive("sparse iteration bound overflow") }
        return max(1, count.partialValue)
    }

    private func sparse(_ matrix: N.Matrix, numerical: N, work: inout UInt64) throws -> S.CSR {
        try numerical.slots(matrix.rows)
        var rows = Array(repeating: [Int: I](), count: matrix.rows)
        for i in 0..<matrix.rows { for j in 0..<matrix.columns {
            try numerical.tick(&work)
            let value = matrix[i, j]
            if value.lowerBound != 0 || value.upperBound != 0 { try numerical.slots(3); rows[i][j] = value }
        } }
        return try S(numerical: numerical).fromRows(rows, columns: matrix.columns, work: &work)
    }

    private func dense(_ matrix: S.CSR, numerical: N, work: inout UInt64) throws -> N.Matrix {
        var result = try numerical.matrix(matrix.rows, matrix.columns)
        for i in 0..<matrix.rows { for offset in matrix.rowOffsets[i]..<matrix.rowOffsets[i + 1] {
            try numerical.tick(&work); result[i, matrix.columnIndices[offset]] = matrix.values[offset]
        } }
        return result
    }

    private func column(_ matrix: N.Matrix, _ index: Int, numerical: N, work: inout UInt64) throws -> N.Matrix {
        var result = try numerical.matrix(matrix.rows, 1)
        for i in 0..<matrix.rows { try numerical.tick(&work); result[i, 0] = matrix[i, index] }
        return result
    }

    private func prepareSparse(operators: NativeSTAConservativeSparseGraph.Operators,
        parasitics: TimingParasitics, sources: [Source], receiverLoads: [E: Double], rows: [E: Int],
        endpointSource: [E: Int], sourceIndex: [E: Int], slopes: N.Matrix,
        thresholds: TimingCharacterizationThresholds, options: STAConservativeCoupledRCOptions,
        numerical: N, monotoneWeight: Bool, work: inout UInt64) throws -> ComparisonPrepared {
        let solver = S(numerical: numerical), d = operators.a.rows
        try numerical.slots(d)
        var comparisonRows = Array(repeating: [Int: I](), count: d)
        for i in 0..<d { for offset in operators.a.rowOffsets[i]..<operators.a.rowOffsets[i + 1] {
            try numerical.tick(&work); try numerical.slots(3)
            let j = operators.a.columnIndices[offset], value = operators.a.values[offset]
            comparisonRows[i][j] = try I(point: i == j ? value.upperBound : value.absolute().upperBound)
        } }
        let f = try solver.fromRows(comparisonRows, columns: d, work: &work)
        if d == 0 {
            return ComparisonPrepared(parasitics: parasitics, sources: sources, receiverLoads: receiverLoads, endpointRows: rows,
                endpointSource: endpointSource, sourceIndices: sourceIndex, dynamicRows: operators.dynamicRows,
                reconstruction: operators.reconstruction, operatorA: operators.a, forcingJ: operators.j,
                comparison: f, weight: try numerical.matrix(0, 1), alpha: 1, radius: try numerical.matrix(0, 1),
                voltageError: try numerical.matrix(operators.reconstruction.rows, 1), sourceSlopes: slopes,
                dcIncidence: operators.dcIncidence, thresholds: thresholds, options: options, numerics: numerical)
        }
        var ones = try numerical.matrix(d, 1)
        for i in 0..<d { try numerical.tick(&work); ones[i, 0] = try I(point: 1) }
        let maximumIterations = try iterations(d, options: options)
        let certificate = try certifiedSparseWeight(comparison: f, ones: ones, monotoneWeight: monotoneWeight,
            maximumIterations: maximumIterations, numerical: numerical, work: &work)
        let w = certificate.weight, alpha = certificate.alpha
        let forcing = try solver.product(solver.magnitude(operators.j, work: &work), slopes, work: &work)
        let radius = try invariantRadius(f: f, w: w, forcing: forcing, numerical: numerical,
            maximumIterations: maximumIterations, work: &work)
        let error = try solver.product(solver.magnitude(operators.reconstruction, work: &work), radius, work: &work)
        let certificates = try separatedCertificates(a: operators.a, j: operators.j, f: f, w: w,
            slopes: slopes, options: options, numerical: numerical, work: &work)
        return ComparisonPrepared(parasitics: parasitics, sources: sources, receiverLoads: receiverLoads, endpointRows: rows,
            endpointSource: endpointSource, sourceIndices: sourceIndex, dynamicRows: operators.dynamicRows,
            reconstruction: operators.reconstruction, operatorA: operators.a, forcingJ: operators.j,
            comparison: f, weight: w, alpha: alpha, radius: radius, voltageError: error, sourceSlopes: slopes,
            dcIncidence: operators.dcIncidence, thresholds: thresholds, options: options, numerics: numerical,
            sourceCertificates: certificates)
    }

    /// The whitening portfolio retains both finite proposals under one unchanged outward gate.
    func certifiedSparseWeight(comparison f: S.CSR, ones: N.Matrix, monotoneWeight: Bool,
        maximumIterations: Int, numerical: N, work: inout UInt64) throws -> (weight: N.Matrix, alpha: Double) {
        let solver = S(numerical: numerical)
        if monotoneWeight {
            if let witness = try NativeSTAConservativeWeightDiagnostic.principalWitness(
                comparison: f, numerical: numerical, work: &work) {
                throw NativeSTAConservativeCandidateNotCertified(reason: "principal comparison proved non-Hurwitz [\(witness)]")
            }
        }
        do {
            let proposed = try solver.approximateSolve(solver.negated(f, work: &work), ones,
                maximumIterations: maximumIterations, work: &work)
            return try admitSparseWeight(proposed, comparison: f, numerical: numerical, work: &work)
        } catch let first as NativeSTAConservativeCandidateNotCertified {
            guard monotoneWeight else { throw first }
            try numerical.slots(2)
            do {
                let proposed = try solver.comparisonWeightCandidate(f, maximumIterations: maximumIterations, work: &work)
                return try admitSparseWeight(proposed, comparison: f, numerical: numerical, work: &work)
            } catch let second as NativeSTAConservativeCandidateNotCertified {
                throw NativeSTAConservativeCandidateNotCertified(reason:
                    "whitening weight candidates exhausted [BiCG: \(first.reason) | GS: \(second.reason)]")
            }
        }
    }

    private func admitSparseWeight(_ w: N.Matrix, comparison f: S.CSR,
        numerical: N, work: inout UInt64) throws -> (weight: N.Matrix, alpha: Double) {
        let solver = S(numerical: numerical)
        for i in 0..<f.rows {
            try numerical.tick(&work)
            guard w[i, 0].lowerBound > 0, w[i, 0].lowerBound == w[i, 0].upperBound else {
                let diagnostic = try NativeSTAConservativeWeightDiagnostic.evaluate(comparison: f, candidate: w,
                    numerical: numerical, work: &work)
                throw NativeSTAConservativeCandidateNotCertified(reason: "sparse comparison weight not positive [\(diagnostic) transformedCoordinateRow=\(diagnostic.minimumWeightRow)]")
            }
        }
        let fw = try solver.product(f, w, work: &work)
        var alpha = Double.greatestFiniteMagnitude
        for i in 0..<f.rows {
            try numerical.tick(&work)
            let ratio = try fw[i, 0].negated().divided(by: w[i, 0])
            guard ratio.lowerBound > 0 else { throw NativeSTAConservativeCandidateNotCertified(reason: "sparse comparison stability inequality failed") }
            alpha = min(alpha, ratio.lowerBound)
        }
        return (w, alpha)
    }

    private func separatedCertificates(a: S.CSR, j: S.CSR, f: S.CSR, w: N.Matrix,
        slopes: N.Matrix, options: STAConservativeCoupledRCOptions, numerical: N,
        work: inout UInt64) throws -> SourceCertificates {
        let solver = S(numerical: numerical), d = a.rows, s = j.columns
        let maximumIterations = try iterations(d, options: options)
        let magnitudes = try dense(solver.magnitude(j, work: &work), numerical: numerical, work: &work)
        var sourceForcing = try numerical.matrix(d, s), aggressorForcing = try numerical.matrix(d, s)
        for i in 0..<d { for source in 0..<s {
            try numerical.tick(&work)
            sourceForcing[i, source] = try magnitudes[i, source].multiplied(by: slopes[source, 0])
        } }
        // Sum other forcings directly: independently rounded upper radii are never subtracted.
        for i in 0..<d { for source in 0..<s { for other in 0..<s where other != source {
            try numerical.tick(&work)
            aggressorForcing[i, source] = try aggressorForcing[i, source].adding(sourceForcing[i, other])
        } } }
        var own = try numerical.matrix(d, s), aggressor = try numerical.matrix(d, s)
        for source in 0..<s {
            let ownColumn = try invariantRadius(f: f, w: w, forcing: column(sourceForcing, source, numerical: numerical, work: &work),
                numerical: numerical, maximumIterations: maximumIterations, work: &work)
            let aggressorColumn = try invariantRadius(f: f, w: w, forcing: column(aggressorForcing, source, numerical: numerical, work: &work),
                numerical: numerical, maximumIterations: maximumIterations, work: &work)
            for i in 0..<d { try numerical.tick(&work); own[i, source] = ownColumn[i, 0]; aggressor[i, source] = aggressorColumn[i, 0] }
        }
        let rhs = try numerical.negated(dense(j, numerical: numerical, work: &work), work: &work)
        let equilibrium = try solver.verifiedSolve(a, rhs, comparison: f, weight: w,
            maximumIterations: maximumIterations, work: &work)
        return SourceCertificates(ownRadius: own, aggressorRadius: aggressor,
            unitEquilibrium: equilibrium, aggressorForcing: aggressorForcing)
    }
}
