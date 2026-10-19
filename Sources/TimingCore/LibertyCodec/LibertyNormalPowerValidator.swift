import LogicIR

/// Validates conditional power-down behavior from retained source, independently of engine policy.
public struct LibertyNormalPowerValidator: LibertyNormalPowerValidating {
    public init() {}

    public func requirements(source: borrowing OwnedLibertySource, cell name: String,
                             admit: (UInt64, Int, UInt64) throws -> Void)
        throws(LibertyNormalPowerError) -> LibertyNormalPowerRequirements {
        let resources = source.normalPowerResources
        let cell = try selected(source:source,name:name,resources:resources,admit:admit)
        let counts = try functionCounts(cell,resources:resources,admit:admit)
        let bytes = try add(try extent(LibertyNormalPowerFunctionOrigin.self,counts.functions),
            try extent((OwnedLibertySource, LibertySourceStorageReservation, String, Int, Int,
                        [LibertySourcePowerPin], [LibertyNormalPowerFunctionOrigin]).self,1))
        let reservation = try reserve(bytes:bytes,slots:try add(counts.functions,1),kind:.liveOwnedBytes,
            resources:resources,admit:admit)
        var origins: [LibertyNormalPowerFunctionOrigin] = []; origins.reserveCapacity(counts.functions)
        for (index,declaration) in cell.sequential.enumerated() {
            try step(resources:resources,admit:admit)
            if let function = declaration.powerDownFunction { origins.append(origin(declaration,index:index,function:function)) }
        }
        for pin in cell.pins {
            try step(resources:resources,admit:admit)
            if let function = pin.powerDownFunction { origins.append(origin(pin,function:function)) }
        }
        return .init(cell:cell,functions:origins,source:copy source,reservation:reservation)
    }

    public func validate(source: borrowing OwnedLibertySource, cell name: String, conditions: [LibertyPGCondition],
                         admit: (UInt64, Int, UInt64) throws -> Void)
        throws(LibertyNormalPowerError) -> CheckedLibertyNormalPower {
        let resources = source.normalPowerResources
        let cell = try selected(source:source,name:name,resources:resources,admit:admit)
        let counts = try functionCounts(cell,resources:resources,admit:admit)
        for (index,condition) in conditions.enumerated() {
            try step(resources:resources,admit:admit)
            var matched: LibertySourcePowerPin?
            for pin in cell.powerPins {
                if try equal(pin.name,condition.pin,resources:resources,admit:admit) { matched = pin }
            }
            guard let pin = matched else { throw .invalidPGCondition(condition.pin) }
            guard let type = pin.pgType, !type.isEmpty else { throw .missingPGType(pin.name) }
            guard try equal(type,condition.sourcePGType,resources:resources,admit:admit) else { throw .invalidPGCondition(condition.pin) }
            for earlier in 0..<index {
                if try equal(conditions[earlier].pin,condition.pin,resources:resources,admit:admit) {
                    throw .invalidPGCondition(condition.pin)
                }
            }
        }
        var bytes = try extent(LibertyNormalPowerReceipt.PGValue.self,cell.powerPins.count)
        bytes = try add(bytes,try extent(LibertyNormalPowerReceipt.FunctionSample.self,counts.functions))
        bytes = try add(bytes,try extent(LibertyNormalPowerReceipt.Query.self,counts.symbols))
        bytes = try add(bytes,try extent((OwnedLibertySource,LibertySourceStorageReservation,LibertyNormalPowerReceipt).self,1))
        let slots = try add(try add(cell.powerPins.count,counts.functions),try add(counts.symbols,1))
        let reservation = try reserve(bytes:bytes,slots:slots,kind:.liveOwnedBytes,resources:resources,admit:admit)
        var values: [LibertyNormalPowerReceipt.PGValue] = []; values.reserveCapacity(cell.powerPins.count)
        for pin in cell.powerPins {
            try step(resources:resources,admit:admit)
            guard let type = pin.pgType, !type.isEmpty else { throw .missingPGType(pin.name) }
            var value: Bool?
            for condition in conditions {
                if try equal(pin.name,condition.pin,resources:resources,admit:admit) { value = condition.value }
            }
            guard let value else { throw .missingPGValue(pin.name) }
            values.append(.init(condition:.init(pin:pin.name,sourcePGType:type,value:value),line:pin.line,byteOffset:pin.byteOffset))
        }
        var samples: [LibertyNormalPowerReceipt.FunctionSample] = []; samples.reserveCapacity(counts.functions)
        for (index,declaration) in cell.sequential.enumerated() {
            try step(resources:resources,admit:admit)
            if let function = declaration.powerDownFunction {
                samples.append(try evaluate(function,origin:origin(declaration,index:index,function:function),cell:cell,
                    values:values,resources:resources,admit:admit))
            }
        }
        for pin in cell.pins {
            try step(resources:resources,admit:admit)
            if let function = pin.powerDownFunction {
                samples.append(try evaluate(function,origin:origin(pin,function:function),cell:cell,
                    values:values,resources:resources,admit:admit))
            }
        }
        try check(resources)
        return .init(receipt:.init(cell:cell.name,cellLine:cell.line,cellByteOffset:cell.byteOffset,
            pgValues:values,functions:samples),source:copy source,reservation:reservation)
    }

