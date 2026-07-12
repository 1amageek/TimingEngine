import Foundation

public struct TimingExternalOracleProbe: Sendable {
    public init() {}

    public func probe(
        oracleID: String = "external-digital-sta",
        executableNames: [String] = ["sta", "opensta", "pt_shell", "tempus"]
    ) -> TimingExternalOracleEvidence {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for directory in pathDirectories {
            for name in executableNames {
                let path = URL(filePath: directory).appending(path: name).path(percentEncoded: false)
                if FileManager.default.isExecutableFile(atPath: path) {
                    return TimingExternalOracleEvidence(
                        oracleID: oracleID,
                        status: .available,
                        executablePath: path,
                        details: "An external STA executable was found; version and correlation must still be retained."
                    )
                }
            }
        }
        return TimingExternalOracleEvidence(
            oracleID: oracleID,
            status: .unavailable,
            details: "No configured external digital STA executable was found in PATH."
        )
    }
}
