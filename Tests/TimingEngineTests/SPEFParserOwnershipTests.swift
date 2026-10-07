import Foundation
import Testing
@testable import TimingCore

struct SPEFParserOwnershipTests {
    @Test("Scoped exporter bytes resolve complete pin and internal node ownership")
    func scopedExporterOwnership() throws {
        let source = """
        *SPEF "IEEE 1481-1998"
        *DELIMITER :
        *C_UNIT 1 PF
        *R_UNIT 1 KOHM
        *NAME_MAP
        *1 PEX_IDENTITY_V1_00
        *2 aggressor
        *3 aggressor:1
        *4 PEX_PIN_76696374696d_51
        *5 victim
        *D_NET *2 0.03
        *CAP
        1 *3 0.01
        2 *3 *4 0.02
        *RES
        1 *3 aggressor:2 0.5
        *END
        *D_NET *5 0.04
        *CONN
        *P *4 B
        *CAP
        1 *4 0.04
        *END
        """
        let value = try SPEFParser().parse(Data(source.utf8))
        #expect(value.networks.map(\.name) == ["aggressor", "victim"])
        #expect(value.network(named: "aggressor")?.totalCapacitance == 0.03e-12)
        #expect(value.network(named: "aggressor")?.groundCapacitance == 0.01e-12)
        #expect(value.network(named: "aggressor")?.resistance == 500)
        #expect(value.couplings == [.init(firstNet: "aggressor", secondNet: "victim", capacitance: 0.02e-12)])
        #expect(TimingCanonicalValidator().validateSignalIntegrityParasitics(value).isValid)
    }

    @Test("Mapped prefixes and custom delimiters preserve exact root identities")
    func mappedPrefixesAndRootIdentity() throws {
        let source = """
        *DELIMITER |
        *C_UNIT 1 FF
        *NAME_MAP
        *1 top/root
        *2 other
        *3 cell|Q
        *D_NET *1 7
        *CONN
        *P top/root O
        *CAP
        1 *1|1 3
        2 *1|1 *3 4
        *END
        *D_NET *2 4
        *CONN
        *I *3 I
        *END
        """
        let value = try SPEFParser().parse(Data(source.utf8))
        #expect(value.networks.map(\.name) == ["other", "top/root"])
        let ground = try #require(value.network(named: "top/root")?.groundCapacitance)
        #expect(abs(ground - 3e-15) < 1e-28)
        #expect(value.couplings == [.init(firstNet: "top/root", secondNet: "other", capacitance: 4e-15)])
    }

    @Test("Bare external root nets preserve partial parasitic coverage")
    func partialRootCoverage() throws {
        let value = try SPEFParser().parse(Data("*D_NET out 2\n*CAP\n1 out input 2\n*END\n".utf8))
        #expect(value.networks.map(\.name) == ["out"])
        #expect(value.couplings == [.init(firstNet: "out", secondNet: "input", capacitance: 2)])
    }