    private func selected(source: borrowing OwnedLibertySource, name: String,
                          resources: any LibertySourceResourceAccounting, admit: (UInt64, Int, UInt64) throws -> Void)
        throws(LibertyNormalPowerError) -> LibertySourceCell {
        var selected: LibertySourceCell?
        for cell in source.cells {
            if try equal(cell.name,name,resources:resources,admit:admit) {
                guard selected == nil else { throw .ambiguousSource(name) }
                selected = cell
            }
        }
        guard let cell = selected else { throw .missingCell(name) }
        guard cell.unsupportedFunctionalGroups.isEmpty else { throw .unsupportedSource("Incomplete functional group coverage") }
        for (index,pin) in cell.powerPins.enumerated() {
            try step(resources:resources,admit:admit)
            guard !pin.name.isEmpty, let type = pin.pgType, !type.isEmpty else { throw .missingPGType(pin.name) }
            for earlier in 0..<index {
                if try equal(pin.name,cell.powerPins[earlier].name,resources:resources,admit:admit) { throw .ambiguousSource(pin.name) }
            }
            for signal in cell.pins {
                if try equal(pin.name,signal.name,resources:resources,admit:admit) { throw .ambiguousSource(pin.name) }
            }
        }
        return cell
    }

    private func functionCounts(_ cell: LibertySourceCell, resources: any LibertySourceResourceAccounting,
                                admit: (UInt64, Int, UInt64) throws -> Void)
        throws(LibertyNormalPowerError) -> (functions:Int,symbols:Int) {
        var functions = 0, symbols = 0
        for declaration in cell.sequential {
            try step(resources:resources,admit:admit)
            if let function = declaration.powerDownFunction {
                guard case .normalized(let facts) = function.content else { throw .unsupportedSource("Unnormalized declaration power-down function") }
                functions = try add(functions,1); symbols = try add(symbols,facts.symbols.count)
            }
        }
        for pin in cell.pins {
            try step(resources:resources,admit:admit)
            if let function = pin.powerDownFunction {
                guard case .normalized(let facts) = function.content else { throw .unsupportedSource("Unnormalized pin power-down function") }
                functions = try add(functions,1); symbols = try add(symbols,facts.symbols.count)
            }
        }
        return (functions,symbols)
    }

