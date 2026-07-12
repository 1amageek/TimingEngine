import Foundation

public struct STAVariation: Sendable, Hashable, Codable {
    public var lateCellDelayScale: Double
    public var earlyCellDelayScale: Double
    public var lateInterconnectDelayScale: Double
    public var earlyInterconnectDelayScale: Double

    public init(
        lateCellDelayScale: Double = 1,
        earlyCellDelayScale: Double = 1,
        lateInterconnectDelayScale: Double = 1,
        earlyInterconnectDelayScale: Double = 1
    ) {
        self.lateCellDelayScale = lateCellDelayScale
        self.earlyCellDelayScale = earlyCellDelayScale
        self.lateInterconnectDelayScale = lateInterconnectDelayScale
        self.earlyInterconnectDelayScale = earlyInterconnectDelayScale
    }

    public var isValid: Bool {
        [lateCellDelayScale, earlyCellDelayScale, lateInterconnectDelayScale, earlyInterconnectDelayScale]
            .allSatisfy { $0.isFinite && $0 > 0 }
    }
}
