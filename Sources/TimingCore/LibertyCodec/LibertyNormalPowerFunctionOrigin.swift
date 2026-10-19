public struct LibertyNormalPowerFunctionOrigin: Sendable, Hashable, Codable {
    public enum Owner: Sendable, Hashable, Codable {
        case pin(String)
        case declaration(index: Int, kind: LibertySourceSequential.Kind)
    }
    public let owner: Owner
    public let ownerLine: Int
    public let ownerByteOffset: Int
    public let functionLine: Int
    public let functionByteOffset: Int

    internal init(owner: Owner, ownerLine: Int, ownerByteOffset: Int, functionLine: Int, functionByteOffset: Int) {
        self.owner = owner; self.ownerLine = ownerLine; self.ownerByteOffset = ownerByteOffset
        self.functionLine = functionLine; self.functionByteOffset = functionByteOffset
    }
}
