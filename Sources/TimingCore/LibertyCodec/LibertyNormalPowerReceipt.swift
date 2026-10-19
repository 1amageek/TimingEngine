/// Conditional Boolean observations; transport alone is never a checked normal-power owner.
public struct LibertyNormalPowerReceipt: Sendable, Hashable, Codable {
    public struct PGValue: Sendable, Hashable, Codable {
        public let condition: LibertyPGCondition
        public let line: Int
        public let byteOffset: Int
    }
    public struct Query: Sendable, Hashable, Codable {
        public enum Binding: String, Sendable, Hashable, Codable { case powerPin, inputPin, stateVariable }
        public enum Domain: String, Sendable, Hashable, Codable { case binary }
        public let symbol: String
        public let binding: Binding
        public let domain: Domain
        /// Nil represents both binary values, never a default value.
        public let value: Bool?
    }
    public struct FunctionSample: Sendable, Hashable, Codable {
        public let origin: LibertyNormalPowerFunctionOrigin
        public let queries: [Query]
        public let result: Bool
    }
    public let cell: String
    public let cellLine: Int
    public let cellByteOffset: Int
    public let pgValues: [PGValue]
    public let functions: [FunctionSample]
}