    @Test("Escaped delimiter characters stay in the canonical root identity")
    func escapedDelimiter() throws {
        let source = #"""
        *DELIMITER :
        *D_NET root\:port 1
        *CAP
        1 root\:port:1 external 1
        *END
        """#
        let value = try SPEFParser().parse(Data(source.utf8))
        #expect(value.networks.map(\.name) == ["root:port"])
        #expect(value.couplings.first?.firstNet == "root:port")
        #expect(value.couplings.first?.secondNet == "external")
    }

    @Test("Unknown scoped endpoints and name-map references fail with physical lines")
    func unknownOwnership() {
        let unknownPin = "\n*D_NET root 1\n*CAP\n1 root missing:Q 1\n*END\n"
        #expect(throws: TimingError.spefOwnership(TimingSPEFError.unknownEndpoint(line: 4, endpoint: "missing:Q"))) {
            _ = try SPEFParser().parse(Data(unknownPin.utf8))
        }
        let unknownNode = "*D_NET root 1\n*CAP\n1 root missing:1 1\n*END\n"
        #expect(throws: TimingError.spefOwnership(TimingSPEFError.unknownEndpoint(line: 3, endpoint: "missing:1"))) {
            _ = try SPEFParser().parse(Data(unknownNode.utf8))
        }
        #expect(throws: TimingError.spefOwnership(TimingSPEFError.unknownNameMapReference(line: 1, reference: "*2"))) {
            _ = try SPEFParser().parse(Data("*D_NET *2 1\n*END\n".utf8))
        }
        #expect(throws: TimingError.spefOwnership(TimingSPEFError.unknownNameMapReference(line: 3, reference: "*9"))) {
            _ = try SPEFParser().parse(Data("*D_NET root 1\n*CAP\n1 root *9:1 1\n*END\n".utf8))
        }
    }

    @Test("Connections cannot publish contradictory or ambiguous ownership")
    func conflictingAndAmbiguousOwnership() {
        let conflicting = """
        *D_NET a 0
        *CONN
        *I cell:Q O
        *END
        *D_NET b 0
        *CONN
        *I cell:Q O
        *END
        """
        #expect(throws: TimingError.spefOwnership(TimingSPEFError.conflictingConnection(line: 7, endpoint: "cell:Q", firstNet: "a", secondNet: "b"))) {
            _ = try SPEFParser().parse(Data(conflicting.utf8))
        }
        let ambiguous = """
        *D_NET a 1
        *CAP
        1 a:1 b 1
        *END
        *D_NET b 0
        *CONN
        *P a:1 O
        *END
        """
        #expect(throws: TimingError.spefOwnership(TimingSPEFError.ambiguousEndpoint(line: 3, endpoint: "a:1", nets: ["a", "b"]))) {
            _ = try SPEFParser().parse(Data(ambiguous.utf8))
        }
        let exactNetCollision = "*D_NET a 1\n*CAP\n1 a:1 b 1\n*END\n*D_NET a:1 0\n*END\n"
        #expect(throws: TimingError.spefOwnership(TimingSPEFError.ambiguousEndpoint(line: 3, endpoint: "a:1", nets: ["a", "a:1"]))) {
            _ = try SPEFParser().parse(Data(exactNetCollision.utf8))
        }
    }

    @Test("Duplicate identities and intra-net coupling cannot be silently replaced")
    func duplicateAndIntraNetFailure() {
        #expect(throws: TimingError.spefOwnership(TimingSPEFError.duplicateNameMapReference(line: 3, reference: "*1"))) {
            _ = try SPEFParser().parse(Data("*NAME_MAP\n*1 root\n*1 other\n*D_NET *1 0\n*END\n".utf8))
        }
        #expect(throws: TimingError.spefOwnership(TimingSPEFError.duplicateNetwork(line: 3, net: "root"))) {
            _ = try SPEFParser().parse(Data("*D_NET root 0\n*END\n*D_NET root 0\n*END\n".utf8))
        }
        #expect(throws: TimingError.spefOwnership(TimingSPEFError.intraNetCoupling(line: 3, net: "root"))) {
            _ = try SPEFParser().parse(Data("*D_NET root 1\n*CAP\n1 root:1 root:2 1\n*END\n".utf8))
        }
    }

    @Test("Converted capacitances and accumulated resistance remain finite")
    func numericOverflow() {
        for source in [
            "*C_UNIT 1e308 F\n*D_NET root 2\n*END\n",
            "*C_UNIT 1e308 F\n*D_NET root 0\n*CAP\n1 root external 2\n*END\n",
            "*D_NET root 0\n*RES\n1 root:1 root:2 1e308\n2 root:2 root:3 1e308\n*END\n"
        ] {
            #expect(throws: TimingError.self) {
                _ = try SPEFParser().parse(Data(source.utf8))
            }
        }
    }
}
