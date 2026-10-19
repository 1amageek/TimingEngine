import Foundation
import Testing
@testable import TimingCore

@Suite("Checked source normal-power conditions", .timeLimit(.minutes(1)))
struct LibertyNormalPowerTests {
    private let text = """
    library(L){
      cell(FF){pg_pin(VPWR){pg_type:primary_power;}pg_pin(VGND){pg_type:primary_ground;}
        pg_pin(BIAS){pg_type:primary_power;}
        ff(S,SN){next_state:D;clocked_on:C;power_down_function:"!VPWR";}
        pin(C){direction:input;}pin(D){direction:input;}pin(SLEEP){direction:input;}
        pin(Q){direction:output;function:S;power_down_function:"!VPWR + VGND";}}
      cell(MASK){pg_pin(P){pg_type:primary_power;}ff(S,SN){next_state:D;clocked_on:C;power_down_function:"!P (D + S)";}
        pin(C){direction:input;}pin(D){direction:input;}pin(Q){direction:output;function:S;power_down_function:"!P D";}}
      cell(UNKNOWN){pg_pin(P){pg_type:primary_power;}pin(SLEEP){direction:input;}
        pin(Q){direction:output;function:0;power_down_function:"!P + SLEEP";}}
      cell(NO_LAW){pg_pin(P){pg_type:primary_power;}pin(Q){direction:output;function:0;}}
      cell(EMPTY){pin(Q){direction:output;function:0;}}
    }
    """
    private var conditions: [LibertyPGCondition] {
        [.init(pin:"VPWR",sourcePGType:"primary_power",value:true),
         .init(pin:"VGND",sourcePGType:"primary_ground",value:false),
         .init(pin:"BIAS",sourcePGType:"primary_power",value:true)]
    }
    private func owner(_ text: String? = nil, resources: LibertyCodecTestResources = .init()) throws -> OwnedLibertySource {
        let bytes = Array((text ?? self.text).utf8)
        return try LibertyParser().parseSource(bytes.span,limits:.init(maximumNestingDepth:32),resources:resources)
    }
    @Test func totalPGAndEveryOriginalFunctionHavePositionedBinaryReceipts() throws {
        let source = try owner(), validator: any LibertyNormalPowerValidating = LibertyNormalPowerValidator()
        let requirements = try validator.requirements(source:source,cell:"FF",admit:{ _,_,_ in })
        #expect(requirements.requiresCondition && requirements.powerPins.map(\.name) == ["VPWR","VGND","BIAS"])
        #expect(requirements.functionOrigins.count == 2)
        let checked = try validator.validate(source:source,cell:"FF",conditions:conditions,admit:{ _,_,_ in })
        #expect(checked.receipt.pgValues.map { $0.condition } == conditions)
        #expect(checked.receipt.functions.map(\.origin) == requirements.functionOrigins)
        #expect(checked.receipt.functions.allSatisfy { !$0.result && $0.queries.allSatisfy { $0.domain == .binary && $0.binding == .powerPin && $0.value != nil } })
        let bytes = Array(text.utf8)
        for sample in checked.receipt.functions {
            #expect(String(decoding:bytes.dropFirst(sample.origin.functionByteOffset),as:UTF8.self).hasPrefix("power_down_function"))
        }
        let decoded = try JSONDecoder().decode(LibertyNormalPowerReceipt.self,from:JSONEncoder().encode(checked.receipt))
        let replay = try validator.validate(source:source,cell:"FF",conditions:Array(conditions.reversed()),admit:{ _,_,_ in })
        #expect(decoded == replay.receipt)
    }
    @Test func unreferencedPGMissingDuplicatesWrongTypesSignalsAndPoweredDownAllRefuse() throws {
        let source = try owner(), validator = LibertyNormalPowerValidator()
        let invalid: [[LibertyPGCondition]] = [[],Array(conditions.prefix(2)),conditions + [conditions[0]],
            [.init(pin:"VPWR",sourcePGType:"primary_ground",value:true),conditions[1],conditions[2]],
            [.init(pin:"D",sourcePGType:"primary_power",value:true)] + Array(conditions.dropFirst()),
            [.init(pin:"VPWR",sourcePGType:"primary_power",value:false),conditions[1],conditions[2]]]
        for assignment in invalid {
            #expect(throws:LibertyNormalPowerError.self) { try validator.validate(source:source,cell:"FF",conditions:assignment,admit:{ _,_,_ in }) }
        }
        #expect(throws:LibertyNormalPowerError.self) { try validator.requirements(source:source,cell:"missing",admit:{ _,_,_ in }) }
        let unsupported = try owner("library(L){cell(C){pg_pin(P){}pin(Q){direction:output;function:0;}}}")
        #expect(throws:LibertyNormalPowerError.self) { try validator.validate(source:unsupported,cell:"C",conditions:[.init(pin:"P",sourcePGType:"primary_power",value:true)],admit:{ _,_,_ in }) }
    }
    @Test func nestedTestCellPowerDownCannotDisappearIntoQualifiedAbsence() throws {
        for nested in ["pin(Q){direction:output;function:0;power_down_function:1;}",
                       "ff(S,SN){next_state:0;clocked_on:C;power_down_function:1;}pin(C){direction:input;}"] {
            let source = try owner("library(L){cell(C){pin(Q){direction:output;function:0;}test_cell(){" + nested + "}}}")
            #expect(source.cells[0].unsupportedFunctionalGroups == ["test_cell"])
            let validator = LibertyNormalPowerValidator()
            #expect(throws:LibertyNormalPowerError.self) {
                try validator.requirements(source:source,cell:"C",admit:{ _,_,_ in })
            }
            #expect(throws:LibertyNormalPowerError.self) {
                try validator.validate(source:source,cell:"C",conditions:[],admit:{ _,_,_ in })
            }
        }
    }
    @Test func residualDataAndStateRemainBinaryAndOnlySoundFalseIsAdmitted() throws {
        let source = try owner(), validator = LibertyNormalPowerValidator()
        let on = [LibertyPGCondition(pin:"P",sourcePGType:"primary_power",value:true)]
        let result = try validator.validate(source:source,cell:"MASK",conditions:on,admit:{ _,_,_ in })
        let residual = result.receipt.functions.flatMap(\.queries).filter { $0.binding != .powerPin }
        #expect(Set(residual.map(\.binding)) == [.inputPin,.stateVariable])
        #expect(residual.allSatisfy { $0.value == nil && $0.domain == .binary })
        #expect(result.receipt.functions.allSatisfy { !$0.result })
        #expect(throws:LibertyNormalPowerError.self) { try validator.validate(source:source,cell:"UNKNOWN",conditions:on,admit:{ _,_,_ in }) }
        #expect(throws:LibertyNormalPowerError.self) {
            try validator.validate(source:source,cell:"MASK",conditions:[.init(pin:"P",sourcePGType:"primary_power",value:false)],admit:{ _,_,_ in })
        }
    }
    @Test func noLawStillRequiresAllPGAndEmptySourceIsExplicitlyDistinguished() throws {
        let source = try owner(), validator = LibertyNormalPowerValidator()
        let required = try validator.requirements(source:source,cell:"NO_LAW",admit:{ _,_,_ in })
        let empty = try validator.requirements(source:source,cell:"EMPTY",admit:{ _,_,_ in })
        #expect(required.requiresCondition && !empty.requiresCondition)
        #expect(throws:LibertyNormalPowerError.self) { try validator.validate(source:source,cell:"NO_LAW",conditions:[],admit:{ _,_,_ in }) }
        let checked = try validator.validate(source:source,cell:"NO_LAW",conditions:[.init(pin:"P",sourcePGType:"primary_power",value:false)],admit:{ _,_,_ in })
        #expect(checked.receipt.pgValues.count == 1 && checked.receipt.pgValues[0].condition.value == false && checked.receipt.functions.isEmpty)
        #expect(try validator.validate(source:source,cell:"EMPTY",conditions:[],admit:{ _,_,_ in }).receipt.pgValues.isEmpty)
    }
    @Test func exactReservationBytesPrecedeAllocationAndOriginalWorkLedgerNeverResets() throws {
        let resources = LibertyCodecTestResources(), source = try owner(resources:resources), validator = LibertyNormalPowerValidator()
        let before = resources.work, beforeLive = resources.liveBytes
        var admittedWork: UInt64 = 0, byteNotices: [UInt64] = []
        let checked = try validator.validate(source:source,cell:"FF",conditions:conditions,admit:{ work,_,bytes in
            admittedWork += work
            if bytes > 0 { byteNotices.append(bytes) }
        })
        #expect(resources.work - before == admittedWork && admittedWork > 0)
        #expect(byteNotices.count == 3 && resources.liveBytes - beforeLive == byteNotices[0] && resources.temporaryBytes == 0)
        withExtendedLifetime(checked) {}
        let refusalWork = resources.work, refusalLive = resources.liveBytes, refusalReservations = resources.reservationCount
        do {
            _ = try validator.validate(source:source,cell:"FF",conditions:conditions,admit:{ _,_,bytes in
                if bytes > 0 { throw LibertyCodecTestResources.Failure.cancelled }
            })
            Issue.record("Expected preallocation refusal")
        } catch LibertyNormalPowerError.resource(let cause) {
            #expect(cause as? LibertyCodecTestResources.Failure == .cancelled)
        }
        #expect(resources.work > refusalWork && resources.liveBytes == refusalLive && resources.reservationCount == refusalReservations)
        let baseline = LibertyCodecTestResources()
        _ = try owner(resources:baseline)
        let limited = LibertyCodecTestResources(maximumWork:baseline.work), limitedSource = try owner(resources:limited)
        do {
            _ = try validator.validate(source:limitedSource,cell:"FF",conditions:conditions,admit:{ _,_,_ in })
            Issue.record("Expected cumulative source work refusal")
        } catch LibertyNormalPowerError.resource(let cause) { #expect(cause as? LibertyCodecTestResources.Failure == .work) }
    }
    @Test func copiedCheckedOwnerRetainsSourceAndLiveBackingUntilFinalRelease() throws {
        let resources = LibertyCodecTestResources()
        var source: OwnedLibertySource? = try owner(resources:resources)
        var checked: CheckedLibertyNormalPower? = try LibertyNormalPowerValidator().validate(source:try #require(source),cell:"FF",conditions:conditions,admit:{ _,_,_ in })
        var copy = checked
        source = nil; checked = nil
        #expect(resources.liveBytes > 0 && copy?.receipt.functions.count == 2)
        copy = nil
        #expect(resources.liveBytes == 0 && resources.temporaryBytes == 0 && resources.releaseCount == resources.reservationCount)
    }
}
