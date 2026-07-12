import Foundation

public struct TimingDesign: Sendable, Hashable, Codable {
    public struct Port: Sendable, Hashable, Codable {
        public enum Direction: String, Sendable, Hashable, Codable {
            case input
            case output
            case bidirectional = "inout"
        }

        public var name: String
        public var direction: Direction
        public var clock: String?

        public init(name: String, direction: Direction, clock: String? = nil) {
            self.name = name
            self.direction = direction
            self.clock = clock
        }
    }

    public struct Instance: Sendable, Hashable, Codable {
        public var name: String
        public var cell: String
        public var connections: [String: String]

        public init(name: String, cell: String, connections: [String: String]) {
            self.name = name
            self.cell = cell
            self.connections = connections
        }
    }

    public struct Net: Sendable, Hashable, Codable {
        public var name: String
        public var capacitance: Double

        public init(name: String, capacitance: Double = 0) {
            self.name = name
            self.capacitance = capacitance
        }
    }

    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var topDesignName: String
    public var ports: [Port]
    public var instances: [Instance]
    public var nets: [Net]

    public init(
        topDesignName: String,
        ports: [Port],
        instances: [Instance],
        nets: [Net] = []
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.topDesignName = topDesignName
        self.ports = ports
        self.instances = instances
        self.nets = nets
    }

    public func net(named name: String) -> Net {
        nets.first { $0.name == name } ?? Net(name: name)
    }
}
