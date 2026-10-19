import Foundation

public struct TimingDesign: Sendable, Hashable, Codable {
    public enum Constant: String, Sendable, Hashable, Codable { case zero, one }
    public struct Port: Sendable, Hashable, Codable {
        public enum Direction: String, Sendable, Hashable, Codable {
            case input
            case output
            case bidirectional = "inout"
        }

        public var name: String
        public var direction: Direction
        public var clock: String?
        public var net: String?
        public var netName: String { net ?? name }

        public init(name: String, direction: Direction, clock: String? = nil, net: String? = nil) {
            self.name = name
            self.direction = direction
            self.clock = clock
            self.net = net
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
        public var constant: Constant?

        public init(name: String, capacitance: Double = 0, constant: Constant? = nil) {
            self.name = name
            self.capacitance = capacitance
            self.constant = constant
        }
    }

    public static let currentSchemaVersion = 2
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

    private enum CodingKeys: String, CodingKey { case schemaVersion, topDesignName, ports, instances, nets }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        let ports = try values.decode([Port].self, forKey: .ports)
        let nets = try values.decode([Net].self, forKey: .nets)
        guard version == Self.currentSchemaVersion || (version == 1
            && ports.allSatisfy({ $0.net == nil }) && nets.allSatisfy({ $0.constant == nil })) else {
            throw TimingError.invalidInput("Unsupported timing design schema or v1 with explicit connectivity")
        }
        self.init(topDesignName: try values.decode(String.self, forKey: .topDesignName), ports: ports,
            instances: try values.decode([Instance].self, forKey: .instances), nets: nets)
    }

    public func net(named name: String) -> Net {
        nets.first { $0.name == name } ?? Net(name: name)
    }
}
