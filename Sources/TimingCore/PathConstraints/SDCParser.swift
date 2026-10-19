import Foundation

public struct SDCParser: TimingConstraintParsing {
    public var defaultTimeUnit: Double

    public init(defaultTimeUnit: Double = 1e-9) {
        self.defaultTimeUnit = defaultTimeUnit
    }

    public func parse(_ data: Data, modeID: String = "default") throws -> TimingConstraintSet {
        guard let source = String(data: data, encoding: .utf8) else {
            throw TimingError.parseFailure(format: "SDC", line: 1, message: "Input is not UTF-8.")
        }
        var result = TimingConstraintSet(modeID: modeID)
        for (offset, rawLine) in source.split(whereSeparator: \.isNewline).enumerated() {
            let lineNumber = offset + 1
            let line = removeComment(String(rawLine))
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let tokens = tokenize(line)
            guard let command = tokens.first else { continue }
            switch command {
            case "create_clock":
                let clock = try parseClock(tokens, line: lineNumber)
                result.clocks.append(clock)
            case "create_generated_clock":
                let generated = try parseGeneratedClock(tokens, line: lineNumber)
                result.generatedClocks.append(generated)
            case "set_input_delay":
                for delay in try parsePortDelays(tokens, line: lineNumber) {
                    result.inputDelays.removeAll { $0.port == delay.port && $0.clock == delay.clock && $0.isMax == delay.isMax }
                    result.inputDelays.append(delay)
                }
            case "set_output_delay":
                for delay in try parsePortDelays(tokens, line: lineNumber) {
                    result.outputDelays.removeAll { $0.port == delay.port && $0.clock == delay.clock && $0.isMax == delay.isMax }
                    result.outputDelays.append(delay)
                }
            case "set_input_transition":
                result.defaultInputSlew = try parseGlobalInputTransition(tokens, line: lineNumber)
                result.inputTransition = .allInputsBothEdges(slew: result.defaultInputSlew)
            case "set_clock_transition":
                let targets = try primaryClockTargets(tokens, clocks: result.clocks, line: lineNumber)
                let flags = tokens.filter { $0 == "-rise" || $0 == "-fall" }
                guard flags.count <= 1, tokens.count == (flags.isEmpty ? 3 : 4),
                      let raw = tokens.dropFirst().first(where: { !$0.hasPrefix("-") && !$0.hasPrefix("[") }) else {
                    throw TimingError.unsupportedSemantic(format: "SDC", semantic: "set_clock_transition options")
                }
                let value = try parseTime(raw, line: lineNumber)
                guard value.isFinite, value > 0 else { throw TimingError.invalidInput("Clock transitions must be finite and positive") }
                for index in targets {
                    if flags.first != "-fall" { result.clocks[index].sourceRiseTransition = value }
                    if flags.first != "-rise" { result.clocks[index].sourceFallTransition = value }
                }
            case "set_propagated_clock":
                guard tokens.count == 2 else { throw TimingError.unsupportedSemantic(format: "SDC", semantic: "set_propagated_clock options") }
                for index in try primaryClockTargets(tokens, clocks: result.clocks, line: lineNumber) {
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
                    result.clocks[index].uncertainty = uncertainty
                }
            case "set_false_path":
                result.exceptions.append(try parseException(tokens, kind: .falsePath, line: lineNumber))
            case "set_multicycle_path":
                result.exceptions.append(try parseException(tokens, kind: .multicycle, line: lineNumber))
            case "set_max_delay":
                result.exceptions.append(try parseException(tokens, kind: .maxDelay, line: lineNumber))
            case "set_min_delay":
                result.exceptions.append(try parseException(tokens, kind: .minDelay, line: lineNumber))
            case "group_path":
                result.pathGroups.append(parsePathGroup(tokens, line: lineNumber))
            case "set_clock_groups":
                result.clockGroups.append(try parseClockGroups(tokens, line: lineNumber))
            case "set_case_analysis":
                let analyses = try parseCaseAnalyses(tokens, line: lineNumber)
                for analysis in analyses {
                    if let existing = result.caseAnalyses.first(where: {
                        $0.target == analysis.target
                    }), existing.value != analysis.value {
                        throw TimingError.parseFailure(
                            format: "SDC",
                            line: lineNumber,
                            message: "Case analysis assigns conflicting values to \(analysis.target)."
                        )
                    }
                    if !result.caseAnalyses.contains(analysis) {
                        result.caseAnalyses.append(analysis)
                    }
                }
            case "set_driving_cell", "set_load", "set_disable_timing":
                throw TimingError.unsupportedSemantic(format: "SDC", semantic: command)
            default:
                throw TimingError.unsupportedSemantic(format: "SDC", semantic: command)
            }
        }
        return result
    }

