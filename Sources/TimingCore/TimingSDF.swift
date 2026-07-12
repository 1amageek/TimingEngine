import Foundation

public struct TimingSDF: Sendable, Hashable, Codable {
    public struct Annotation: Sendable, Hashable, Codable {
        public var instance: String
        public var fromPin: String?
        public var toPin: String?
        public var rise: Double?
        public var fall: Double?

        public init(
            instance: String,
            fromPin: String? = nil,
            toPin: String? = nil,
            rise: Double? = nil,
            fall: Double? = nil
        ) {
            self.instance = instance
            self.fromPin = fromPin
            self.toPin = toPin
            self.rise = rise
            self.fall = fall
        }
    }

    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var timescale: Double
    public var annotations: [Annotation]

    public init(timescale: Double = 1, annotations: [Annotation] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.timescale = timescale
        self.annotations = annotations
    }
}
