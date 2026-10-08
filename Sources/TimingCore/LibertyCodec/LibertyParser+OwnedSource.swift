extension LibertyParser {
    public func parseSource(_ bytes: borrowing Span<UInt8>, limits: LibertySourceParseLimits,
                            resources: any LibertySourceResourceAccounting)
        throws(LibertySourceError) -> OwnedLibertySource {
        do {
            try validate(bytes, resources: resources)
            let storage = try LibertyParseStorage.make(resources: resources)
            let result = try parseOwnedBody(bytes, limits: limits, storage: storage)
            // All lexical/tree/temporary local borrows have ended before their receipts are released.
            storage.releaseTemporary()
            try resources.check()
            return result
        } catch let error as LibertySourceError { throw error }
        catch let error as TimingError {
            if case .parseFailure(_, let line, _) = error { throw .syntax(line: line) }
            throw .syntax(line: 1)
        } catch let error as TimingCharacterizationError {
            switch error {
            case .ambiguousSource: throw .unsupportedSemantics("Ambiguous Liberty source")
            default: throw .unsupportedSemantics("Unsupported Liberty conversion")
            }
        } catch { throw .resource(error) }
    }

    private func parseOwnedBody(_ bytes: borrowing Span<UInt8>, limits: LibertySourceParseLimits,
                                storage: LibertyParseStorage) throws -> OwnedLibertySource {
        let original = try storage.bytes(bytes)
        let textLease = try storage.reserve(UInt8.self, capacity: original.count)
        try storage.step(UInt64(original.count))
        let source = original.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
        try storage.hold(source, receipt: textLease)
        var grammar = try LibertyGrammar(source: source, storage: storage,
            maximumNestingDepth: limits.maximumNestingDepth)
        let roots = try grammar.parse()
        for root in roots { try checkCoverageName(root.name, storage: storage) }
        guard roots.count == 1, roots[0].name == "library" else {
            throw LibertySourceError.unsupportedSemantics("Exactly one Liberty library is required")
        }
        try admitCoverage(roots, storage: storage)
        let parser = LibertyParser(storage: storage)
        let converted = try parser.convert(roots)
        var cells = LibertyBuffer<LibertySourceCell>()
        var conditions = LibertyBuffer<LibertySourceOperatingCondition>()
        for node in roots[0].children {
            try parser.checkText(node.name)
            if node.name == "cell" {
                guard let name = node.arguments.first else { throw LibertySourceError.syntax(line: node.sourceLine) }
                var pins = LibertyBuffer<LibertySourcePin>()
                for child in node.children {
                    try parser.checkText(child.name)
                    guard child.name == "pin" else { continue }
                    guard let pin = child.arguments.first else { throw LibertySourceError.syntax(line: child.sourceLine) }
                    for prior in pins {
                        try parser.checkText(prior.name); try parser.checkText(pin)
                        guard prior.name != pin else { throw LibertySourceError.unsupportedSemantics("Duplicate source pin") }
                    }
                    try pins.append(.init(name: pin, line: child.sourceLine, byteOffset: child.byteOffset), storage: storage)
                }
                try cells.append(.init(name: name, pins: pins.array(storage: storage), line: node.sourceLine,
                    byteOffset: node.byteOffset), storage: storage)
            } else if node.name == "operating_conditions" {
                let name = node.arguments.first ?? "default"
                for prior in conditions {
                    try parser.checkText(prior.name); try parser.checkText(name)
                    guard prior.name != name else { throw LibertySourceError.unsupportedSemantics("Duplicate operating condition") }
                }
                try parser.checkText(name)
                guard let condition = converted.library.operatingConditions[name] else {
                    throw LibertySourceError.syntax(line: node.sourceLine)
                }
                try conditions.append(.init(name: name, process: condition.process, voltage: condition.voltage,
                    temperature: condition.temperature, line: node.sourceLine, byteOffset: node.byteOffset), storage: storage)
            }
        }
        let cellFacts = try cells.array(storage: storage)
        let conditionFacts = try conditions.array(storage: storage)
        let metadata = try storage.reserve((TimingLibrary, [LibertySourceCell],
            [LibertySourceOperatingCondition], [UInt8], LibertyParseStorage, LibertySourceStorageReservation).self, capacity: 1)
        return OwnedLibertySource(library: converted.library, cells: cellFacts,
            operatingConditions: conditionFacts, bytes: original, storage: storage, metadata: metadata)
    }

    private func validate(_ bytes: borrowing Span<UInt8>, resources: any LibertySourceResourceAccounting) throws {
        var index = 0; var nonASCII = false
        while index < bytes.count {
            try resources.check(); try resources.chargeWork(1)
            let first = bytes[index]
            if first < 128 { index += 1; continue }
            nonASCII = true
            let length: Int
            let lower: UInt8
            let upper: UInt8
            switch first {
            case 0xC2...0xDF: length = 2; lower = 0x80; upper = 0xBF
            case 0xE0: length = 3; lower = 0xA0; upper = 0xBF
            case 0xE1...0xEC, 0xEE...0xEF: length = 3; lower = 0x80; upper = 0xBF
            case 0xED: length = 3; lower = 0x80; upper = 0x9F
            case 0xF0: length = 4; lower = 0x90; upper = 0xBF
            case 0xF1...0xF3: length = 4; lower = 0x80; upper = 0xBF
            case 0xF4: length = 4; lower = 0x80; upper = 0x8F
            default: throw LibertySourceError.invalidUTF8(byteOffset: index)
            }
            guard bytes.count - index >= length, bytes[index + 1] >= lower, bytes[index + 1] <= upper else {
                throw LibertySourceError.invalidUTF8(byteOffset: index)
            }
            for offset in 1..<length {
                try resources.check(); try resources.chargeWork(1)
                guard bytes[index + offset] >= 0x80, bytes[index + offset] <= 0xBF else {
                    throw LibertySourceError.invalidUTF8(byteOffset: index + offset)
                }
            }
            index += length
        }
        guard !nonASCII else { throw LibertySourceError.unsupportedSemantics("Cooperative Unicode Liberty lexing") }
        try resources.check()
    }

    private func admitCoverage(_ roots: [LibertyNode], storage: LibertyParseStorage) throws {
        var pending = LibertyBuffer<LibertyNode>()
        for root in roots { try pending.append(root, storage: storage) }
        while !pending.isEmpty {
            try storage.step()
            let node = pending.removeLast()
            try checkCoverageName(node.name, storage: storage)
            for child in node.children { try pending.append(child, storage: storage) }
        }
    }
    private func checkCoverageName(_ name: String, storage: LibertyParseStorage) throws {
        for _ in name.utf8 { try storage.step() }
        if name == "include" || name == "include_file" || name == "library_file" || name == "section" || name == "lib" {
            throw LibertySourceError.unsupportedSemantics("Liberty dependency or section semantics")
        }
    }
}
