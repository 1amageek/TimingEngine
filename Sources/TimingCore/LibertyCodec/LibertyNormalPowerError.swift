public enum LibertyNormalPowerError: Error, Sendable {
    case missingCell(String)
    case ambiguousSource(String)
    case missingPGValue(String)
    case invalidPGCondition(String)
    case missingPGType(String)
    case unsupportedSource(String)
    case unknownPowerDown(LibertyNormalPowerFunctionOrigin)
    case poweredDown(LibertyNormalPowerFunctionOrigin)
    case invalidProgram(LibertyNormalPowerFunctionOrigin)
    case arithmeticOverflow
    case resource(any Error)
}
