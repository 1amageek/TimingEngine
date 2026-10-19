import CircuiteFoundation
import Foundation
import STAEngine
import TimingCore

/// CLI composition consumes domain-owned requests and checked execution without a second STA policy.
enum TimingSTARequestCommand {
    static let resourceOptions: Set<String> = ["--maximum-request-bytes","--maximum-input-bytes","--maximum-scenarios",
        "--maximum-design-elements","--maximum-paths","--maximum-path-states","--maximum-path-work-units",
        "--maximum-source-storage-bytes","--maximum-source-work","--source-timeout-seconds"]
    static let help = """
    run-sta --design FILE --library FILE --constraints FILE --pdk-manifest FILE --process ID --pdk-version VERSION --corner ID [existing STA options]
    run-sta --request FILE --maximum-request-bytes N --workspace-root ROOT [--out DIR] [resource options]
    Request mode requires STARequest schema 4 with requireStrictSourceEvidence=true.
    Request mode resource options (positive integers; omitted native limits retain public defaults):
      --maximum-input-bytes N --maximum-scenarios N --maximum-design-elements N
      --maximum-paths N --maximum-path-states N --maximum-path-work-units N
    Source overrides must be supplied together, otherwise the original defaults apply:
      --maximum-source-storage-bytes N --maximum-source-work N --source-timeout-seconds N
    """

    static func run(_ arguments: [String]) async throws {
        let options = try Options(arguments)
        let root = URL(filePath:try options.required("--workspace-root"),directoryHint:.isDirectory)
            .standardizedFileURL.resolvingSymlinksInPath()
        let requestURL = URL(fileURLWithPath:try options.required("--request"),relativeTo:root).standardizedFileURL
        let bytes = try TimingCLIRequestFile.read(requestURL,maximumBytes:options.unsigned("--maximum-request-bytes",hostAddressable:true))
        let request: STARequest
        do { request = try JSONDecoder().decode(STARequest.self,from:bytes) }
        catch { throw TimingError.parseFailure(format:"STA request",line:1,message:String(describing:error)) }
        guard request.requireStrictSourceEvidence else {
            throw TimingError.invalidInput("STA request mode requires requireStrictSourceEvidence=true; ordinary file mode remains available")
        }
        let store = try options.values["--out"].map {
            try FileSystemTimingArtifactStore(workspaceRoot:root,outputDirectory:URL(fileURLWithPath:$0,relativeTo:root))
        }
        let reader = FileSystemTimingArtifactReader(workspaceRoot:root)
        let resources = STAExecutionResources(reader:reader,sourceLimits:try .init(maximumNestingDepth:64),
            sourceResources:try options.sourceResources(),limits:try options.nativeLimits())
        let engine = NativeSTAEngine(reader:reader)
        let prepared = try await engine.prepare(request,resources:resources)
        let measured = try await engine.execute(prepared)
        guard measured.status == .completed else { throw TimingError.invalidInput("Strict STA execution did not complete") }
        try await engine.validateSourceEvidence(measured,against:prepared)
        try Task.checkCancellation(); try resources.sourceResources.check()
        var artifacts: [TimingArtifactBinding] = []
        if let store {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            artifacts.append(try await store.store(encoder.encode(measured.payload),artifactName:"timing-sta-report",
                runID:request.runID,kind:.report,format:.json))
        }
        let result = try STAExecutionResult(runID:measured.runID,status:measured.status,payload:measured.payload,
            inputBindings:measured.inputBindings,artifactBindings:artifacts,diagnostics:measured.diagnostics,
            provenance:measured.evidence.provenance,schemaVersion:measured.schemaVersion)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        print(String(decoding:try encoder.encode(result),as:UTF8.self))
    }

    private struct Options {
        let values: [String:String]
        init(_ arguments: [String]) throws {
            let allowed = TimingSTARequestCommand.resourceOptions.union(["--request","--workspace-root","--out"])
            var parsed: [String:String] = [:]
            var index = 0
            while index < arguments.count {
                let key = arguments[index]
                guard allowed.contains(key), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw TimingError.invalidInput("Unknown or incomplete strict STA request option: " + key)
                }
                guard parsed[key] == nil else { throw TimingError.invalidInput("Duplicate strict STA request option: " + key) }
                parsed[key] = arguments[index + 1]; index += 2
            }
            values = parsed
        }
        func required(_ key: String) throws -> String {
            guard let value = values[key], !value.isEmpty else { throw TimingError.invalidInput("Missing " + key) }
            return value
        }
        func unsigned(_ key: String, default fallback: UInt64? = nil, hostAddressable: Bool = false) throws -> UInt64 {
            if values[key] == nil, let fallback { return fallback }
            guard let value = UInt64(try required(key)), value > 0,
                  !hostAddressable || value < UInt64(Int.max) else {
                throw TimingError.invalidInput(key + " requires a positive bounded integer")
            }
            return value
        }
        func count(_ key: String, default fallback: Int) throws -> Int {
            Int(try unsigned(key,default:UInt64(fallback),hostAddressable:true))
        }
        func nativeLimits() throws -> STAExecutionLimits {
            let defaults = try STAExecutionLimits()
            return try .init(maximumInputBytes:unsigned("--maximum-input-bytes",default:defaults.maximumInputBytes,hostAddressable:true),
                maximumScenarios:count("--maximum-scenarios",default:defaults.maximumScenarios),
                maximumDesignElements:count("--maximum-design-elements",default:defaults.maximumDesignElements),
                maximumPaths:count("--maximum-paths",default:defaults.maximumPaths),
                maximumPathStates:count("--maximum-path-states",default:defaults.maximumPathStates),
                maximumPathWorkUnits:unsigned("--maximum-path-work-units",default:defaults.maximumPathWorkUnits))
        }
        func sourceResources() throws -> STALibertyResources {
            let keys = ["--maximum-source-storage-bytes","--maximum-source-work","--source-timeout-seconds"]
            guard keys.contains(where:{ values[$0] != nil }) else { return STALibertyResources() }
            guard keys.allSatisfy({ values[$0] != nil }) else { throw TimingError.invalidInput("Source storage, work and timeout overrides must be supplied together") }
            let seconds = try unsigned("--source-timeout-seconds")
            guard seconds <= UInt64(Int64.max / 1_000_000_000) else { throw TimingError.invalidInput("Source timeout exceeds the host nanosecond range") }
            return STALibertyResources(maximumStorageBytes:try unsigned(keys[0],hostAddressable:true),
                maximumWork:try unsigned(keys[1]),maximumDuration:.nanoseconds(Int64(seconds) * 1_000_000_000))
        }
    }
}