    private func evaluate(_ function: LibertySourceFunction, origin: LibertyNormalPowerFunctionOrigin,
                          cell: LibertySourceCell, values: [LibertyNormalPowerReceipt.PGValue],
                          resources: any LibertySourceResourceAccounting, admit: (UInt64, Int, UInt64) throws -> Void)
        throws(LibertyNormalPowerError) -> LibertyNormalPowerReceipt.FunctionSample {
        guard case .normalized(let facts) = function.content else { throw .unsupportedSource("Unnormalized power-down function") }
        var queries: [LibertyNormalPowerReceipt.Query] = []; queries.reserveCapacity(facts.symbols.count)
        for symbol in facts.symbols {
            try step(resources:resources,admit:admit)
            var binding: LibertyNormalPowerReceipt.Query.Binding?, value: Bool?
            for pg in values {
                if try equal(pg.condition.pin,symbol,resources:resources,admit:admit) { binding = .powerPin; value = pg.condition.value }
            }
            for pin in cell.pins {
                try step(resources:resources,admit:admit)
                guard pin.direction == .input else { continue }
                if try equal(pin.name,symbol,resources:resources,admit:admit) {
                    guard binding == nil else { throw .ambiguousSource(symbol) }
                    binding = .inputPin
                }
            }
            for declaration in cell.sequential {
                try step(resources:resources,admit:admit)
                for variable in declaration.variables {
                    if try equal(variable,symbol,resources:resources,admit:admit) {
                        guard binding == nil else { throw .ambiguousSource(symbol) }
                        binding = .stateVariable
                    }
                }
            }
            guard let binding else { throw .unsupportedSource("Unresolved or output-referencing power-down symbol") }
            queries.append(.init(symbol:symbol,binding:binding,domain:.binary,value:value))
        }
        let scratch = try reserve(bytes:try extent(LogicBit.self,facts.operations.count),slots:0,kind:.temporaryBytes,
            resources:resources,admit:admit)
        defer { withExtendedLifetime(scratch) {} }
        let result: LogicBit
        do {
            result = try LibertySourceBooleanEvaluation.evaluate(function,value:{ slot in
                queries[slot].value.map { $0 ? .one : .zero } ?? .unknown
            },admit:{ amount,slots in
                try step(amount,states:slots,resources:resources,admit:admit)
            },checkpoint:{ try check(resources) })
        } catch let failure as LibertySourceBooleanEvaluation.Failure {
            switch failure {
            case .unsupported: throw .unsupportedSource("Unnormalized power-down function")
            case .invalidProgram: throw .invalidProgram(origin)
            }
        } catch let failure as LibertyNormalPowerError { throw failure }
        catch { throw .resource(error) }
        switch result {
        case .zero: return .init(origin:origin,queries:queries,result:false)
        case .one: throw .poweredDown(origin)
        case .unknown, .highImpedance: throw .unknownPowerDown(origin)
        }
    }

    private func origin(_ pin: LibertySourcePin, function: LibertySourceFunction) -> LibertyNormalPowerFunctionOrigin {
        .init(owner:.pin(pin.name),ownerLine:pin.line,ownerByteOffset:pin.byteOffset,
            functionLine:function.line,functionByteOffset:function.byteOffset)
    }
    private func origin(_ declaration: LibertySourceSequential, index: Int, function: LibertySourceFunction) -> LibertyNormalPowerFunctionOrigin {
        .init(owner:.declaration(index:index,kind:declaration.kind),ownerLine:declaration.line,ownerByteOffset:declaration.byteOffset,
            functionLine:function.line,functionByteOffset:function.byteOffset)
    }
    private func equal(_ lhs: String, _ rhs: String, resources: any LibertySourceResourceAccounting,
                       admit: (UInt64, Int, UInt64) throws -> Void) throws(LibertyNormalPowerError) -> Bool {
        var a = lhs.utf8.makeIterator(), b = rhs.utf8.makeIterator()
        while true {
            try step(resources:resources,admit:admit)
            let x = a.next(), y = b.next()
            if x != y { return false }
            if x == nil { return true }
        }
    }
    private func check(_ resources: any LibertySourceResourceAccounting) throws(LibertyNormalPowerError) {
        do { try resources.check() } catch { throw .resource(error) }
    }
    private func step(_ amount: UInt64 = 1, states: Int = 0,
                      resources: any LibertySourceResourceAccounting, admit: (UInt64, Int, UInt64) throws -> Void)
        throws(LibertyNormalPowerError) {
        do { try resources.check(); try admit(amount,states,0); try resources.chargeWork(amount) }
        catch { throw .resource(error) }
    }
    private func reserve(bytes: UInt64, slots: Int, kind: LibertySourceStorageKind,
                         resources: any LibertySourceResourceAccounting, admit: (UInt64, Int, UInt64) throws -> Void)
        throws(LibertyNormalPowerError) -> LibertySourceStorageReservation {
        do {
            try resources.check(); try admit(0,slots,bytes)
            return try resources.reserveStorage(kind:kind,byteCount:bytes)
        } catch { throw .resource(error) }
    }
    private func extent<T>(_ type: T.Type, _ count: Int) throws(LibertyNormalPowerError) -> UInt64 {
        guard count >= 0 else { throw .arithmeticOverflow }
        let result = UInt64(count).multipliedReportingOverflow(by:UInt64(MemoryLayout<T>.stride))
        guard !result.overflow else { throw .arithmeticOverflow }; return result.partialValue
    }
    private func add(_ a: Int, _ b: Int) throws(LibertyNormalPowerError) -> Int {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw .arithmeticOverflow }; return result.partialValue
    }
    private func add(_ a: UInt64, _ b: UInt64) throws(LibertyNormalPowerError) -> UInt64 {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw .arithmeticOverflow }; return result.partialValue
    }
}