    private func primaryClockTargets(_ tokens: [String], clocks: [TimingConstraintSet.Clock], line: Int) throws -> [Int] {
        let collections = tokens.filter { collectionCommand($0) == "get_clocks" }
        guard collections.count == 1 else { throw TimingError.parseFailure(format: "SDC", line: line, message: "Clock setting requires exact get_clocks targets") }
        let names = collectionValues(collections[0])
        guard !names.isEmpty, Set(names).count == names.count else { throw TimingError.invalidInput("Clock targets must be unique and nonempty") }
        return try names.map { name in
            let matches = clocks.indices.filter { clocks[$0].name == name }
            guard matches.count == 1 else { throw TimingError.invalidInput("Unknown or ambiguous primary clock target: " + name) }
            return matches[0]
        }
    }

    private func parseGlobalInputTransition(_ tokens: [String], line: Int) throws -> Double {
        guard tokens.count == 3, tokens[2].hasPrefix("["), tokens[2].hasSuffix("]"),
              tokens[2].dropFirst().dropLast().split(whereSeparator: \.isWhitespace).map(String.init) == ["all_inputs"],
              !tokens[1].hasPrefix("-") || parseTimeUnchecked(tokens[1]) != nil else {
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
            throw TimingError.unsupportedSemantic(
                format: "SDC",
                semantic: "set_case_analysis value \(tokens[1])"
            )
        }
        let targets = targetNames(tokens)
        guard !targets.isEmpty else {
            throw TimingError.parseFailure(
                format: "SDC",
                line: line,
                message: "Case analysis has no target."
            )
        }
        guard Set(targets).count == targets.count else {
            throw TimingError.parseFailure(
                format: "SDC",
                line: line,
                message: "Case analysis contains duplicate targets."
            )
        }
        return targets.map {
            TimingConstraintSet.CaseAnalysis(target: $0, value: value)
        }
    }

