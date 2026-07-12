import Foundation
import Testing
@testable import TimingCore

@Suite("TimingCore parsers")
struct TimingCoreTests {
    @Test("Liberty parses combinational and sequential timing arcs")
    func libertyParser() throws {
        let library = try LibertyParser().parse(Data(Self.liberty.utf8))
        #expect(library.timeUnitScale == 1e-9)
        #expect(library.capacitanceUnitScale == 1e-12)
        #expect(library.cells["INV"]?.arcs.count == 1)
        #expect(library.cells["DFF"]?.sequentialModel?.dataPin == "D")
        #expect(library.cells["DFF"]?.sequentialModel?.clockPin == "CLK")
        #expect(abs((library.cells["DFF"]?.sequentialModel?.setupTime ?? 0) - 0.2e-9) < 1e-21)
        #expect(library.cells["INV"]?.powerModel != nil)
    }

    @Test("Liberty skips edge-specific arcs without inventing the missing edge")
    func libertyPartialArc() throws {
        let liberty = """
        library (partial) {
          time_unit : "1ns";
          cell (INV) {
            pin (A) { direction : input; }
            pin (Y) {
              direction : output;
              timing () {
                related_pin : "A";
                cell_fall (t) { index_1 ("0.1"); index_2 ("0.0"); values ("1.0"); }
              }
            }
          }
        }
        """

        let library = try LibertyParser().parse(Data(liberty.utf8))
        #expect(library.cells["INV"]?.arcs.isEmpty == true)
    }

    @Test("SDC parses clocks, IO delays and path exceptions")
    func sdcParser() throws {
        let sdc = """
        create_clock -name clk -period 10ns [get_ports clk]
        set_input_delay 1ns -clock clk [get_ports in]
        set_output_delay 2ns -clock clk [get_ports out]
        set_false_path -from [get_ports scan_en] -to [get_ports out]
        group_path -name functional -from [get_ports in] -to [get_ports out] -weight 2
        """
        let constraints = try SDCParser().parse(Data(sdc.utf8), modeID: "functional")
        #expect(constraints.clocks.first?.period == 10e-9)
        #expect(constraints.inputDelays.first?.port == "in")
        #expect(constraints.outputDelays.first?.rise == 2e-9)
        #expect(constraints.exceptions.first?.kind == .falsePath)
        #expect(constraints.pathGroups.first?.name == "functional")
        #expect(constraints.pathGroups.first?.weight == 2)

        let clockGroups = try SDCParser().parse(Data("set_clock_groups -asynchronous -group [get_clocks clk] -group [get_clocks aux]".utf8))
        #expect(clockGroups.clockGroups.first?.kind == .asynchronous)
        #expect(clockGroups.clockGroups.first?.groups == [["clk"], ["aux"]])
    }

    @Test("SDC accepts standard option-before-value port delays")
    func sdcOptionBeforeValue() throws {
        let sdc = """
        create_clock -name clk -period 10 [get_ports clk]
        set_input_delay -clock clk 1 [get_ports in]
        set_output_delay -clock clk 2 -max [get_ports out]
        """

        let constraints = try SDCParser().parse(Data(sdc.utf8))
        #expect(constraints.inputDelays.first?.rise == 1e-9)
        #expect(constraints.inputDelays.first?.clock == "clk")
        #expect(constraints.outputDelays.first?.rise == 2e-9)
        #expect(constraints.outputDelays.first?.isMax == true)
    }

    @Test("SPEF preserves ground and coupling capacitance")
    func spefParser() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *CAP_UNIT 1 PF
        *RES_UNIT 1 OHM
        *D_NET n1 0.03
        *CONN
        *P n1 O
        *CAP
        1 n1 0.02
        2 n1 n2 0.01
        *RES
        1 n1 n2 10
        *END
        """
        let parasitics = try SPEFParser().parse(Data(spef.utf8))
        #expect(parasitics.network(named: "n1")?.groundCapacitance == 0.02e-12)
        #expect(parasitics.couplings.first?.firstNet == "n1")
        #expect(parasitics.couplings.first?.secondNet == "n2")
        #expect(parasitics.network(named: "n1")?.resistance == 10)
    }

    @Test("SDF round trips annotated delays")
    func sdfRoundTrip() throws {
        let value = TimingSDF(timescale: 1e-9, annotations: [
            TimingSDF.Annotation(instance: "U1", fromPin: "A", toPin: "Y", rise: 1e-9, fall: 2e-9)
        ])
        let encoded = SDFWriter().write(value)
        let decoded = try SDFParser().parse(encoded)
        #expect(decoded.annotations.count == 1)
        #expect(decoded.annotations.first?.fromPin == "A")
        #expect(decoded.annotations.first?.rise == 1e-9)
    }

    @Test("Verilog parser creates a stable structural design graph")
    func verilogParser() throws {
        let verilog = """
        module top(input a, input b, output y);
          wire n1;
          INV U1 (.A(a), .Y(n1));
          INV U2 (.A(n1), .Y(y));
        endmodule
        """
        let design = try TimingDesignParser().parse(Data(verilog.utf8), topDesignName: "top")
        #expect(design.topDesignName == "top")
        #expect(design.ports.map(\.name) == ["a", "b", "y"])
        #expect(design.instances.count == 2)
        #expect(design.instances[1].connections["A"] == "n1")
    }

    @Test("unsupported SDC semantics fail with a typed diagnostic error")
    func unsupportedSDC() {
        #expect(throws: TimingError.self) {
            _ = try SDCParser().parse(Data("set_case_analysis 1 [get_ports scan_enable]".utf8))
        }
    }

    static let liberty = """
    library (test) {
      time_unit : "1ns";
      power_unit : "1uW";
      capacitive_load_unit (1, pf);
      cell (INV) {
        cell_leakage_power : 0.1;
        pin (A) { direction : input; capacitance : 0.01; }
        pin (Y) {
          direction : output;
          function : "!A";
          timing () {
            related_pin : "A";
            timing_sense : negative_unate;
            cell_rise (t) { index_1 ("0.1"); index_2 ("0.0"); values ("1.0"); }
            cell_fall (t) { index_1 ("0.1"); index_2 ("0.0"); values ("1.0"); }
            rise_transition (t) { index_1 ("0.1"); index_2 ("0.0"); values ("0.1"); }
            fall_transition (t) { index_1 ("0.1"); index_2 ("0.0"); values ("0.1"); }
          }
        }
      }
      cell (DFF) {
        ff (IQ, IQN) { next_state : "D"; clocked_on : "CLK"; }
        pin (D) {
          direction : input;
          timing () {
            related_pin : "CLK";
            timing_type : setup_rising;
            rise_constraint (t) { index_1 ("0.1"); index_2 ("0.0"); values ("0.2"); }
            fall_constraint (t) { index_1 ("0.1"); index_2 ("0.0"); values ("0.2"); }
          }
        }
        pin (CLK) { direction : input; clock : true; }
        pin (Q) {
          direction : output;
          timing () {
            related_pin : "CLK";
            timing_type : rising_edge;
            cell_rise (t) { index_1 ("0.1"); index_2 ("0.0"); values ("0.5"); }
            cell_fall (t) { index_1 ("0.1"); index_2 ("0.0"); values ("0.5"); }
          }
        }
      }
    }
    """
}
