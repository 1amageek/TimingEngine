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

    public struct ResistanceRecord: Sendable, Hashable, Codable {
        public let source: SourceID
        public let first: Endpoint
        public let second: Endpoint
        /// Exact zero preserves an ideal voltage-equality source record between endpoint identities.
        public let resistance: Double

        public init(source: SourceID, first: Endpoint, second: Endpoint, resistance: Double) {
            self.source = source; self.first = first; self.second = second; self.resistance = resistance
        }
    }

    public struct Network: Sendable, Hashable, Codable {
        public let name: String
        public let declaredCapacitance: Double
        public let resistanceInventory: Double
        public let capacitances: [CapacitanceRecord]
        public let resistances: [ResistanceRecord]
        public let connections: [Endpoint]

        public var groundCapacitance: Double {
            capacitances.reduce(0) { $0 + ($1.second == nil ? $1.capacitance : 0) }
        }

        public init(name: String, declaredCapacitance: Double = 0,
                    resistanceInventory: Double = 0, capacitances: [CapacitanceRecord] = [],
                    resistances: [ResistanceRecord] = [], connections: [Endpoint] = []) {
            self.name = name
            self.declaredCapacitance = declaredCapacitance
            self.resistanceInventory = resistanceInventory
            self.capacitances = capacitances
            self.resistances = resistances
            self.connections = connections
        }

        private enum CodingKeys: String, CodingKey {
            case name, declaredCapacitance, resistanceInventory, capacitances, resistances, connections
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(name: c.decode(String.self, forKey: .name),
                declaredCapacitance: c.decode(Double.self, forKey: .declaredCapacitance),
                resistanceInventory: c.decode(Double.self, forKey: .resistanceInventory),
                capacitances: c.decode([CapacitanceRecord].self, forKey: .capacitances),
                resistances: c.decodeIfPresent([ResistanceRecord].self, forKey: .resistances) ?? [],
                connections: c.decodeIfPresent([Endpoint].self, forKey: .connections) ?? [])
        }
    }

    public static let currentSchemaVersion = 3
    /// Legacy inventory is usable only for the explicit equipotential projection.
    public var hasDistributedTopology: Bool { schemaVersion == Self.currentSchemaVersion }
    public let schemaVersion: Int
    public let designName: String?
    public let pinDelimiter: String
    public let networks: [Network]

    public init(designName: String? = nil, pinDelimiter: String = ":", networks: [Network] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.designName = designName
        self.pinDelimiter = pinDelimiter
        self.networks = networks
    }

    public func network(named name: String) -> Network? {
        networks.first { $0.name == name }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, designName, pinDelimiter, networks }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == 2 || version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                debugDescription: "Unsupported timing parasitic source inventory schema.")
        }
        schemaVersion = version
        designName = try container.decodeIfPresent(String.self, forKey: .designName)
        pinDelimiter = try container.decodeIfPresent(String.self, forKey: .pinDelimiter) ?? ":"
        networks = try container.decode([Network].self, forKey: .networks)
    }
}
