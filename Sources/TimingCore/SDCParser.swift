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
                result.inputDelays.append(try parsePortDelay(tokens, line: lineNumber, isInput: true))
            case "set_output_delay":
                result.outputDelays.append(try parsePortDelay(tokens, line: lineNumber, isInput: false))
            case "set_clock_uncertainty":
                let uncertainty = try parseTime(requiredValue(after: "set_clock_uncertainty", in: tokens, line: lineNumber), line: lineNumber)
                let clocks = targets(after: "set_clock_uncertainty", in: tokens)
                for index in result.clocks.indices where clocks.isEmpty || clocks.contains(result.clocks[index].name) {
                    result.clocks[index].uncertainty = uncertainty
                }
            case "set_false_path":
                result.exceptions.append(parseException(tokens, kind: .falsePath, line: lineNumber))
            case "set_multicycle_path":
                result.exceptions.append(parseException(tokens, kind: .multicycle, line: lineNumber))
            case "set_max_delay":
                result.exceptions.append(parseException(tokens, kind: .maxDelay, line: lineNumber))
            case "set_min_delay":
                result.exceptions.append(parseException(tokens, kind: .minDelay, line: lineNumber))
            case "group_path":
                result.pathGroups.append(parsePathGroup(tokens, line: lineNumber))
            case "set_clock_groups":
                result.clockGroups.append(try parseClockGroups(tokens, line: lineNumber))
            case "set_case_analysis":
                result.caseAnalyses.append(try parseCaseAnalysis(tokens, line: lineNumber))
            case "set_driving_cell", "set_load", "set_disable_timing":
                throw TimingError.unsupportedSemantic(format: "SDC", semantic: command)
            default:
                throw TimingError.unsupportedSemantic(format: "SDC", semantic: command)
            }
        }
        return result
    }

    private func parseCaseAnalysis(
        _ tokens: [String],
        line: Int
    ) throws -> TimingConstraintSet.CaseAnalysis {
        guard tokens.count >= 3 else {
            throw TimingError.parseFailure(
                format: "SDC",
                line: line,
                message: "Case analysis requires a binary value and one target."
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
        guard let target = targetName(tokens) else {
            throw TimingError.parseFailure(
                format: "SDC",
                line: line,
                message: "Case analysis has no target."
            )
        }
        return TimingConstraintSet.CaseAnalysis(target: target, value: value)
    }

    private func parseClock(_ tokens: [String], line: Int) throws -> TimingConstraintSet.Clock {
        let period = try parseTime(try requiredOption("-period", in: tokens, line: line), line: line)
        let name = option("-name", in: tokens) ?? targetName(tokens) ?? "clock"
        let source = targetName(tokens) ?? name
        let waveform = option("-waveform", in: tokens).map(parseList).map { $0.compactMap { parseTimeUnchecked($0) } } ?? []
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

    private func parsePortDelay(_ tokens: [String], line: Int, isInput: Bool) throws -> TimingConstraintSet.PortDelay {
        guard tokens.count > 1 else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Port delay is missing its value.")
        }
        _ = isInput
        let value = try parseTime(portDelayValue(in: tokens, line: line), line: line)
        let clock = optionTargetName("-clock", in: tokens)
        let targets = targetNames(tokens)
        guard let port = targets.first else {
            throw TimingError.parseFailure(format: "SDC", line: line, message: "Port delay has no target.")
        }
        let isMax = !tokens.contains("-min")
        return TimingConstraintSet.PortDelay(
            port: port,
            clock: clock,
            rise: value,
            fall: value,
            isMax: isMax
        )
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
            if token.hasPrefix("-") || (token.hasPrefix("[") && token.hasSuffix("]")) {
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

    private func parseException(
        _ tokens: [String],
        kind: TimingConstraintSet.PathException.Kind,
        line: Int
    ) -> TimingConstraintSet.PathException {
        let delay: Double? = kind == .maxDelay || kind == .minDelay
            ? tokens.dropFirst().first.flatMap(parseTimeUnchecked)
            : nil
        let cycles: Int? = kind == .multicycle ? tokens.dropFirst().first.flatMap(Int.init) : nil
        return TimingConstraintSet.PathException(
            kind: kind,
            from: values(after: "-from", in: tokens),
            to: values(after: "-to", in: tokens),
            through: values(after: "-through", in: tokens),
            cycles: cycles,
            delay: delay
        )
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
            } else if character.isWhitespace, !quote, bracketDepth == 0 {
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
        tokens.compactMap { token in
            guard token.hasPrefix("["), token.hasSuffix("]") else { return nil }
            let content = token.dropFirst().dropLast()
            let pieces = content.split(whereSeparator: \.isWhitespace)
            return pieces.last.map(String.init)
        }
    }

    private func optionTargetName(_ key: String, in tokens: [String]) -> String? {
        guard let index = tokens.firstIndex(of: key), tokens.index(after: index) < tokens.endIndex else { return nil }
        let token = tokens[tokens.index(after: index)]
        if token.hasPrefix("[") && token.hasSuffix("]") {
            return token.dropFirst().dropLast().split(whereSeparator: \.isWhitespace).last.map(String.init)
        }
        return token
    }

    private func values(after key: String, in tokens: [String]) -> [String] {
        guard let index = tokens.firstIndex(of: key), tokens.index(after: index) < tokens.endIndex else { return [] }
        let token = tokens[tokens.index(after: index)]
        if token.hasPrefix("[") && token.hasSuffix("]") {
            return token.dropFirst().dropLast().split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
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
