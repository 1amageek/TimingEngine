import CircuiteFoundation
import Foundation
import STAEngine
import TimingCore

/// Actual process tests and direct API execution consume identical retained request bindings.
struct STAStrictRequestCLIFixture {
    let root: URL
    let request: STARequest

    init() async throws {
        root = FileManager.default.temporaryDirectory.appending(path:"sta-strict-request-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let powers = """
        pg_pin(VPWR){pg_type:primary_power;}pg_pin(VGND){pg_type:primary_ground;}
        pg_pin(VPB){pg_type:nwell;}pg_pin(VNB){pg_type:pwell;}
        """
        let base = try STAPropagatedClockFixture(sdc:STAPropagatedClockFixture.sdc
            + "\nset_output_delay 0ns -clock clk [get_ports out]", spef:STAPropagatedClockFixture.spef + "\n" + """
        *D_NET din 0.05
        *CONN
        *P din I
        *I L:D I
        *CAP
        1 L:D 0.05
        *RES
        1 din L:D 100
        *END
        *D_NET out 0.05
        *CONN
        *I C:Q O
        *P out O
        *CAP
        1 out 0.05
        *RES
        1 C:Q out 100
        *END
        """,analysisKinds:[.setup,.hold,.recovery,.removal,.pulseWidth],libraryMutation:{ text in
            text.replacingOccurrences(of:"library (clockcells) {",with:"library (clockcells) { operating_conditions(tt){process:1;voltage:1;temperature:25;}")
                .replacingOccurrences(of:"cell (BUF) {",with:"cell (BUF) {" + powers)
                .replacingOccurrences(of:"cell (FF) {",with:"cell (FF) {" + powers)
                .replacingOccurrences(of:"next_state : \"D\";",with:"next_state : \"D\";power_down_function:\"!VPWR + VGND\";")
                .replacingOccurrences(of:"pin (Y) { direction : output;",with:"pin (Y) { direction : output;power_down_function:\"!VPWR + VGND\";")
                .replacingOccurrences(of:"pin (Q) { direction : output;",with:"pin (Q) { direction : output;power_down_function:\"!VPWR + VGND\";")
        })
        let original = base.request
        var assumptions: [STAOperatingSupplyAssumption] = []
        for library in original.libraries {
            for corner in library.cornerIDs {
                for instance in STAPropagatedClockFixture.design.instances {
                    for (pin,type,value) in [("VPWR","primary_power",TimingDesign.Constant.one),("VGND","primary_ground",.zero),
                                             ("VPB","nwell",.one),("VNB","pwell",.zero)] {
                        assumptions.append(try .init(instance:instance.name,cell:instance.cell,cornerID:corner,
                            library:library.artifact.reference,pin:pin,sourcePGType:type,value:value))
                    }
                }
            }
        }
        request = try .init(runID:"strict-cli",design:original.design,topDesignName:original.topDesignName,
            libraries:original.libraries,constraints:original.constraints,requestedModeIDs:original.requestedModeIDs,
            requestedCornerIDs:original.requestedCornerIDs,pdkManifest:original.pdkManifest,processID:original.processID,
            pdkVersion:original.pdkVersion,parasitics:original.parasitics,analysisKinds:original.analysisKinds,
            requiresPostLayoutInputs:true,characterizationPolicy:.requireObservedConditions,
            characterizationBindings:original.requestedCornerIDs.map { .init(cornerID:$0,conditionName:"tt",requiredNumericProcess:1) },
            distributedRC:original.distributedRC,requireStrictSourceEvidence:true,operatingSupplyAssumptions:assumptions)
        for (binding,name) in [(request.design,"design.json"),(request.constraints,"constraints.sdc"),
                               (request.pdkManifest,"pdk.json"),(request.parasitics!,"network.spef")] {
            try await base.reader.read(binding).write(to:root.appending(path:name))
        }
        for library in request.libraries {
            try await base.reader.read(library.artifact).write(to:root.appending(path:library.cornerIDs[0] + ".lib"))
        }
        try JSONEncoder().encode(request).write(to:root.appending(path:"request.json"))
    }

    var arguments: [String] {
        ["run-sta","--request",root.appending(path:"request.json").path,"--maximum-request-bytes","1048576",
         "--workspace-root",root.path,"--out",root.appending(path:"out").path,
         "--maximum-input-bytes","33554432","--maximum-source-storage-bytes","1073741824",
         "--maximum-source-work","1000000000","--source-timeout-seconds","90"]
    }

    func prepared() async throws -> (NativeSTAEngine,PreparedSTAExecution) {
        let reader = FileSystemTimingArtifactReader(workspaceRoot:root), engine = NativeSTAEngine(reader:FileSystemTimingArtifactReader(workspaceRoot:root))
        let prepared = try await engine.prepare(request,resources:.init(reader:reader,sourceLimits:try .init(maximumNestingDepth:64),
            sourceResources:STALibertyResources(maximumStorageBytes:1_073_741_824,maximumWork:1_000_000_000,maximumDuration:.seconds(90)),
            limits:try .init(maximumInputBytes:33_554_432)))
        return (engine,prepared)
    }
}
