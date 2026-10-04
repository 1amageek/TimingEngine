import Foundation

public protocol TimingCharacterizationParsing: Sendable {
    func parseCharacterized(_ data: Data, cellNames: [String], propagationCellNames: [String]) throws -> CharacterizedTimingLibrary
}
