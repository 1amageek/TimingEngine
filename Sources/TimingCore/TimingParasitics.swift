import Foundation

/// Preserved parasitic source inventory, independent of any load approximation.
public struct TimingParasitics: Sendable, Hashable, Codable {
    public struct Endpoint: Sendable, Hashable, Codable, Comparable {
        public let name: String
        public let ownerNet: String

        public init(name: String, ownerNet: String) {
            self.name = name
            self.ownerNet = ownerNet
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.ownerNet, lhs.name) < (rhs.ownerNet, rhs.name)
        }
    }

    public struct SourceID: Sendable, Hashable, Codable, Comparable {
        public let declaringNet: String
        public let identifier: UInt64
        public let line: Int

        public init(declaringNet: String, identifier: UInt64, line: Int) {
            self.declaringNet = declaringNet
            self.identifier = identifier
            self.line = line
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.declaringNet, lhs.identifier, lhs.line) < (rhs.declaringNet, rhs.identifier, rhs.line)
        }
    }

    public struct CapacitanceRecord: Sendable, Hashable, Codable {
        public let source: SourceID
        public let first: Endpoint
        public let second: Endpoint?
        public let capacitance: Double

        public init(source: SourceID, first: Endpoint, second: Endpoint? = nil, capacitance: Double) {
            self.source = source
            self.first = first
            self.second = second
            self.capacitance = capacitance
        }
    }

    public struct Network: Sendable, Hashable, Codable {
        public let name: String
        public let declaredCapacitance: Double
        public let resistanceInventory: Double
        public let capacitances: [CapacitanceRecord]

        public var groundCapacitance: Double {
            capacitances.reduce(0) { $0 + ($1.second == nil ? $1.capacitance : 0) }
        }

        public init(name: String, declaredCapacitance: Double = 0,
                    resistanceInventory: Double = 0, capacitances: [CapacitanceRecord] = []) {
            self.name = name
            self.declaredCapacitance = declaredCapacitance
            self.resistanceInventory = resistanceInventory
            self.capacitances = capacitances
        }
    }

    public static let currentSchemaVersion = 2
    public let schemaVersion: Int
    public let designName: String?
    public let networks: [Network]

    public init(designName: String? = nil, networks: [Network] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.designName = designName
        self.networks = networks
    }

    public func network(named name: String) -> Network? {
        networks.first { $0.name == name }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, designName, networks }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                debugDescription: "Unsupported timing parasitic source inventory schema.")
        }
        self.init(designName: try container.decodeIfPresent(String.self, forKey: .designName),
                  networks: try container.decode([Network].self, forKey: .networks))
    }
}
