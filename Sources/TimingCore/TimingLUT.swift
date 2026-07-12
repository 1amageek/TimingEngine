import Foundation

public struct TimingLUT: Sendable, Hashable, Codable {
    public let inputSlews: [Double]
    public let outputLoads: [Double]
    public let values: [[Double]]

    public init(inputSlews: [Double], outputLoads: [Double], values: [[Double]]) throws {
        guard !inputSlews.isEmpty, !outputLoads.isEmpty else {
            throw TimingError.invalidInput("A timing LUT needs at least one sample on both axes.")
        }
        guard values.count == inputSlews.count,
              values.allSatisfy({ $0.count == outputLoads.count }) else {
            throw TimingError.invalidInput("Timing LUT values do not match the declared axes.")
        }
        guard Self.isStrictlyAscending(inputSlews), Self.isStrictlyAscending(outputLoads) else {
            throw TimingError.invalidInput("Timing LUT axes must be strictly ascending.")
        }
        guard inputSlews.allSatisfy(\.isFinite), outputLoads.allSatisfy(\.isFinite),
              values.flatMap({ $0 }).allSatisfy(\.isFinite) else {
            throw TimingError.invalidInput("Timing LUT values and axes must be finite.")
        }
        self.inputSlews = inputSlews
        self.outputLoads = outputLoads
        self.values = values
    }

    public static func constant(_ value: Double) -> TimingLUT {
        do {
            return try TimingLUT(inputSlews: [0], outputLoads: [0], values: [[value]])
        } catch {
            preconditionFailure("A constant timing LUT must be constructible: \(error)")
        }
    }

    public func lookup(inputSlew: Double, outputLoad: Double) -> Double {
        let row = Self.bracket(inputSlews, inputSlew)
        let low = Self.interpolate(outputLoads, values[row.low], at: outputLoad)
        guard row.low != row.high else { return low }
        let high = Self.interpolate(outputLoads, values[row.high], at: outputLoad)
        return low + (high - low) * row.fraction
    }

    private struct Bracket {
        let low: Int
        let high: Int
        let fraction: Double
    }

    private static func isStrictlyAscending(_ values: [Double]) -> Bool {
        guard values.count > 1 else { return true }
        return zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
    }

    private static func bracket(_ axis: [Double], _ value: Double) -> Bracket {
        guard axis.count > 1 else { return Bracket(low: 0, high: 0, fraction: 0) }
        if value <= axis[0] {
            return Bracket(low: 0, high: 1, fraction: (value - axis[0]) / (axis[1] - axis[0]))
        }
        let last = axis.count - 1
        if value >= axis[last] {
            return Bracket(
                low: last - 1,
                high: last,
                fraction: (value - axis[last - 1]) / (axis[last] - axis[last - 1])
            )
        }
        var high = 1
        while axis[high] < value { high += 1 }
        return Bracket(
            low: high - 1,
            high: high,
            fraction: (value - axis[high - 1]) / (axis[high] - axis[high - 1])
        )
    }

    private static func interpolate(_ axis: [Double], _ values: [Double], at value: Double) -> Double {
        let bracket = bracket(axis, value)
        guard bracket.low != bracket.high else { return values[bracket.low] }
        return values[bracket.low] + (values[bracket.high] - values[bracket.low]) * bracket.fraction
    }
}
