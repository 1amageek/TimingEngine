public protocol LibertyNormalPowerValidating: Sendable {
    func requirements(source: borrowing OwnedLibertySource, cell: String,
                      admit: (UInt64, Int, UInt64) throws -> Void)
        throws(LibertyNormalPowerError) -> LibertyNormalPowerRequirements

    func validate(source: borrowing OwnedLibertySource, cell: String, conditions: [LibertyPGCondition],
                  admit: (UInt64, Int, UInt64) throws -> Void)
        throws(LibertyNormalPowerError) -> CheckedLibertyNormalPower
}
