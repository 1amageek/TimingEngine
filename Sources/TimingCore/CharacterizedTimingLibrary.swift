public struct CharacterizedTimingLibrary: Sendable {
    private let library: TimingLibrary
    private let propagationCells: Set<String>
    private let capacitanceSources: [String: [String: TimingCapacitanceSource]]
    public let thresholds: TimingCharacterizationThresholds
    /// Attribute names resolved using the Liberty R-2020.09 normative default.
    public let standardDefaultAttributes: Set<String>

    // Only source admission constructs this immutable value; canonical JSON does not.
    init(
        admitted library: TimingLibrary, thresholds: TimingCharacterizationThresholds,
        standardDefaultAttributes: Set<String>, propagationCells: Set<String>,
        capacitanceSources: [String: [String: TimingCapacitanceSource]]
    ) {
        self.library = library
        self.propagationCells = propagationCells
        self.capacitanceSources = capacitanceSources
        self.thresholds = thresholds
        self.standardDefaultAttributes = standardDefaultAttributes
    }

    public var name: String { library.name }

    public func pinCapacitance(cell: String, pin: String) throws -> Double {
        let model = try library.cell(named: cell)
        guard let input = model.pin(named: pin), input.direction == .input else {
            throw TimingCharacterizationError.unsupportedSemantic("input pin \(cell).\(pin)")
        }
        return input.capacitance
    }

    public func pinCapacitanceSource(cell: String, pin: String) throws -> TimingCapacitanceSource {
        _ = try pinCapacitance(cell: cell, pin: pin)
        guard let source = capacitanceSources[cell]?[pin] else {
            throw TimingCharacterizationError.missingSourceFact("capacitance origin \(cell).\(pin)")
        }
        return source
    }

    public func pinIsClock(cell: String, pin: String) throws -> Bool {
        let model = try library.cell(named: cell)
        guard let input = model.pin(named: pin), input.direction == .input else {
            throw TimingCharacterizationError.unsupportedSemantic("input pin \(cell).\(pin)")
        }
        return input.isClock
    }

    public func arcSense(cell: String, fromPin: String, toPin: String) throws -> TimingSense {
        try arc(cell: cell, fromPin: fromPin, toPin: toPin).sense
    }

    public func evaluate(
        cell: String, fromPin: String, toPin: String, edge: TimingEdge,
        inputSlew: Double, outputLoad: Double
    ) throws -> TimingCharacterizationSample {
        let model = try arc(cell: cell, fromPin: fromPin, toPin: toPin)
        // All edge tables must admit the operating point before any value is published.
        let riseDelay = try model.delayRise.lookupChecked(inputSlew: inputSlew, outputLoad: outputLoad)
        let fallDelay = try model.delayFall.lookupChecked(inputSlew: inputSlew, outputLoad: outputLoad)
        let riseSlew = try model.transitionRise.lookupChecked(inputSlew: inputSlew, outputLoad: outputLoad)
        let fallSlew = try model.transitionFall.lookupChecked(inputSlew: inputSlew, outputLoad: outputLoad)
        return TimingCharacterizationSample(
            delay: edge == .rise ? riseDelay : fallDelay,
            outputSlew: edge == .rise ? riseSlew : fallSlew
        )
    }

    private func arc(cell: String, fromPin: String, toPin: String) throws -> TimingArc {
        guard propagationCells.contains(cell) else {
            throw TimingCharacterizationError.unsupportedSemantic("capacitance-only cell \(cell)")
        }
        let matches = try library.cell(named: cell).arcs(from: fromPin, to: toPin)
        guard matches.count == 1, let model = matches.first else {
            if matches.isEmpty {
                throw TimingCharacterizationError.missingSourceFact("arc \(cell).\(fromPin)->\(toPin)")
            }
            throw TimingCharacterizationError.ambiguousSource("arc \(cell).\(fromPin)->\(toPin)")
        }
        return model
    }
}
