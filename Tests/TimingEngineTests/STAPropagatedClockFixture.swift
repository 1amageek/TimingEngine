import Foundation
import CircuiteFoundation
import PDKCore
import STAEngine
import TimingCore

/// One retained physical candidate is used by direct and process-level clock tests.
struct STAPropagatedClockFixture {
    let request: STARequest
    let reader: InMemoryTimingArtifactReader
    static let sdc = """
    create_clock -name clk -period 20ns -waveform {1ns 11ns} [get_ports clk]
    set_clock_transition -rise 0.2ns [get_clocks clk]
    set_clock_transition -fall 0.3ns [get_clocks clk]
    set_propagated_clock [get_clocks clk]
    set_clock_uncertainty 0.01ns [get_clocks clk]
    set_input_transition 0.2ns [all_inputs]
    set_input_delay -clock clk -max 1ns [get_ports din]
    set_input_delay -clock clk -min 0.5ns [get_ports din]
    """
    static var options: STADistributedRCOptions {
        get throws { try .init(maximumTimeStep: 2e-11, stopTime: 2e-7, crossingTolerance: 2e-12,
            maximumRefinements: 10, maximumNodes: 16, maximumSteps: 2_000_000) }
    }
    static var design: TimingDesign {
        .init(topDesignName: "top", ports: [.init(name: "clk", direction: .input, net: "root"),
            .init(name: "din", direction: .input, net: "din"), .init(name: "out", direction: .output, net: "out")],
            instances: [.init(name: "B", cell: "BUF", connections: ["A":"root", "Y":"leaf"]),
                .init(name: "L", cell: "FF", connections: ["D":"din", "CLK":"leaf", "Q":"data"]),
                .init(name: "C", cell: "FF", connections: ["D":"data", "CLK":"leaf", "Q":"out"])],
            nets: ["root", "leaf", "din", "data", "out"].map { .init(name: $0) })
    }
    static let spef = """
    *SPEF "IEEE 1481-1998"
    *C_UNIT 1 PF
    *R_UNIT 1 OHM
    *D_NET root 0.2
    *CONN
    *P clk I
    *I B:A I
    *CAP
    1 B:A 0.2
    *RES
    1 clk B:A 1000
    *END
    *D_NET leaf 0.3
    *CONN
    *I B:Y O
    *I L:CLK I
    *I C:CLK I
    *CAP
    1 L:CLK 0.1
    2 C:CLK 0.2
    *RES
    1 B:Y L:CLK 1000
    2 B:Y C:CLK 1500
    *END
    *D_NET data 0.2
    *CONN
    *I L:Q O
    *I C:D I
    *CAP
    1 C:D 0.2
    *RES
    1 L:Q C:D 1000
    *END
    """
    static func liberty(delay: Double, invert: Bool = false) -> String {
        func tables(_ d: Double, _ slew: Double) -> String {
            """
            cell_rise (nldm) { values ("\(d), \(d)", "\(d + 2), \(d + 2)"); }
            cell_fall (nldm) { values ("\(d + 0.1), \(d + 0.1)", "\(d + 2.1), \(d + 2.1)"); }
            rise_transition (nldm) { values ("\(slew), \(slew)", "\(slew), \(slew)"); }
            fall_transition (nldm) { values ("\(slew + 0.1), \(slew + 0.1)", "\(slew + 0.1), \(slew + 0.1)"); }
            """
        }
        func checks(_ type: String) -> String {
            """
            timing () { related_pin : "CLK"; timing_type : \(type)_rising;
              rise_constraint (checks) { values ("0.1, 2.1", "2.1, 4.1"); }
              fall_constraint (checks) { values ("0.2, 2.2", "2.2, 4.2"); } }
            """
        }
        return """
        library (clockcells) { time_unit : "1ns"; capacitive_load_unit (1, pf);
          input_threshold_pct_rise : 40; input_threshold_pct_fall : 60;
          output_threshold_pct_rise : 60; output_threshold_pct_fall : 40;
          lu_table_template (nldm) { variable_1 : input_net_transition; variable_2 : total_output_net_capacitance;
            index_1 ("0, 20"); index_2 ("0, 20"); }
          lu_table_template (checks) { variable_1 : constrained_pin_transition; variable_2 : related_pin_transition;
            index_1 ("0, 20"); index_2 ("0, 20"); }
          cell (BUF) { pin (A) { direction : input; capacitance : 0.05; }
            pin (Y) { direction : output; function : "\(invert ? "!A" : "A")";
              timing () { related_pin : "A"; timing_sense : \(invert ? "negative_unate" : "positive_unate"); \(tables(delay, 0.25)) } } }
          cell (FF) { ff (IQ, IQN) { clocked_on : "CLK"; next_state : "D"; }
            pin (CLK) { direction : input; clock : true; capacitance : 0.05; min_pulse_width_high : 0.5; }
            pin (D) { direction : input; capacitance : 0.05; \(checks("setup")) \(checks("hold")) }
            pin (Q) { direction : output; function : "IQ";
              timing () { related_pin : "CLK"; timing_type : rising_edge; timing_sense : non_unate; \(tables(delay + 0.2, 0.3)) } }
          }
        }
        """
    }
    init(sdc: String = Self.sdc, spef: String = Self.spef, invert: Bool = false,
         variation: STAVariation = .init(), selected: STADistributedRCOptions? = nil,
         design supplied: TimingDesign? = nil, analysisKinds: [STAAnalysisKind] = [.setup, .hold], libraryMutation: ((String) -> String)? = nil) throws {
        let libs = ["typical": Data((libraryMutation?(Self.liberty(delay: 0.4, invert: invert)) ?? Self.liberty(delay: 0.4, invert: invert)).utf8),
                    "slow": Data((libraryMutation?(Self.liberty(delay: 0.8, invert: invert)) ?? Self.liberty(delay: 0.8, invert: invert)).utf8)]
        let designBytes = try JSONEncoder().encode(supplied ?? Self.design), constraintsBytes = Data(sdc.utf8), parasiticBytes = Data(spef.utf8)
        let manifestBytes = try PDKManifestCodec.encode(STATestProcessFactory.manifest(libraries: libs))
        let d = try STAProcessTestFixture.binding(designBytes, path: "design.json", kind: .netlist, format: .json)
        let c = try STAProcessTestFixture.binding(constraintsBytes, path: "constraints.sdc", kind: .constraints, format: .sdc)
        let p = try STAProcessTestFixture.binding(parasiticBytes, path: "network.spef", kind: .parasitics, format: .spef)
        let m = try STAProcessTestFixture.binding(manifestBytes, path: "pdk.json", kind: .technology, format: .json)
        var artifacts = [d.id:designBytes, c.id:constraintsBytes, p.id:parasiticBytes, m.id:manifestBytes]
        var references: [TimingLibraryReference] = []
        for corner in libs.keys.sorted() {
            let bytes = libs[corner]!, binding = try STAProcessTestFixture.binding(bytes, path: corner + ".lib", kind: .model, format: .liberty)
            artifacts[binding.id] = bytes; references.append(.init(artifact: binding, cornerIDs: [corner]))
        }
        request = try .init(runID: "propagated-clock-exact", design: d, topDesignName: "top", libraries: references,
            constraints: c, requestedModeIDs: ["functional"], requestedCornerIDs: ["typical", "slow"], pdkManifest: m,
            processID: "test", pdkVersion: "1", parasitics: p, analysisKinds: analysisKinds, requiresPostLayoutInputs: true, variation: variation,
            distributedRC: selected ?? Self.options)
        reader = .init(artifacts: artifacts)
    }
}
