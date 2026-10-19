extension LibertyParser: LibertySourceCharacterizationParsing {
    public func parseCharacterizedSource(_ bytes: borrowing Span<UInt8>, cellNames: [String], propagationCellNames: [String], sequentialPropagationCellNames: [String] = [],
                                         limits: LibertySourceParseLimits, resources: any LibertySourceResourceAccounting)
        throws(LibertySourceError) -> CharacterizedTimingLibrary {
        do {
            try validate(bytes, resources: resources)
            let storage = try LibertyParseStorage.make(resources: resources)
            for names in [cellNames, propagationCellNames, sequentialPropagationCellNames] {
                for name in names { try storage.step(UInt64(name.utf8.count) + 1) }
            }
            let count = try LibertyParseStorage.add(try LibertyParseStorage.add(cellNames.count, propagationCellNames.count), sequentialPropagationCellNames.count)
            let selectionReceipt = try storage.reserve(String.self, capacity: count)
            func names(_ input: [String]) throws -> Set<String> {
                var result = Set<String>()
                result.reserveCapacity(input.count)
                for name in input { result.insert(try storage.text(name)) }
                return result
            }
            let selected = try names(cellNames), propagated = try names(propagationCellNames), sequential = try names(sequentialPropagationCellNames)
            guard !selected.isEmpty, !selected.contains(""), selected.count == cellNames.count,
                  propagated.count == propagationCellNames.count, sequential.count == sequentialPropagationCellNames.count,
                  propagated.isSubset(of: selected), sequential.isSubset(of: selected), propagated.isDisjoint(with: sequential) else {
                throw TimingCharacterizationError.invalidValue("selected cell names")
            }
            try storage.hold((selected, propagated, sequential), receipt: selectionReceipt)
            let original = try storage.bytes(bytes)
            let textReceipt = try storage.reserve(UInt8.self, capacity: original.count)
            try storage.step(UInt64(original.count))
            let text = original.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
            try storage.hold(text, receipt: textReceipt)
            var grammar = try LibertyGrammar(source: text, storage: storage, maximumNestingDepth: limits.maximumNestingDepth)
            let roots = try grammar.parse()
            guard roots.count == 1, roots[0].name == "library" else { throw LibertySourceError.unsupportedSemantics("Exactly one Liberty library is required") }
            let converted = try LibertyParser(storage: storage).convert(roots, strictCells: selected, propagationCells: propagated, sequentialPropagationCells: sequential)
            guard let thresholds = converted.thresholds else { throw TimingCharacterizationError.missingSourceFact("thresholds") }
            var library = converted.library
            var cells = LibertyMap<TimingCell>()
            for node in roots[0].children {
                try storage.step(UInt64(node.name.utf8.count) + 1)
                guard node.name == "cell", let name = node.arguments.first else { continue }
                try storage.step(UInt64(name.utf8.count) + 1)
                guard selected.contains(name), var cell = library.cells[name] else { continue }
                let facts = try LibertyFunctionalProjection(storage: storage, maximumNesting: limits.maximumNestingDepth).cell(node)
                if !facts.sequential.isEmpty {
                    cell.sequentialModel = try LibertySequentialBinding(storage: storage).model(facts, numerical: cell.sequentialModel)
                }
                try cells.set(cell, for: name, storage: storage)
            }
            library.cells = try cells.dictionary(storage: storage)
            let metadata = try storage.reserve(CharacterizedTimingLibrary.self, capacity: 1)
            let unionReceipt = try storage.reserve(String.self, capacity: propagated.count + sequential.count)
            let allPropagation = propagated.union(sequential)
            try storage.hold(allPropagation, receipt: unionReceipt)
            let result = CharacterizedTimingLibrary(admitted: library, thresholds: thresholds,
                standardDefaultAttributes: converted.defaults, propagationCells: allPropagation, capacitanceSources: converted.capacitanceSources,
                storage: storage, metadata: metadata)
            storage.releaseTemporary(); try resources.check()
            return result
        } catch let error as LibertySourceError { throw error }
        catch let error as TimingError { throw .conversion(error) }
        catch let error as TimingCharacterizationError { throw .conversion(error) }
        catch { throw .resource(error) }
    }
}
