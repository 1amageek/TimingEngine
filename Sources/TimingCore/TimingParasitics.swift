import Foundation

public struct TimingParasitics: Sendable, Hashable, Codable {
    public struct Network: Sendable, Hashable, Codable {
        public var name: String
        public var totalCapacitance: Double
        public var groundCapacitance: Double
        public var resistance: Double

        public init(
            name: String,
            totalCapacitance: Double = 0,
            groundCapacitance: Double = 0,
            resistance: Double = 0
        ) {
            self.name = name
            self.totalCapacitance = totalCapacitance
            self.groundCapacitance = groundCapacitance
            self.resistance = resistance
        }
    }

    public struct Coupling: Sendable, Hashable, Codable {
        public var firstNet: String
        public var secondNet: String
        public var capacitance: Double

        public init(firstNet: String, secondNet: String, capacitance: Double) {
            self.firstNet = firstNet
            self.secondNet = secondNet
            self.capacitance = capacitance
        }
    }

    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var designName: String?
    public var networks: [Network]
    public var couplings: [Coupling]

    public init(
        designName: String? = nil,
        networks: [Network] = [],
        couplings: [Coupling] = []
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.designName = designName
        self.networks = networks
        self.couplings = couplings
    }

    public func network(named name: String) -> Network? {
        networks.first { $0.name == name }
    }
}
