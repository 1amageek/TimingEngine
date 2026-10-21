import Foundation

public struct SDCParser: TimingConstraintParsing {
    public var defaultTimeUnit: Double
    private var transform: TimingTextTransform?

    public init(defaultTimeUnit: Double = 1e-9) {
        self.defaultTimeUnit = defaultTimeUnit
    }

    public func parse(_ data: Data, modeID: String = "default") throws -> TimingConstraintSet {
        let source: String
        if let transform { source = try transform.source(data, format: "SDC") }
        else {
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw TimingError.parseFailure(format: "SDC", line: 1, message: "Input is not UTF-8.")
            }
            source = decoded
        }
        var result = TimingConstraintSet(modeID: modeID)
        var clocks = ArrayAdmission(), generatedAdmission = ArrayAdmission(), inputs = ArrayAdmission(), outputs = ArrayAdmission()
        var exceptions = ArrayAdmission(), paths = ArrayAdmission(), groups = ArrayAdmission(), caseAdmission = ArrayAdmission()
        let lines: [Substring]
        if let transform { lines = try transform.segments(source, omittingEmpty: true, separatedBy: \.isNewline) }
        else { lines = source.split(whereSeparator: \.isNewline) }
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            try transform?.storage.step()
            let line = try removeComment(text(rawLine, kind: .temporaryBytes))
            let trimmed: String
            if let transform { trimmed = try transform.trimmed(line) }
            else { trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !trimmed.isEmpty else { continue }
            let tokens = try tokenize(line)
            guard let command = tokens.first else { continue }
            switch command {
            case "create_clock":
                let clock = try parseClock(tokens, line: lineNumber)
                try append(clock, to: &result.clocks, admission: &clocks)
            case "create_generated_clock":
                let generated = try parseGeneratedClock(tokens, line: lineNumber)
                try append(generated, to: &result.generatedClocks, admission: &generatedAdmission)
            case "set_input_delay":
                for delay in try parsePortDelays(tokens, line: lineNumber) {
                    try transform?.storage.step(UInt64(result.inputDelays.count))
                    result.inputDelays.removeAll { $0.port == delay.port && $0.clock == delay.clock && $0.isMax == delay.isMax }
                    try append(delay, to: &result.inputDelays, admission: &inputs)
                }
            case "set_output_delay":
                for delay in try parsePortDelays(tokens, line: lineNumber) {
                    try transform?.storage.step(UInt64(result.outputDelays.count))
                    result.outputDelays.removeAll { $0.port == delay.port && $0.clock == delay.clock && $0.isMax == delay.isMax }
                    try append(delay, to: &result.outputDelays, admission: &outputs)
                }
            case "set_input_transition":
                result.defaultInputSlew = try parseGlobalInputTransition(tokens, line: lineNumber)
                result.inputTransition = .allInputsBothEdges(slew: result.defaultInputSlew)
            case "set_clock_transition":
                let targets = try primaryClockTargets(tokens, clocks: result.clocks, line: lineNumber)
                let flags = try filtered(tokens) { $0 == "-rise" || $0 == "-fall" }
                guard flags.count <= 1, tokens.count == (flags.isEmpty ? 3 : 4),
                      let raw = tokens.dropFirst().first(where: { !$0.hasPrefix("-") && !$0.hasPrefix("[") }) else {
                    throw TimingError.unsupportedSemantic(format: "SDC", semantic: "set_clock_transition options")
                }
                let value = try parseTime(raw, line: lineNumber)
                guard value.isFinite, value > 0 else { throw TimingError.invalidInput("Clock transitions must be finite and positive") }
                for index in targets {
                    try transform?.storage.step()
                    if flags.first != "-fall" { result.clocks[index].sourceRiseTransition = value }
                    if flags.first != "-rise" { result.clocks[index].sourceFallTransition = value }
                }
            case "set_propagated_clock":
                guard tokens.count == 2 else { throw TimingError.unsupportedSemantic(format: "SDC", semantic: "set_propagated_clock options") }
                for index in try primaryClockTargets(tokens, clocks: result.clocks, line: lineNumber) {
                    try transform?.storage.step()
                    result.clocks[index].isPropagated = true
                }
            case "set_clock_latency":
                // FIXME(INCOMPLETE_IMPLEMENTATION): Native clock execution has no source/network latency profile.
                // SDC intake is the production entrypoint; actual per-edge latency semantics must be implemented before admission.
                throw TimingError.unsupportedSemantic(format: "SDC", semantic: "set_clock_latency")
            case "set_clock_uncertainty":
                guard tokens.count == 3 else { throw TimingError.unsupportedSemantic(format: "SDC", semantic: "set_clock_uncertainty options") }
                let uncertainty = try parseTime(tokens[1], line: lineNumber)
                guard uncertainty.isFinite, uncertainty >= 0 else { throw TimingError.invalidInput("Clock uncertainty must be finite and nonnegative") }
                for index in try primaryClockTargets(tokens, clocks: result.clocks, line: lineNumber) {
                    try transform?.storage.step()
                    result.clocks[index].uncertainty = uncertainty
                }
            case "set_false_path":
                try append(try parseException(tokens, kind: .falsePath, line: lineNumber), to: &result.exceptions, admission: &exceptions)
            case "set_multicycle_path":
                try append(try parseException(tokens, kind: .multicycle, line: lineNumber), to: &result.exceptions, admission: &exceptions)
            case "set_max_delay":
                try append(try parseException(tokens, kind: .maxDelay, line: lineNumber), to: &result.exceptions, admission: &exceptions)
            case "set_min_delay":
                try append(try parseException(tokens, kind: .minDelay, line: lineNumber), to: &result.exceptions, admission: &exceptions)
            case "group_path":
                try append(try parsePathGroup(tokens, line: lineNumber), to: &result.pathGroups, admission: &paths)
            case "set_clock_groups":
                try append(try parseClockGroups(tokens, line: lineNumber), to: &result.clockGroups, admission: &groups)
            case "set_case_analysis":
                let analyses = try parseCaseAnalyses(tokens, line: lineNumber)
                for analysis in analyses {
                    try transform?.storage.step(UInt64(result.caseAnalyses.count))
                    if let existing = result.caseAnalyses.first(where: {
                        $0.target == analysis.target
                    }), existing.value != analysis.value {
                        throw try sourceFailure("Case analysis assigns conflicting values to .", analysis.target) {
                            TimingError.parseFailure(format: "SDC", line: lineNumber,
                                message: "Case analysis assigns conflicting values to \(analysis.target).")
                        }
                    }
                    if !result.caseAnalyses.contains(analysis) {
                        try append(analysis, to: &result.caseAnalyses, admission: &caseAdmission)
                    }
                }
            case "set_driving_cell", "set_load", "set_disable_timing":
                throw TimingError.unsupportedSemantic(format: "SDC", semantic: command)
            default:
                throw TimingError.unsupportedSemantic(format: "SDC", semantic: command)
            }
        }
        try hold(result.clocks, admission: clocks); try hold(result.generatedClocks, admission: generatedAdmission)
        try hold(result.inputDelays, admission: inputs); try hold(result.outputDelays, admission: outputs)
        try hold(result.exceptions, admission: exceptions); try hold(result.pathGroups, admission: paths)
        try hold(result.clockGroups, admission: groups); try hold(result.caseAnalyses, admission: caseAdmission)
        return result
    }

    public func parse(_ data: Data, modeID: String = "default",
        resources: any LibertySourceResourceAccounting) throws -> TimingTransformValue<TimingConstraintSet> {
        let transform = try TimingTextTransform(resources: resources)
        var parser = self; parser.transform = transform
        do { return try transform.finish(parser.parse(data, modeID: modeID)) }
        catch let error as TimingControlledTransformFailure { throw error }
        catch { throw transform.failure(error) }
    }

    private func primaryClockTargets(_ tokens: [String], clocks: [TimingConstraintSet.Clock], line: Int) throws -> [Int] {
        let collections = try filtered(tokens) { try collectionCommand($0) == "get_clocks" }
        guard collections.count == 1 else { throw TimingError.parseFailure(format: "SDC", line: line, message: "Clock setting requires exact get_clocks targets") }
        let names = try collectionValues(collections[0])
        guard !names.isEmpty, try uniqueCount(names) == names.count else { throw TimingError.invalidInput("Clock targets must be unique and nonempty") }
        return try mapped(names) { name in
            let matches = try filtered(clocks.indices) { clocks[$0].name == name }
            guard matches.count == 1 else { throw try sourceFailure("Unknown or ambiguous primary clock target: ", name) { TimingError.invalidInput("Unknown or ambiguous primary clock target: " + name) } }
            return matches[0]
        }
    }

    private func parseGlobalInputTransition(_ tokens: [String], line: Int) throws -> Double {
        guard tokens.count == 3, tokens[2].hasPrefix("["), tokens[2].hasSuffix("]"),
              try allInputsCollection(tokens[2]),
              try !tokens[1].hasPrefix("-") || parseTimeUnchecked(tokens[1]) != nil else {
            throw TimingError.unsupportedSemantic(format: "SDC",
                semantic: "set_input_transition supports only a global value and [all_inputs] without options")
        }
        guard defaultTimeUnit.isFinite, defaultTimeUnit > 0 else {
            throw TimingError.parseFailure(format: "SDC", line: line,
                message: "Input transition requires a finite positive default time unit.")
        }
        let value = try parseTime(tokens[1], line: line)
        guard value.isFinite, value > 0 else {
            throw TimingError.parseFailure(format: "SDC", line: line,
                message: "Input transition must remain finite and positive in SI units.")
        }
        return value
    }

    private func parseCaseAnalyses(
        _ tokens: [String],
        line: Int
    ) throws -> [TimingConstraintSet.CaseAnalysis] {
        guard tokens.count >= 3 else {
            throw TimingError.parseFailure(
                format: "SDC",
                line: line,
                message: "Case analysis requires a binary value and at least one target."
            )
        }
        let value: TimingConstraintSet.CaseAnalysis.Value
        switch tokens[1] {
        case "0":
            value = .zero
        case "1":
            value = .one
        default:
            throw try sourceFailure("set_case_analysis value ", tokens[1]) {
                TimingError.unsupportedSemantic(format: "SDC", semantic: "set_case_analysis value \(tokens[1])")
            }
        }
        let targets = try targetNames(tokens)
        guard !targets.isEmpty else {
            throw TimingError.parseFailure(
                format: "SDC",
                line: line,
                message: "Case analysis has no target."
            )
        }
        guard try uniqueCount(targets) == targets.count else {
            throw TimingError.parseFailure(
                format: "SDC",
                line: line,
                message: "Case analysis contains duplicate targets."
            )
        }
        return try mapped(targets, kind: .liveOwnedBytes) {
            TimingConstraintSet.CaseAnalysis(target: $0, value: value)
        }
    }

    private func parseClock(_ tokens: [String], line: Int) throws -> TimingConstraintSet.Clock {
        let seenLease = try transform?.reserveSet(String.self, capacity: 3)
        defer { withExtendedLifetime(seenLease) {} }
        var seen = Set<String>(), explicitSource: String?, index = 1
        if transform != nil { seen.reserveCapacity(3) }
        while index < tokens.count {
            try transform?.storage.step()
            let token = tokens[index]
            if token == "-name" || token == "-period" || token == "-waveform" {
                guard seen.insert(token).inserted, index + 1 < tokens.count else { throw TimingError.parseFailure(format: "SDC", line: line, message: "Repeated or missing clock option") }
                index += 2
            } else {
                guard explicitSource == nil, !token.hasPrefix("-"),
                      try collectionCommand(token) == nil || collectionCommand(token) == "get_ports" else {
                    throw TimingError.unsupportedSemantic(format: "SDC", semantic: "create_clock target/options")
                }
                let names = try collectionCommand(token) == "get_ports" ? collectionValues(token) : single(token)
                guard names.count == 1 else { throw TimingError.unsupportedSemantic(format: "SDC", semantic: "multiple clock source targets") }
                explicitSource = names[0]; index += 1
            }
        }
        guard let source = explicitSource else { throw TimingError.unsupportedSemantic(format: "SDC", semantic: "clock without explicit hardware source") }
        let period = try parseTime(try requiredOption("-period", in: tokens, line: line), line: line)
        let name = option("-name", in: tokens) ?? source
        let waveform = try option("-waveform", in: tokens).map { raw in
            try mapped(parseList(raw), kind: .liveOwnedBytes) { try parseTime($0, line: line) }
        } ?? []
        guard period.isFinite, period > 0,
              waveform.isEmpty || (waveform.count == 2 && waveform.allSatisfy(\.isFinite)
                && waveform[0] >= 0 && waveform[0] < waveform[1] && waveform[1] < period) else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Clock period/waveform is invalid")
        }
        return TimingConstraintSet.Clock(name: name, source: source, period: period, waveform: waveform)
    }

    private func parseGeneratedClock(_ tokens: [String], line: Int) throws -> TimingConstraintSet.GeneratedClock {
        let name = try option("-name", in: tokens) ?? targetName(tokens) ?? "generated_clock"
        let source = try optionTargetName("-source", in: tokens) ?? name
        _ = try targetName(tokens) ?? name
        if let transform { for token in tokens { try transform.storage.step(UInt64(token.utf8.count)) } }
        let divideBy = try generatedRatio("-divide_by", in: tokens, line: line)
        let multiplyBy = try generatedRatio("-multiply_by", in: tokens, line: line)
        guard divideBy > 0, multiplyBy > 0 else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Generated clock ratios must be positive.")
        }
        return TimingConstraintSet.GeneratedClock(
            name: name,
            source: source,
            masterClock: source,
            divideBy: divideBy,
            multiplyBy: multiplyBy
        )
    }

    private func generatedRatio(_ key: String, in tokens: [String], line: Int) throws -> Int {
        guard let index = tokens.firstIndex(of: key) else { return 1 }
        guard index + 1 < tokens.count, let value = Int(tokens[index + 1]) else {
            throw try sourceFailure("Generated clock  requires an integer value.", key) {
                TimingError.parseFailure(format: "SDC", line: line,
                    message: "Generated clock \(key) requires an integer value.")
            }
        }
        return value
    }

    private func parsePortDelays(
        _ tokens: [String],
        line: Int
    ) throws -> [TimingConstraintSet.PortDelay] {
        guard tokens.count > 1 else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Port delay is missing its value.")
        }
        let value = try parseTime(portDelayValue(in: tokens, line: line), line: line)
        let clock = try optionTargetName("-clock", in: tokens)
        let ports = try flattened(tokens) { token -> [String] in
            if try collectionCommand(token) == "get_ports" { return try collectionValues(token) }
            return []
        }
        guard !ports.isEmpty else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Port delay has no target.")
        }
        for token in tokens.dropFirst() {
            try transform?.storage.step()
            guard token.hasPrefix("-"), try parseTimeUnchecked(token) == nil else { continue }
            guard token == "-clock" || token == "-max" || token == "-min" else { throw TimingError.unsupportedSemantic(format: "SDC", semantic: token) }
        }
        guard !(tokens.contains("-max") && tokens.contains("-min")) else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Conflicting min/max delay flags")
        }
        let roleLease = try transform?.storage.reserve(Bool.self, capacity: 2, kind: .temporaryBytes)
        defer { withExtendedLifetime(roleLease) {} }
        let roles = tokens.contains("-min") ? [false] : tokens.contains("-max") ? [true] : [true, false]
        return try flattened(ports) { port in try mapped(roles) { TimingConstraintSet.PortDelay(port: port, clock: clock,
            rise: value, fall: value, isMax: $0) } }
    }

    private func portDelayValue(in tokens: [String], line: Int) throws -> String {
        var index = tokens.index(after: tokens.startIndex)
        while index < tokens.endIndex {
            try transform?.storage.step()
            let token = tokens[index]
            if token == "-clock" {
                index = tokens.index(after: index)
                if index < tokens.endIndex {
                    index = tokens.index(after: index)
                }
                continue
            }
            if try parseTimeUnchecked(token) == nil && (token.hasPrefix("-") || (token.hasPrefix("[") && token.hasSuffix("]"))) {
                index = tokens.index(after: index)
                continue
            }
            if try parseTimeUnchecked(token) != nil {
                return token
            }
            index = tokens.index(after: index)
        }
        throw TimingError.parseFailure(format: "SDC", line: line, message: "Port delay has no valid time value.")
    }

    private func parseException(_ tokens: [String], kind: TimingConstraintSet.PathException.Kind,
                                line: Int) throws -> TimingConstraintSet.PathException {
        var from: [TimingPathObject] = []; var to: [TimingPathObject] = []
        var through: [[TimingPathObject]] = []; var throughAdmission = ArrayAdmission()
        let flagsLease = try transform?.reserveSet(String.self, capacity: 4)
        defer { withExtendedLifetime(flagsLease) {} }
        var flags = Set<String>(); var number: String?
        if transform != nil { flags.reserveCapacity(4) }
        var index = 1
        while index < tokens.count {
            try transform?.storage.step()
            let token = tokens[index]
            if token == "-from" || token == "-to" || token == "-through" {
                index += 1
                guard index < tokens.count else { throw try sourceFailure("Missing selector after ", token) { TimingError.parseFailure(format: "SDC", line: line, message: "Missing selector after " + token) } }
                let objects = try pathObjects(tokens[index], line: line)
                if token == "-through" { try append(objects, to: &through, admission: &throughAdmission) }
                else if token == "-from" {
                    guard from.isEmpty else { throw TimingError.parseFailure(format: "SDC", line: line, message: "Repeated from selector") }
                    from = objects
                } else {
                    guard to.isEmpty else { throw TimingError.parseFailure(format: "SDC", line: line, message: "Repeated to selector") }
                    to = objects
                }
            } else if token == "-setup" || token == "-hold" || token == "-start" || token == "-end" {
                guard flags.insert(token).inserted else { throw try sourceFailure("Repeated flag ", token) { TimingError.parseFailure(format: "SDC", line: line, message: "Repeated flag " + token) } }
            } else if try token.hasPrefix("-") && parseTimeUnchecked(token) == nil {
                throw TimingError.unsupportedSemantic(format: "SDC path exception", semantic: token)
            } else {
                guard number == nil else { throw TimingError.parseFailure(format: "SDC", line: line, message: "Extra path exception argument") }
                number = token
            }
            index += 1
        }
        guard !(flags.contains("-setup") && flags.contains("-hold")), !(flags.contains("-start") && flags.contains("-end")) else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Conflicting exception flags")
        }
        let scope: TimingConstraintSet.PathException.CheckScope = flags.contains("-setup") ? .setup : flags.contains("-hold") ? .hold : .both
        let reference: TimingConstraintSet.PathException.ClockReference? = flags.contains("-start") ? .start : flags.contains("-end") ? .end : nil
        guard kind == .multicycle || reference == nil, kind == .multicycle || kind == .falsePath || scope == .both else {
            throw TimingError.unsupportedSemantic(format: "SDC", semantic: "check/reference flag for this exception kind")
        }
        var cycles: Int?; var delay: Double?
        if kind == .falsePath {
            guard number == nil, !from.isEmpty || !to.isEmpty || !through.isEmpty else {
                throw TimingError.parseFailure(format: "SDC", line: line, message: "False path needs selectors and no numeric argument")
            }
        } else if kind == .multicycle {
            guard let number, let value = Int(number), value >= (scope == .hold ? 0 : 1) else {
                throw TimingError.parseFailure(format: "SDC", line: line, message: "Invalid multicycle multiplier")
            }
            cycles = value
        } else {
            guard let number else { throw TimingError.parseFailure(format: "SDC", line: line, message: "Missing path delay") }
            let value = try parseTime(number, line: line)
            guard value.isFinite, value >= 0 else { throw TimingError.parseFailure(format: "SDC", line: line, message: "Invalid path delay") }
            delay = value
        }
        try hold(through, admission: throughAdmission)
        return .init(kind: kind, from: from, to: to, through: through, cycles: cycles, delay: delay,
                     scope: scope, clockReference: reference)
    }

    private func pathObjects(_ token: String, line: Int) throws -> [TimingPathObject] {
        let kind: TimingPathObject.Kind
        if token.hasPrefix("[") {
            switch try collectionCommand(token) {
            case "get_ports": kind = .port
            case "get_pins": kind = .pin
            case "get_nets": kind = .net
            case "get_clocks": kind = .clock
            case "get_cells": kind = .instance
            default: throw try sourceFailure("path collection ", token) { TimingError.unsupportedSemantic(format: "SDC", semantic: "path collection " + token) }
            }
            let names = try collectionValues(token)
            guard !names.isEmpty, names.allSatisfy({ !$0.hasPrefix("-") && !$0.contains("$") && !$0.contains(";") }) else {
                throw TimingError.parseFailure(format: "SDC", line: line, message: "Invalid path collection")
            }
            return try mapped(names, kind: .liveOwnedBytes) { TimingPathObject(kind: kind, pattern: $0) }
        }
        guard !token.isEmpty, !token.contains("$"), !token.contains(";"), !token.contains("{") else {
            throw try sourceFailure("path selector ", token) { TimingError.unsupportedSemantic(format: "SDC", semantic: "path selector " + token) }
        }
        kind = .name
        return try single(TimingPathObject(kind: kind, pattern: token))
    }

    private func parsePathGroup(_ tokens: [String], line: Int) throws -> TimingPathGroup {
        let name = try option("-name", in: tokens) ?? groupName(line)
        if let raw = option("-weight", in: tokens) { try transform?.storage.step(UInt64(raw.utf8.count)) }
        let weight = option("-weight", in: tokens).flatMap(Double.init)
        return TimingPathGroup(
            name: name,
            from: try values(after: "-from", in: tokens),
            to: try values(after: "-to", in: tokens),
            through: try values(after: "-through", in: tokens),
            weight: weight
        )
    }

    private func parseClockGroups(_ tokens: [String], line: Int) throws -> TimingClockGroup {
        let kind: TimingClockGroup.Kind
        if tokens.contains("-asynchronous") {
            kind = .asynchronous
        } else if tokens.contains("-logically_exclusive") {
            kind = .logicallyExclusive
        } else if tokens.contains("-physically_exclusive") {
            kind = .physicallyExclusive
        } else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Clock groups require an exclusivity kind.")
        }
        var groups: [[String]] = []; var admission = ArrayAdmission()
        var index = 0
        while index < tokens.count {
            try transform?.storage.step()
            guard tokens[index] == "-group" else {
                index += 1
                continue
            }
            guard tokens.index(after: index) < tokens.endIndex else {
                throw TimingError.parseFailure(format: "SDC", line: line, message: "Clock group is missing its target collection.")
            }
            let values = try collectionValues(tokens[index + 1])
            guard !values.isEmpty else {
                throw TimingError.parseFailure(format: "SDC", line: line, message: "Clock group has no clock target.")
            }
            try append(values, to: &groups, admission: &admission)
            index += 2
        }
        guard groups.count >= 2 else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Clock groups require at least two groups.")
        }
        try hold(groups, admission: admission)
        return TimingClockGroup(kind: kind, groups: groups)
    }

    private func removeComment(_ line: String) throws -> String {
        var quote = false
        for index in line.indices {
            try transform?.storage.step(UInt64(line[index].utf8.count))
            if line[index] == "\"" { quote.toggle() }
            if line[index] == "#", !quote {
                return try text(line[..<index], kind: .temporaryBytes)
            }
        }
        return line
    }

    private func tokenize(_ line: String) throws -> [String] {
        if let transform {
            var result = LibertyBuffer<String>()
            var beginning: String.Index?
            var bracketDepth = 0, braceDepth = 0
            var quote = false
            for index in line.indices {
                let character = line[index]
                try transform.storage.step(UInt64(character.utf8.count))
                if character == "\"" { quote.toggle() }
                else if character == "[", !quote { bracketDepth += 1 }
                else if character == "]", !quote { bracketDepth = max(0, bracketDepth - 1) }
                else if character == "{", !quote { braceDepth += 1 }
                else if character == "}", !quote { braceDepth = max(0, braceDepth - 1) }
                else if character.isWhitespace, !quote, bracketDepth == 0, braceDepth == 0 {
                    if let start = beginning {
                        try result.append(transform.text(line[start..<index]), storage: transform.storage)
                        beginning = nil
                    }
                    continue
                }
                if beginning == nil { beginning = index }
            }
            if let beginning { try result.append(transform.text(line[beginning...]), storage: transform.storage) }
            return try result.array(storage: transform.storage, kind: .temporaryBytes)
        }
        var result: [String] = []
        var current = ""
        var bracketDepth = 0
        var braceDepth = 0
        var quote = false
        for character in line {
            if character == "\"" {
                quote.toggle()
                current.append(character)
            } else if character == "[", !quote {
                bracketDepth += 1
                current.append(character)
            } else if character == "]", !quote {
                bracketDepth = max(0, bracketDepth - 1)
                current.append(character)
            } else if character == "{", !quote {
                braceDepth += 1; current.append(character)
            } else if character == "}", !quote {
                braceDepth = max(0, braceDepth - 1); current.append(character)
            } else if character.isWhitespace, !quote, bracketDepth == 0, braceDepth == 0 {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func option(_ key: String, in tokens: [String]) -> String? {
        guard let index = tokens.firstIndex(of: key), tokens.index(after: index) < tokens.endIndex else { return nil }
        return tokens[tokens.index(after: index)]
    }

    private func requiredOption(_ key: String, in tokens: [String], line: Int) throws -> String {
        guard let value = option(key, in: tokens) else {
            throw try sourceFailure("Missing option .", key) { TimingError.parseFailure(format: "SDC", line: line, message: "Missing option \(key).") }
        }
        return value
    }

    private func requiredValue(after command: String, in tokens: [String], line: Int) throws -> String {
        guard tokens.count > 1 else {
            throw try sourceFailure("Command  is missing a value.", command) { TimingError.parseFailure(format: "SDC", line: line, message: "Command \(command) is missing a value.") }
        }
        return tokens[1]
    }

    private func targetName(_ tokens: [String]) throws -> String? {
        try targetNames(tokens).first
    }

    private func targetNames(_ tokens: [String]) throws -> [String] {
        try flattened(tokens) { token in
            guard token.hasPrefix("["), token.hasSuffix("]") else { return [] }
            return try collectionValues(token)
        }
    }

    private func optionTargetName(_ key: String, in tokens: [String]) throws -> String? {
        guard let index = tokens.firstIndex(of: key), tokens.index(after: index) < tokens.endIndex else { return nil }
        let token = tokens[tokens.index(after: index)]
        if token.hasPrefix("[") && token.hasSuffix("]") {
            return try collectionValues(token).first
        }
        return token
    }

    private func values(after key: String, in tokens: [String]) throws -> [String] {
        guard let index = tokens.firstIndex(of: key), tokens.index(after: index) < tokens.endIndex else { return [] }
        let token = tokens[tokens.index(after: index)]
        if token.hasPrefix("["), token.hasSuffix("]") { return try collectionValues(token) }
        return try single(token)
    }

    private func targets(after command: String, in tokens: [String]) throws -> [String] {
        _ = command
        return try targetNames(tokens)
    }

    private func parseList(_ value: String) throws -> [String] {
        guard let transform else {
            return value.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                .replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
                .replacingOccurrences(of: "\"", with: "").split(whereSeparator: \.isWhitespace).map(String.init)
        }
        let marksLease = try transform.storage.reserve(String.self, capacity: 5, kind: .temporaryBytes)
        defer { withExtendedLifetime(marksLease) {} }
        var cleaned = value
        for mark in ["[", "]", "{", "}", "\""] {
            cleaned = try deletion(cleaned, kind: .temporaryBytes) { cleaned.replacingOccurrences(of: mark, with: "") }
        }
        return try transform.map(transform.segments(cleaned, omittingEmpty: true, separatedBy: \.isWhitespace), kind: .liveOwnedBytes) {
            try transform.text($0)
        }
    }

    private func collectionValues(_ token: String) throws -> [String] {
        guard token.hasPrefix("["), token.hasSuffix("]") else { return try single(token) }
        guard let transform else {
            return token.dropFirst().dropLast().split(whereSeparator: \.isWhitespace).dropFirst()
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "{}")) }.filter { !$0.isEmpty }
        }
        let body = try transform.text(token.dropFirst().dropLast(), kind: .temporaryBytes)
        let parts = try transform.segments(body, omittingEmpty: true, separatedBy: \.isWhitespace)
        let names = try transform.map(parts.dropFirst(), kind: .liveOwnedBytes) { part in
            try deletion(part, kind: .liveOwnedBytes) { part.trimmingCharacters(in: CharacterSet(charactersIn: "{}")) }
        }
        return try transform.filter(names, kind: .liveOwnedBytes) { !$0.isEmpty }
    }

    private func collectionCommand(_ token: String) throws -> String? {
        guard token.hasPrefix("["), token.hasSuffix("]") else { return nil }
        if let transform {
            let body = try transform.text(token.dropFirst().dropLast(), kind: .temporaryBytes)
            let parts = try transform.segments(body, omittingEmpty: true, separatedBy: \.isWhitespace)
            if let first = parts.first { return try transform.text(first, kind: .temporaryBytes) }
            return nil
        }
        return token.dropFirst().dropLast().split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    private func parseTime(_ value: String, line: Int) throws -> Double {
        guard let parsed = try parseTimeUnchecked(value) else {
            throw try sourceFailure("Invalid time value ''.", value) { TimingError.parseFailure(format: "SDC", line: line, message: "Invalid time value '\(value)'.") }
        }
        return parsed
    }

    private func parseTimeUnchecked(_ value: String) throws -> Double? {
        let cleaned = try deletion(value, kind: .temporaryBytes) { value.replacingOccurrences(of: "\"", with: "") }
        let lower: String
        if let transform { lower = try transform.caseMapped(cleaned, uppercase: false) }
        else { lower = cleaned.lowercased() }
        let lease = try transform?.storage.reserve((String, Double).self, capacity: 6, kind: .temporaryBytes)
        defer { withExtendedLifetime(lease) {} }
        let suffixes: [(String, Double)] = [("fs", 1e-15), ("ps", 1e-12), ("ns", 1e-9), ("us", 1e-6), ("ms", 1e-3), ("s", 1)]
        for (suffix, scale) in suffixes where lower.hasSuffix(suffix) {
            try transform?.storage.step(UInt64(lower.utf8.count))
            let prefix = try text(lower.dropLast(suffix.count), kind: .temporaryBytes)
            guard let number = Double(prefix) else { return nil }
            return number * scale
        }
        try transform?.storage.step(UInt64(cleaned.utf8.count))
        return Double(cleaned).map { $0 * defaultTimeUnit }
    }

    private struct ArrayAdmission {
        var capacity = 0
        var receipt: LibertySourceStorageReservation?
    }

    private func append<Element: Sendable>(_ value: Element, to output: inout [Element],
        admission: inout ArrayAdmission) throws {
        guard let transform else { output.append(value); return }
        try transform.storage.step()
        if output.count == admission.capacity {
            let doubled = admission.capacity.multipliedReportingOverflow(by: 2)
            guard !doubled.overflow else { throw LibertySourceError.arithmeticOverflow }
            let capacity = max(1, doubled.partialValue)
            let receipt = try transform.storage.reserve(Element.self, capacity: capacity, kind: .liveOwnedBytes)
            try transform.storage.step(UInt64(output.count))
            var replacement: [Element] = []; replacement.reserveCapacity(capacity)
            replacement.append(contentsOf: output)
            try transform.resources.check()
            output = replacement; admission.receipt = receipt; admission.capacity = capacity
        }
        output.append(value)
    }

    private func hold<Element: Sendable>(_ value: [Element], admission: ArrayAdmission) throws {
        if let transform, let receipt = admission.receipt {
            try transform.storage.hold(value, receipt: receipt, kind: .liveOwnedBytes)
        }
    }

    private func text<S: StringProtocol>(_ value: S,
        kind: LibertySourceStorageKind = .liveOwnedBytes) throws -> String {
        if let transform { return try transform.text(value, kind: kind) }
        return String(value)
    }

    private func deletion<S: StringProtocol>(_ source: S, kind: LibertySourceStorageKind,
        _ body: () -> String) throws -> String {
        guard let transform else { return body() }
        let count = source.utf8.count
        let lease = try transform.storage.reserve(UInt8.self, capacity: count, kind: kind)
        try transform.storage.step(UInt64(count))
        let result = body()
        try transform.storage.hold(result, receipt: lease, kind: kind)
        try transform.resources.check()
        return result
    }

    private func mapped<C: Collection, Element: Sendable>(_ input: C,
        kind: LibertySourceStorageKind = .temporaryBytes,
        _ body: (C.Element) throws -> Element) throws -> [Element] {
        if let transform { return try transform.map(input, kind: kind, body) }
        return try input.map(body)
    }

    private func filtered<C: Collection>(_ input: C,
        _ body: (C.Element) throws -> Bool) throws -> [C.Element] where C.Element: Sendable {
        if let transform { return try transform.filter(input, body) }
        return try input.filter(body)
    }

    private func flattened<C: Collection, Element: Sendable>(_ input: C,
        kind: LibertySourceStorageKind = .liveOwnedBytes,
        _ body: (C.Element) throws -> [Element]) throws -> [Element] {
        guard let transform else { return try input.flatMap(body) }
        var buffer = LibertyBuffer<Element>()
        for value in input {
            try transform.storage.step()
            for element in try body(value) { try buffer.append(element, storage: transform.storage) }
        }
        return try buffer.array(storage: transform.storage, kind: kind)
    }

    private func single<Element: Sendable>(_ value: Element) throws -> [Element] {
        try mapped(CollectionOfOne(value), kind: .liveOwnedBytes) { $0 }
    }

    private func uniqueCount(_ values: [String]) throws -> Int {
        guard let transform else { return Set(values).count }
        let receipt = try transform.reserveSet(String.self, capacity: values.count)
        var result = Set<String>(); result.reserveCapacity(values.count)
        for value in values { try transform.storage.step(UInt64(value.utf8.count)); result.insert(value) }
        defer { withExtendedLifetime(receipt) {} }
        return result.count
    }

    private func sourceFailure(_ literal: String, _ field: String,
        _ body: () -> any Error) throws -> any Error {
        guard let transform else { return body() }
        let bytes = UInt64(literal.utf8.count).addingReportingOverflow(UInt64(field.utf8.count))
        guard !bytes.overflow else { throw LibertySourceError.arithmeticOverflow }
        return try transform.sourceFailure(utf8ByteCount: bytes.partialValue, body)
    }

    private func groupName(_ line: Int) throws -> String {
        guard let transform else { return "group_\(line)" }
        var remaining = line, digits = 1
        while remaining >= 10 { try transform.storage.step(); remaining /= 10; digits += 1 }
        let count = try LibertyParseStorage.add(6, digits)
        let lease = try transform.storage.reserve(UInt8.self, capacity: count, kind: .liveOwnedBytes)
        try transform.storage.step(UInt64(count))
        let result = "group_\(line)"
        try transform.storage.hold(result, receipt: lease, kind: .liveOwnedBytes)
        return result
    }

    private func allInputsCollection(_ token: String) throws -> Bool {
        guard let transform else {
            return token.dropFirst().dropLast().split(whereSeparator: \.isWhitespace).map(String.init) == ["all_inputs"]
        }
        let body = try transform.text(token.dropFirst().dropLast(), kind: .temporaryBytes)
        let parts = try transform.segments(body, omittingEmpty: true, separatedBy: \.isWhitespace)
        return parts.count == 1 && parts[0] == "all_inputs"
    }

}
