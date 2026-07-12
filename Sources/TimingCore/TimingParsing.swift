import Foundation

public protocol TimingLibraryParsing: Sendable {
    func parse(_ data: Data) throws -> TimingLibrary
}

public protocol TimingConstraintParsing: Sendable {
    func parse(_ data: Data, modeID: String) throws -> TimingConstraintSet
}

public protocol TimingDesignParsing: Sendable {
    func parse(_ data: Data, topDesignName: String) throws -> TimingDesign
}

public protocol TimingParasiticParsing: Sendable {
    func parse(_ data: Data) throws -> TimingParasitics
}

public protocol TimingSDFParsing: Sendable {
    func parse(_ data: Data) throws -> TimingSDF
}