    private func parseClock(_ tokens: [String], line: Int) throws -> TimingConstraintSet.Clock {
        var seen = Set<String>(), explicitSource: String?, index = 1
        while index < tokens.count {
            let token = tokens[index]
            if ["-name", "-period", "-waveform"].contains(token) {
                guard seen.insert(token).inserted, index + 1 < tokens.count else { throw TimingError.parseFailure(format: "SDC", line: line, message: "Repeated or missing clock option") }
                index += 2
            } else {
                guard explicitSource == nil, !token.hasPrefix("-"),
                      collectionCommand(token) == nil || collectionCommand(token) == "get_ports" else {
                    throw TimingError.unsupportedSemantic(format: "SDC", semantic: "create_clock target/options")
                }
                let names = collectionCommand(token) == "get_ports" ? collectionValues(token) : [token]
                guard names.count == 1 else { throw TimingError.unsupportedSemantic(format: "SDC", semantic: "multiple clock source targets") }
                explicitSource = names[0]; index += 1
            }
        }
        guard let source = explicitSource else { throw TimingError.unsupportedSemantic(format: "SDC", semantic: "clock without explicit hardware source") }
        let period = try parseTime(try requiredOption("-period", in: tokens, line: line), line: line)
        let name = option("-name", in: tokens) ?? source
        let waveform = try option("-waveform", in: tokens).map { raw in try parseList(raw).map { try parseTime($0, line: line) } } ?? []
        guard period.isFinite, period > 0,
              waveform.isEmpty || (waveform.count == 2 && waveform.allSatisfy(\.isFinite)
                && waveform[0] >= 0 && waveform[0] < waveform[1] && waveform[1] < period) else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Clock period/waveform is invalid")
        }
        return TimingConstraintSet.Clock(name: name, source: source, period: period, waveform: waveform)
    }

    private func parseGeneratedClock(_ tokens: [String], line: Int) throws -> TimingConstraintSet.GeneratedClock {
        let name = option("-name", in: tokens) ?? targetName(tokens) ?? "generated_clock"
        let source = optionTargetName("-source", in: tokens) ?? name
        _ = targetName(tokens) ?? name
        let divideBy = Int(option("-divide_by", in: tokens) ?? "1") ?? 1
        let multiplyBy = Int(option("-multiply_by", in: tokens) ?? "1") ?? 1
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

    private func parsePortDelays(
        _ tokens: [String],
        line: Int
    ) throws -> [TimingConstraintSet.PortDelay] {
        guard tokens.count > 1 else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Port delay is missing its value.")
        }
        let value = try parseTime(portDelayValue(in: tokens, line: line), line: line)
        let clock = optionTargetName("-clock", in: tokens)
        let ports = tokens.flatMap { token -> [String] in
            collectionCommand(token) == "get_ports"
                ? collectionValues(token)
                : []
        }
        guard !ports.isEmpty else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Port delay has no target.")
        }
        let allowed = Set(["-clock", "-max", "-min"])
        for token in tokens.dropFirst() where token.hasPrefix("-") && parseTimeUnchecked(token) == nil {
            guard allowed.contains(token) else { throw TimingError.unsupportedSemantic(format: "SDC", semantic: token) }
        }
        guard !(tokens.contains("-max") && tokens.contains("-min")) else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Conflicting min/max delay flags")
        }
        let roles = tokens.contains("-min") ? [false] : tokens.contains("-max") ? [true] : [true, false]
        return ports.flatMap { port in roles.map { TimingConstraintSet.PortDelay(port: port, clock: clock,
            rise: value, fall: value, isMax: $0) } }
    }

    private func portDelayValue(in tokens: [String], line: Int) throws -> String {
        var index = tokens.index(after: tokens.startIndex)
        while index < tokens.endIndex {
            let token = tokens[index]
            if token == "-clock" {
                index = tokens.index(after: index)
                if index < tokens.endIndex {
                    index = tokens.index(after: index)
                }
                continue
            }
            if parseTimeUnchecked(token) == nil && (token.hasPrefix("-") || (token.hasPrefix("[") && token.hasSuffix("]"))) {
                index = tokens.index(after: index)
                continue
            }
            if parseTimeUnchecked(token) != nil {
                return token
            }
            index = tokens.index(after: index)
        }
        throw TimingError.parseFailure(format: "SDC", line: line, message: "Port delay has no valid time value.")
    }

    private func parseException(_ tokens: [String], kind: TimingConstraintSet.PathException.Kind,
                                line: Int) throws -> TimingConstraintSet.PathException {
        var from: [TimingPathObject] = []; var to: [TimingPathObject] = []
        var through: [[TimingPathObject]] = []; var flags = Set<String>(); var number: String?
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if ["-from", "-to", "-through"].contains(token) {
                index += 1
                guard index < tokens.count else { throw TimingError.parseFailure(format: "SDC", line: line, message: "Missing selector after " + token) }
                let objects = try pathObjects(tokens[index], line: line)
                if token == "-through" { through.append(objects) }
                else if token == "-from" {
                    guard from.isEmpty else { throw TimingError.parseFailure(format: "SDC", line: line, message: "Repeated from selector") }
                    from = objects
                } else {
                    guard to.isEmpty else { throw TimingError.parseFailure(format: "SDC", line: line, message: "Repeated to selector") }
                    to = objects
                }
            } else if ["-setup", "-hold", "-start", "-end"].contains(token) {
                guard flags.insert(token).inserted else { throw TimingError.parseFailure(format: "SDC", line: line, message: "Repeated flag " + token) }
            } else if token.hasPrefix("-") && parseTimeUnchecked(token) == nil {
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
        return .init(kind: kind, from: from, to: to, through: through, cycles: cycles, delay: delay,
                     scope: scope, clockReference: reference)
    }

    private func pathObjects(_ token: String, line: Int) throws -> [TimingPathObject] {
        let kind: TimingPathObject.Kind
        if token.hasPrefix("[") {
            switch collectionCommand(token) {
            case "get_ports": kind = .port
            case "get_pins": kind = .pin
            case "get_nets": kind = .net
            case "get_clocks": kind = .clock
            case "get_cells": kind = .instance
            default: throw TimingError.unsupportedSemantic(format: "SDC", semantic: "path collection " + token)
            }
            let names = collectionValues(token)
            guard !names.isEmpty, names.allSatisfy({ !$0.hasPrefix("-") && !$0.contains("$") && !$0.contains(";") }) else {
                throw TimingError.parseFailure(format: "SDC", line: line, message: "Invalid path collection")
            }
            return names.map { .init(kind: kind, pattern: $0) }
        }
        guard !token.isEmpty, !token.contains("$"), !token.contains(";"), !token.contains("{") else {
            throw TimingError.unsupportedSemantic(format: "SDC", semantic: "path selector " + token)
        }
        kind = .name
        return [.init(kind: kind, pattern: token)]
    }

    private func parsePathGroup(_ tokens: [String], line: Int) -> TimingPathGroup {
        let name = option("-name", in: tokens) ?? "group_\(line)"
        let weight = option("-weight", in: tokens).flatMap(Double.init)
        return TimingPathGroup(
            name: name,
            from: values(after: "-from", in: tokens),
            to: values(after: "-to", in: tokens),
            through: values(after: "-through", in: tokens),
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
        var groups: [[String]] = []
        var index = 0
        while index < tokens.count {
            guard tokens[index] == "-group" else {
                index += 1
                continue
            }
            guard tokens.index(after: index) < tokens.endIndex else {
                throw TimingError.parseFailure(format: "SDC", line: line, message: "Clock group is missing its target collection.")
            }
            let values = collectionValues(tokens[index + 1])
            guard !values.isEmpty else {
                throw TimingError.parseFailure(format: "SDC", line: line, message: "Clock group has no clock target.")
            }
            groups.append(values)
            index += 2
        }
        guard groups.count >= 2 else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Clock groups require at least two groups.")
        }
        return TimingClockGroup(kind: kind, groups: groups)
    }

    private func removeComment(_ line: String) -> String {
        var quote = false
        for index in line.indices {
            if line[index] == "\"" { quote.toggle() }
            if line[index] == "#", !quote {
                return String(line[..<index])
            }
        }
        return line
    }

    private func tokenize(_ line: String) -> [String] {
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
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Missing option \(key).")
        }
        return value
    }

    private func requiredValue(after command: String, in tokens: [String], line: Int) throws -> String {
        guard tokens.count > 1 else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Command \(command) is missing a value.")
        }
        return tokens[1]
    }

    private func targetName(_ tokens: [String]) -> String? {
        targetNames(tokens).first
    }

    private func targetNames(_ tokens: [String]) -> [String] {
        tokens.reduce(into: [String]()) { result, token in
            guard token.hasPrefix("["), token.hasSuffix("]") else { return }
            result.append(contentsOf: collectionValues(token))
        }
    }

    private func optionTargetName(_ key: String, in tokens: [String]) -> String? {
        guard let index = tokens.firstIndex(of: key), tokens.index(after: index) < tokens.endIndex else { return nil }
        let token = tokens[tokens.index(after: index)]
        if token.hasPrefix("[") && token.hasSuffix("]") {
            return collectionValues(token).first
        }
        return token
    }

    private func values(after key: String, in tokens: [String]) -> [String] {
        guard let index = tokens.firstIndex(of: key), tokens.index(after: index) < tokens.endIndex else { return [] }
        let token = tokens[tokens.index(after: index)]
        if token.hasPrefix("[") && token.hasSuffix("]") {
            return collectionValues(token)
        }
        return [token]
    }

    private func targets(after command: String, in tokens: [String]) -> [String] {
        _ = command
        return targetNames(tokens)
    }

    private func parseList(_ value: String) -> [String] {
        value
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private func collectionValues(_ token: String) -> [String] {
        guard token.hasPrefix("["), token.hasSuffix("]") else { return [token] }
        return token
            .dropFirst()
            .dropLast()
            .split(whereSeparator: \.isWhitespace)
            .dropFirst()
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "{}")) }
            .filter { !$0.isEmpty }
    }

    private func collectionCommand(_ token: String) -> String? {
        guard token.hasPrefix("["), token.hasSuffix("]") else { return nil }
        return token
            .dropFirst()
            .dropLast()
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
    }

    private func parseTime(_ value: String, line: Int) throws -> Double {
        guard let parsed = parseTimeUnchecked(value) else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Invalid time value '\(value)'.")
        }
        return parsed
    }

    private func parseTimeUnchecked(_ value: String) -> Double? {
        let cleaned = value.replacingOccurrences(of: "\"", with: "")
        let lower = cleaned.lowercased()
        let suffixes: [(String, Double)] = [("fs", 1e-15), ("ps", 1e-12), ("ns", 1e-9), ("us", 1e-6), ("ms", 1e-3), ("s", 1)]
        for (suffix, scale) in suffixes where lower.hasSuffix(suffix) {
            let prefix = String(lower.dropLast(suffix.count))
            guard let number = Double(prefix) else { return nil }
            return number * scale
        }
        return Double(cleaned).map { $0 * defaultTimeUnit }
    }
}
