/// Exact immutable source requirements, retaining the original owner and actual inventory backing.
public final class LibertyNormalPowerRequirements: Sendable {
    public let cell: String
    public let sourceLine: Int
    public let sourceByteOffset: Int
    public let powerPins: [LibertySourcePowerPin]
    public let functionOrigins: [LibertyNormalPowerFunctionOrigin]
    public var requiresCondition: Bool { !powerPins.isEmpty || !functionOrigins.isEmpty }
    private let source: OwnedLibertySource
    private let reservation: LibertySourceStorageReservation

    internal init(cell: LibertySourceCell, functions: [LibertyNormalPowerFunctionOrigin], source: OwnedLibertySource,
                  reservation: LibertySourceStorageReservation) {
        self.cell = cell.name; sourceLine = cell.line; sourceByteOffset = cell.byteOffset
        powerPins = cell.powerPins; functionOrigins = functions; self.source = source; self.reservation = reservation
    }
}
