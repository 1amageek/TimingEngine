import TimingCore

/// Exact primitive graph reduction; dense storage is confined to actual algebraic/C blocks.
internal struct NativeSTAConservativeSparseGraph {
    typealias N = NativeSTAConservativeNumerics
    typealias S = NativeSTAConservativeSparseNumerics
    typealias I = TimingNumericInterval
    typealias E = TimingParasitics.Endpoint
    struct Operators: Sendable {
        let dynamicRows: [Int]
        let a: S.CSR
        let j: S.CSR
        let reconstruction: S.CSR
        let dcIncidence: S.CSR
    }
    struct Reduced: Sendable {
        let dynamicRows: [Int]
        let conductance: S.CSR
        let capacitance: S.CSR
        let forcing: N.Matrix
        let reconstruction: S.CSR
        let dcIncidence: S.CSR
        let capBlocks: [[Int]]
    }
    let numerical: N

    func reduce(parasitics: TimingParasitics, originalIndex: [E: Int], ideal: [Int], idealSource: [Int: Int],
        rows: [E: Int], sourceIndex: [E: Int], receiverLoads: [E: Double],
        skipped: Set<TimingParasitics.SourceID>, dcIncidence: N.Matrix, work: inout UInt64) throws -> Reduced {
        let n = dcIncidence.rows, sources = dcIncidence.columns, solver = S(numerical: numerical)
        let zero = try I(point: 0)
        try numerical.slots(n, times: 4)
        var g = Array(repeating: [Int: I](), count: n), c = g
        var cs = try numerical.matrix(n, sources), gs = try numerical.matrix(n, sources)
        var positiveCap = Array(repeating: false, count: n)
        func add(_ value: I, row: Int, column: Int, to matrix: inout [[Int: I]]) throws {
            try numerical.tick(&work)
            if value.lowerBound == 0, value.upperBound == 0 { return }
            if let old = matrix[row][column] { matrix[row][column] = try old.adding(value) }
            else { try numerical.slots(3); matrix[row][column] = value }
        }
        func stamp(_ first: E, _ second: E?, value: I, capacitance: Bool) throws {
            try numerical.tick(&work)
            let ai = originalIndex[first]!, bi = second.flatMap { originalIndex[$0] }
            if let bi, ideal[ai] == ideal[bi] { return }
            let ar = rows[first], br = second.flatMap { rows[$0] }, negative = try value.negated()
            if capacitance {
                if let ar { try add(value, row: ar, column: ar, to: &c); if value.upperBound > 0 { positiveCap[ar] = true } }
                if let br { try add(value, row: br, column: br, to: &c); if value.upperBound > 0 { positiveCap[br] = true } }
                if let ar, let br { try add(negative, row: ar, column: br, to: &c); try add(negative, row: br, column: ar, to: &c) }
                else if let ar, let bi, let source = idealSource[ideal[bi]] { cs[ar, source] = try cs[ar, source].adding(negative) }
                else if let br, let source = idealSource[ideal[ai]] { cs[br, source] = try cs[br, source].adding(negative) }
            } else {
                if let ar { try add(value, row: ar, column: ar, to: &g) }
                if let br { try add(value, row: br, column: br, to: &g) }
                if let ar, let br { try add(negative, row: ar, column: br, to: &g); try add(negative, row: br, column: ar, to: &g) }
                else if let ar, let bi, let source = idealSource[ideal[bi]] { gs[ar, source] = try gs[ar, source].adding(negative) }
                else if let br, let source = idealSource[ideal[ai]] { gs[br, source] = try gs[br, source].adding(negative) }
            }
        }
        for net in parasitics.networks {
            for resistor in net.resistances where resistor.resistance > 0 {
                try stamp(resistor.first, resistor.second, value: I(point: 1).divided(by: I(point: resistor.resistance)), capacitance: false)
            }
            for cap in net.capacitances where !skipped.contains(cap.source) {
                try stamp(cap.first, cap.second, value: I(point: cap.capacitance), capacitance: true)
            }
        }
        for (endpoint, value) in receiverLoads {
            try numerical.tick(&work)
            guard originalIndex[endpoint] != nil, sourceIndex[endpoint] == nil, value.isFinite, value >= 0 else {
                throw NativeSTAConservativeCouplingError.invalidPrimitive("invalid receiver load binding")
            }
            try stamp(endpoint, nil, value: I(point: value), capacitance: true)
        }
        // Positive primitive R plus the already-verified one-driver connectivity proves G SPD.
        // Independently stamped source incidence also encloses the exact DC identity.
        let sparseG = try solver.fromRows(g, columns: n, work: &work)
        let dcProduct = try solver.product(sparseG, dcIncidence, work: &work)
        for i in dcProduct.values.indices {
            try numerical.tick(&work)
            let residual = try dcProduct.values[i].adding(gs.values[i])
            guard residual.lowerBound <= 0, residual.upperBound >= 0 else { throw NativeSTAConservativeCouplingError.invalidCertificate("sparse DC incidence identity failed") }
        }
        let sparseC = try solver.fromRows(c, columns: n, work: &work)
        var l = try solver.product(sparseC, dcIncidence, work: &work)
        for i in l.values.indices { try numerical.tick(&work); l.values[i] = try l.values[i].adding(cs.values[i]) }
        try numerical.slots(n, times: 4)
        var dynamic: [Int] = [], algebraic: [Int] = [], dynamicIndex = Array(repeating: -1, count: n)
        for i in 0..<n {
            try numerical.tick(&work)
            if positiveCap[i] { dynamicIndex[i] = dynamic.count; dynamic.append(i) } else { algebraic.append(i) }
        }
        let d = dynamic.count
        if d == 0 {
            try numerical.slots(n)
            return Reduced(dynamicRows: [], conductance: try solver.fromRows([], columns: 0, work: &work),
                capacitance: try solver.fromRows([], columns: 0, work: &work), forcing: try numerical.matrix(0, sources),
                reconstruction: try solver.fromRows(Array(repeating: [:], count: n), columns: 0, work: &work),
                dcIncidence: try csr(dcIncidence, solver: solver, work: &work), capBlocks: [])
        }
        try numerical.slots(d, times: 8)
        var reducedG = Array(repeating: [Int: I](), count: d)
        var reducedC = reducedG, reconstruction = Array(repeating: [Int: I](), count: n)
        var reducedL = try numerical.matrix(d, sources)
        for (i, old) in dynamic.enumerated() {
            try numerical.tick(&work)
            try add(I(point: 1), row: old, column: i, to: &reconstruction)
            for (column, value) in g[old] where dynamicIndex[column] >= 0 {
                try add(value, row: i, column: dynamicIndex[column], to: &reducedG)
            }
            for (column, value) in c[old] {
                guard dynamicIndex[column] >= 0 else { throw NativeSTAConservativeCouplingError.invalidCertificate("nonzero C incidence on algebraic row") }
                try add(value, row: i, column: dynamicIndex[column], to: &reducedC)
            }
            for j in 0..<sources { try numerical.tick(&work); reducedL[i, j] = l[old, j] }
        }
        try numerical.slots(n)
        var visited: Set<Int> = []
        for start in algebraic where !visited.contains(start) {
            try numerical.slots(1); visited.insert(start)
            var component = [start], cursor = 0
            while cursor < component.count {
                let row = component[cursor]; cursor += 1
                for (neighbor, value) in g[row] {
                    try numerical.tick(&work)
                    if neighbor != row, !positiveCap[neighbor], value.lowerBound != 0 || value.upperBound != 0,
                       visited.insert(neighbor).inserted {
                        try numerical.slots(2); component.append(neighbor)
                    }
                }
            }
            try numerical.slots(component.count)
            try component.sort { left, right in try numerical.tick(&work); return left < right }
            var boundarySet: Set<Int> = []
            for row in component { for column in g[row].keys {
                try numerical.tick(&work)
                if dynamicIndex[column] >= 0, !boundarySet.contains(column) { try numerical.slots(1); boundarySet.insert(column) }
            } }
            try numerical.slots(boundarySet.count)
            let boundary = try boundarySet.sorted { left, right in try numerical.tick(&work); return left < right }
            var gaa = try numerical.matrix(component.count, component.count)
            var gad = try numerical.matrix(component.count, boundary.count)
            for (i, row) in component.enumerated() {
                for (j, column) in component.enumerated() { try numerical.tick(&work); gaa[i, j] = g[row][column] ?? zero }
                for (j, column) in boundary.enumerated() { try numerical.tick(&work); gad[i, j] = g[row][column] ?? zero }
            }
            try numerical.positiveDefinite(gaa, work: &work)
            let elimination = try numerical.solve(gaa, gad, work: &work)
            for (i, old) in component.enumerated() { for (j, column) in boundary.enumerated() {
                try add(elimination[i, j].negated(), row: old, column: dynamicIndex[column], to: &reconstruction)
            } }
            for (i, row) in boundary.enumerated() { for (j, column) in boundary.enumerated() {
                var correction = zero
                for k in component.indices { try numerical.tick(&work); correction = try correction.adding(gad[k, i].multiplied(by: elimination[k, j])) }
                try add(correction.negated(), row: dynamicIndex[row], column: dynamicIndex[column], to: &reducedG)
            } }
        }
        // C-only connected components define exact independent inverse blocks; R does not join them.
        try numerical.slots(d, times: 3)
        var parent = Array(0..<d)
        func root(_ value: Int) throws -> Int {
            var node = value
            while parent[node] != node { try numerical.tick(&work); node = parent[node] }
            return node
        }
        for i in 0..<d { for (j, value) in reducedC[i] where j != i {
            try numerical.tick(&work)
            if value.lowerBound != 0 || value.upperBound != 0 {
                let a = try root(i), b = try root(j)
                if a != b { parent[max(a, b)] = min(a, b) }
            }
        } }
        var blocks: [Int: [Int]] = [:]
        for i in 0..<d { try numerical.tick(&work); let key = try root(i); blocks[key, default: []].append(i) }
        try numerical.slots(blocks.count, times: 2)
        let blockKeys = try blocks.keys.sorted { left, right in try numerical.tick(&work); return left < right }
        var capBlocks: [[Int]] = []
        capBlocks.reserveCapacity(blockKeys.count)
        for key in blockKeys {
            try numerical.tick(&work)
            let block = blocks[key]!
            var capacitance = try numerical.matrix(block.count, block.count)
            for (i, row) in block.enumerated() { for (j, column) in block.enumerated() {
                try numerical.tick(&work); capacitance[i, j] = reducedC[row][column] ?? zero
            } }
            try numerical.positiveDefinite(capacitance, capacitance: true, work: &work)
            capBlocks.append(block)
        }
        return Reduced(dynamicRows: dynamic,
            conductance: try solver.fromRows(reducedG, columns: d, work: &work),
            capacitance: try solver.fromRows(reducedC, columns: d, work: &work), forcing: reducedL,
            reconstruction: try solver.fromRows(reconstruction, columns: d, work: &work),
            dcIncidence: try csr(dcIncidence, solver: solver, work: &work), capBlocks: capBlocks)
    }

    private func csr(_ matrix: N.Matrix, solver: S, work: inout UInt64) throws -> S.CSR {
        try numerical.slots(matrix.rows)
        var rows = Array(repeating: [Int: I](), count: matrix.rows)
        for i in 0..<matrix.rows { for j in 0..<matrix.columns {
            try numerical.tick(&work)
            let value = matrix[i, j]
            if value.lowerBound != 0 || value.upperBound != 0 { try numerical.slots(3); rows[i][j] = value }
        } }
        return try solver.fromRows(rows, columns: matrix.columns, work: &work)
    }
}
