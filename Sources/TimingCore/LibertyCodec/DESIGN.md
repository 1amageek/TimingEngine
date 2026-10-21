# Liberty Codec

## Purpose and Scope

Own the single Liberty grammar, ordinary library conversion, strict CTS source
characterization, and caller-accounted source intake. Parent:
[TimingCore](../DESIGN.md). No children. Ordinary propagation lookup retains its extrapolation profile.
The owned source API requires PN5.2 behavioral verification before domain use.

## Responsibilities and Boundaries

Sequential source facts retain `power_down_function` as an actual positioned
function. A logic-library consumer must explicitly reject or implement its unknown
state semantics; projection must not manufacture absence of this attribute.

`LibertyParser` conforms to the ordinary parsing/characterization protocols and
the neutral `LibertySourceParsing` protocol. The owned entry accepts a scoped
`Span<UInt8>`, explicit `LibertySourceParseLimits`, and trusted
`LibertySourceResourceAccounting`. It produces `OwnedLibertySource`: one immutable
library plus original cell/pin and raw operating-condition observations, retaining
all live payload receipts. It does not establish artifact identity, named process
or nominal-corner meaning, qualified PVT, engine execution, or PDK admission.
Caller exact source capture and optional PDK bridges remain outside this codec.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [TimingCore](../DESIGN.md) | parent | Timing IR and lookup | Codec owner | Ordinary and CTS numerical semantics remain distinct |
| [ProcessCorners](../../STAEngine/ProcessCorners/DESIGN.md) | used by | Exact manifest/source selection | Future owned intake | Raw numeric process is not a named PDK process |
| [PDK admission](../../../../PDKKit/Sources/PDKProfileAdmission/Admission/DESIGN.md) | coordinates with | Source facts and external accounting bridge | Future optional adapter | No direct dependency or caller-supplied success authority |

## Architecture

```text
Data ordinary entry --------------------------+
Span owned entry -> UTF-8/capability admission +-> one lexer/group grammar
      resources + explicit limits             -> one library/table conversion
                                               -> ordinary library / CTS value
                                               -> immutable owned library + facts
```

## Contracts and Invariants

### Source-bound sequential timing checks

Ordinary and owned Liberty conversion retain setup, hold, recovery and removal
checks as constrained pin, related clock pin/edge, constrained transition and full
slew-dependent table. Both axes are time; declared related/constrained axis order
is normalized. Scalar tables remain valid. A missing check is distinct from an
explicit zero-valued table. Legacy scalar model values are compatibility summaries,
not source-presence evidence; native source parsing supplies an explicit check set.
Conditional timing groups (`when`, `sdf_cond`, `mode`, `when_start`, `when_end`)
are unsupported and fail before unconditional numerical projection in all profiles.
No reset polarity or power-up guarantee is inferred from a timing-sense label.

The existing accounted buffers own new check/table payloads and source strings;
there is no additional shared state or target-specific isolation. Native evaluation
owns clock edges, route arrivals and check coverage. `STANumericalModelTests` proves
nonconstant table consumption, missing-versus-zero, conditional refusal and retained
codec reconstruction. Strict CTS propagation admission remains separate.

### Functional source projection

Owned parsing also projects original cell area/dont_use, explicit pin direction,
output/state/three-state/X functions and ff/latch definitions from the shared
grammar. It never obtains functional meaning from TimingCell's simplified
sequential model. Boolean expressions normalize into flat
`LogicBooleanOperation` tables plus ordered named input slots; the host library
compiler must bind those slots to exact physical input pins/state and rebuild
through LogicIR's validated builder before execution. This codec owns Liberty
spelling and operator precedence: inversion, XOR, AND, OR, in that order.
Prefix !, postfix apostrophe, *, &, whitespace AND, +, |, 0/1 and parentheses
are supported. Identifier syntax is ASCII letters/underscore followed by ASCII
letters/digits/underscore; other terminal spelling is explicitly unsupported.
No function is guessed from cell names or timing sense.

An absent function stays absent. A present malformed/unsupported expression
retains a typed failure fact and original physical attribute position, with no
partial normalized program. Cancellation/storage/work failures propagate out of
parseSource rather than becoming an ineligible-cell fact. Parenthesis/prefix
nesting uses the caller's grammar nesting limit and iterative private stacks.
Duplicate functional attributes are ambiguous source and fail owned admission.
Unsupported functional groups (banks, state tables, memory, buses/bundles,
alternate test cells and multi-name pin groups) are retained as explicit facts for host eligibility.
Multiple sequential groups and simultaneous clear/preset definitions remain
source facts; the host compiler owns whether its declared profile can admit them.
The codec does not grant mapping eligibility, cross-view binding or proof.

### Source-defined sequential models

`TimingSequentialModel.definition` distinguishes caller-declared legacy scalar pins
from source-defined sequential declarations. Single data/clock/output compatibility
views are optional and exist only when the complete source program has that exact
simple form. A missing single-pin view never makes a source-defined cell
combinational. All FF/latch declarations, ordered state variables, complete
next-state/data-in, clock/enable, additional-control, clear/preset and power-down
programs, and actual output functions remain attached to the source model.

Ordinary Liberty `parse(Data)` also compiles actual FF/latch declarations through
the same functional projector and binder. It never labels parsed sequential
source as caller-declared legacy pins. This ordinary profile retains its existing
unaccounted grammar and extrapolating LUT contract; the private helpers accept no
accountant only on that path. Owned intake always supplies its shared accountant
and explicit nesting bound. Neither ordinary source transport nor canonical JSON
grants strict numerical qualification. Only an explicit legacy constructor or
declared legacy JSON can carry a legacy scalar definition.

The codec binds every normalized function slot to an actual declared input pin,
state variable or PG pin. It preserves the complete program rather than selecting
an identifier from an expression. A bound function retains its semantic role and
ordered slot bindings. Missing/unsupported functions, ambiguous declarations or
unresolved symbols retain an explicit unavailable binding with the original
definitions; they do not publish a partially bound success or a nil sequential
model. Allocation, cancellation and accountant failures still abort source intake.

PG declarations and pin-level power-down/related-power/related-ground attributes
are positioned source facts. Their presence grants no supply voltage, powered
state, dynamic power simulation or process qualification. Sequential execution owns
the meaning of enabled FF state updates, latch transparency/closure and async
clear/preset including simultaneous-control values. It consumes complete bound
programs under explicit state/input assumptions; placement does not interpret them.
Host logic-library mapping and equivalence eligibility remain with their existing
owners. Unsupported conditional or multigroup execution must refuse explicitly and
does not complete the requested FF/latch/enable/reset support.

Codable sequential values are declared transport only. Decoding a definition or
source position cannot construct an owned source or qualified numerical evaluator.
Strict consumers re-admit the exact owned Liberty bytes and require complete
source binding before executing stateful semantics.

Timing arcs/checks retain the actual cell/pin, timing type, physical timing-group
position, stable source ordinal and table attribute positions. No source identity
is synthesized for a legacy constructor. The codec supplies source-local identity;
the consuming preparation owner binds it to the exact source ArtifactReference and
corner. Numerical evaluation and receipt publication remain with the admitted
characterization owner.

The immutable admitted characterization owner uniquely resolves source-positioned
propagation/check keys. Propagation consumes actual slew/load and all four tables;
checks consume actual constrained/related slew. Every axis query stays inside its
source domain and every result is finite; constraints retain legitimate signed
values while propagation retains its nonnegative contract. Receipts retain actual
table positions, query, result and domain. Public Codable model/receipt transport
does not grant qualification: retained exact owners revalidate it. Ordinary
extrapolating lookup remains a separately declared compatibility contract.

These additions reuse the same accounted buffers and retention owner. Program,
slot, PG, output and identity collections are admitted before growth. The
LibertyFunctionalSourceTests enabled-FF regression first reproduced the legacy
`next_state` last-identifier error; completion requires full program truth and
actual pin/state/output binding for FF, latch, enable and reset, not merely a
different single data-pin string.

Projection arrays, normalized operations/symbols and parser stacks use the same
accounted LibertyBuffer/Text owners and receipts as the existing grammar.
The shared Mutex retention owner, callback placement and ordinary/CTS conversion
contracts stay unchanged. These new facts are host values, not portable runtime
library owners or new serialization authority.

- `LibertySourceParsing.parseSource(_:limits:resources:)` returns an internally
  constructed non-Codable owner. No public unchecked owner constructor exists.
- Accounting is caller-neutral: `check()`, `chargeWork(_:)`, and
  `reserveStorage(kind:byteCount:)` are protocol requirements. Shared state in an
  external accountant must be synchronized. Errors preserve the original typed
  external cause in `LibertySourceError.resource(any Error)`; cancellation,
  deadline, arithmetic overflow, invalid capacity, syntax, and unsupported source
  semantics remain explicit. The codec never closes an external accountant.
- `LibertySourceStorageReservation` is an externally constructible immutable
  receipt with kind, byte count, and a Sendable release callback. Copies share one
  exactly-once release owner. A receipt grants no source or result authority.
- Managed capacity means concrete element stride times admitted logical capacity,
  plus UTF-8 payload bytes and actual private owner fields. Runtime/allocator
  headers, native container bucket overhead, alignment padding outside stride,
  process RSS, and Swift allocator rounding are excluded. Token count is work;
  it never substitutes for a byte reservation. Checked multiplication/addition
  precedes every capacity, growth, copy, and materialization.
- Variable collections grow geometrically under a new reservation before
  allocation. Shared snapshot writes reserve and clone even when spare capacity
  exists. Private owner identities never escape separately from their backing.
  Immutable publication retains actual backing, not receipts without payloads.
- Lexer and parser charge/check before byte/token/node operations; transforms
  charge/check before loops, comparisons, scans, numeric conversion, and copies.
  Temporary owners release when parsing finishes or fails. Live source, facts,
  library payload, and retained supporting backing release at the last owner copy.
- Group parsing uses an explicit frame stack. The caller provides a positive
  `maximumNestingDepth`; no production quota defaults are invented. Admission
  precedes stack growth and crossing the configured bound fails explicitly.
- Owned intake strictly validates UTF-8 before copying. Its supported lexical
  capability is ASCII: valid non-ASCII input is explicitly unsupported because
  the existing byte lexer cannot supply cooperative Unicode meaning. Ordinary
  source behavior is preserved. Backslash-LF/CRLF and physical diagnostics use
  the same lexer and conversion in both paths.
- Owned intake accepts exactly one Liberty library and no canonical JSON
  fallback. Active dependency/section constructs cannot be ignored as leaf
  coverage; unsupported include/section constructs are refused. Raw optional
  numeric process/voltage/temperature and original names are observations, never
  synthesized from a manifest, requested corner, path, or policy.
- Ordinary STA LUT defaults, normalization, extrapolation, and strict CTS rules
  retain their existing contracts. Owned source parsing does not grant CTS
  characterization. Source facts preserve declaration order and origins.
- Extracting raw `TimingLibrary`, arrays, or String fields transfers backing
  lifetime responsibility to the caller: retain `OwnedLibertySource` while using
  those borrowed/shared values. Mutation of extracted public timing IR is
  caller-owned work, outside the immutable parse owner contract.

### Existing Ordinary and CTS Semantics

The shared Liberty lexer consumes backslash-LF and backslash-CRLF line
continuations before numeric admission. Outside quoted strings a continuation
separates tokens; inside a quoted string it contributes no character. Physical
line numbers still advance, and a backslash not followed by a newline is not
silently discarded from an unquoted numeric value. This preserves actual
multi-row Sky130 Liberty tables without weakening finite numeric validation.

Strict admission requires positive finite time and explicit capacitance units,
nonnegative finite selected input-pin capacitance from the pin or an explicit
library default_input_pin_cap, unique cell/pin names, and all eight input/output/slew
rise/fall threshold percentages strictly between 0 and 100 with each lower slew
threshold below its upper threshold. Liberty R-2020.09 defines omitted time_unit as
1ns, input/output thresholds as 50%, lower slew thresholds as 20%, upper as 80%, and
slew_derate_from_library as 1; only these normative defaults are applied, with the
attribute names retained in standardDefaultAttributes. Capacitance has no invented
fallback. Pin-level threshold overrides are explicitly unsupported in this profile.
Applicable combinational propagation arcs require complete rise/fall delay and
transition tables.
Unconditional combinational arcs require an explicit supported timing sense and
exact related input pin. Conditional or unsupported propagation semantics fail.
Constraint groups remain owned by the ordinary parser and do not become CTS arcs.

Every strict propagation table resolves one unique lu_table_template. Exactly two
axes must represent input_net_transition and total_output_net_capacitance in either
order. Explicit table indexes override template indexes; otherwise the template
supplies them. All indexes and values are finite, nonnegative, dimensionally scaled,
and indexes strictly ascend. Reversed variable order is transposed into the existing
slew-row/load-column representation. Missing axes, scalar/1D/3D or other variables
are unsupported in this profile; no axis or table is synthesized. The published
[Liberty R-2020.09 reference](https://zao111222333.github.io/liberty-db/2020.09/reference_manual.pdf)
defines the template variables and index inheritance.

The immutable characterized value is constructed only by source admission. It
retains pin-versus-library-default capacitance origins and exposes actual pin
capacitance, arc sense and rise/fall evaluation without allowing
mutation or JSON reconstruction to bypass admission. Evaluation rejects nonfinite,
negative and out-of-range slew/load against all four tables, including singleton
axes, and returns delay plus output slew in seconds. Exact boundary queries pass.
Evaluation never extrapolates. Source clock-pin metadata is returned separately
for the caller to enforce sink identity. An explicit slew_derate_from_library other
than 1 is unsupported; characterization never grants signoff qualification.
Existing ordinary STA lookup keeps its separate
extrapolating semantics; it cannot produce a characterized value.

## Runtime Flows

check -> validate bytes/capability -> reserve source -> lex -> iterative groups
-> coverage admission -> accounted existing conversion -> source facts -> check
-> immutable owner. Failure releases private scratch/live storage and publishes
no owned success. No legacy decoder or ordinary parse retry is selected.

## State, Ownership, and Lifecycle

All construction state is invocation-local. Any shared private retention storage
uses one Mutex in every target. Immutable copied owners share receipts and actual
payloads. Resource callbacks run outside a retention lock. No detached tasks,
unsafe pointer escape, unchecked Sendable, or platform-specific synchronization
is introduced. Byte buffer borrows remain within synchronous scoped closures.

| State | Storage / isolation | Read / mutation | Release | Verified platform scope |
|---|---|---|---|---|
| Retained payload slots | `Mutex<State>` on all compilation paths | Short `withLock` slot operations; resource callbacks outside lock | Swap temporary state, then release outside lock; live state at final owner | Native macOS; no WASM/Embedded capability claim |
| Buffer/map/text builders | Invocation-local values + immutable COW identity | Same-capacity reservation before shared writes | Each last builder snapshot drops its receipt | Native macOS |
| Published source / receipt | Immutable Sendable owner | Scoped borrow, no mutation entry | Exactly-once callback after final copy | Native macOS |


## Failure, Concurrency, and Constraints

The parser is synchronous and I/O-free. The caller's accountant supplies deadline
and cancellation sampling. Resource errors propagate without localized variable
diagnostic copies; owned syntax/unsupported errors use static context and original
physical positions. Failed parse payload is released before returning failure.

## Verification and Change Impact

Dedicated `LibertyCodecTests` owns actual ordinary/owned grammar differential,
source facts and raw PVT, LF/CRLF, table dimensions/numbers, JSON/dependency/section
refusal, malformed UTF-8/non-ASCII capability, long token, overflow, pre-allocation
refusal, cancellation/deadline, copied owner release, and same-capacity COW proof.
Parent ordinary characterization regressions cover shared-algorithm behavior.
New domain/host integration remains unimplemented until this lower proof passes;
neither source shape nor successful compilation establishes profile consumption.

`LibertyFunctionalSourceTests` owns precedence, polarity, constants, pin order,
ff/latch controls, source positions, absent/unsupported definitions, duplicate
attributes, resource refusal and retained owner release. Existing codec, STA/SI,
corpus and CLI tests establish cumulative ordinary-path compatibility. Portable
function execution belongs to the independently verified LogicIR/LogicEngine
contracts; these host tests establish no WASM/Embedded TimingCore capability.

### TimingLUT Validation Seam

The codec materializes retained axes, rows, and optional transposed matrices only after
reserving their concrete logical capacities. The shared `TimingLUT` constructor checks
shape, ordered axes, and finite elements with nested iteration; it does not flatten the
matrix. Its internal cooperative callback runs before each validation step. The public
ordinary initializer delegates the same checks without a resource callback, preserving
numerical and error-order semantics. Lookup and CTS algorithms are unchanged. Tests
compare ordinary and owned axes/matrices and exercise refusal during validation.

OwnedLibertySource also retains the admitted library threshold convention, including the existing explicit standard defaults, or a typed unavailable-threshold issue, and whether pin-level threshold overrides occur. Legacy ordinary parsing does not acquire new threshold admission requirements; unavailable facts are never replaced by a fallback. Distributed STA consumes driver output/receiver input thresholds from this same source owner, refusing pin overrides and unsupported slew derates rather than inventing a waveform convention.

Propagated primary FF clock admission also consumes the retained explicit clock-to-Q timing edge (rising_edge/falling_edge). TimingSequentialModel.clockToQEdge distinguishes that source fact from the separately normalized ff clocked_on edge. Legacy numerical consumers retain their previous profile; propagated clocks refuse missing or contradictory edge facts.

### Accounted strict characterization

`LibertySourceCharacterizationParsing.parseCharacterizedSource` admits the same
strict NLDM contract from a scoped byte span under the caller's cumulative
`LibertySourceResourceAccounting` and explicit nesting limit. Selected cell names,
propagation subsets, grammar, tables and capacitance origins retain their actual
payloads and receipts in the immutable `CharacterizedTimingLibrary`. The source
accountant is shared with subsequent host work; this entrypoint never resets work,
deadline or cancellation and never closes the accountant. Every failed admission
releases its private storage before returning `LibertySourceError`, preserving the
original typed resource or characterization cause.

Combinational and sequential propagation subsets are explicit, disjoint subsets
of selected cells. The sequential subset admits FF edge propagation and latch
data/control propagation groups with their actual timing types and all four NLDM
tables. Its selected sequential models retain the same complete source bindings
as owned functional intake; numerical admission grants no
functional eligibility or clock-root policy. Existing `parseCharacterized(Data)`
continues to refuse FF propagation; ordinary parse and extrapolating lookup remain
unchanged. No missing transition table is synthesized in either strict entry.

`LibertyCharacterizedSourceTests` proves checked interpolation/domain refusal,
sequential opt-in, missing-source refusal, cumulative work, byte budgets, deadline,
cancellation and exactly-once owner storage release. This contract can be consumed
by host placement or clock propagation while their candidate/execution policy
remains their own responsibility.

### Positioned pulse-width laws

`TimingCell.pulseWidthConstraints` preserves every actual pin pulse law, independently
of sequential kind. A timing `min_pulse_width` group's rise/fall constraint tables
remain separate opening-edge laws: rise opens a high pulse, fall opens a low pulse.
The owning pin, actual related pin/output pin, group position and table position
remain attached. Pin `min_pulse_width_high` and `min_pulse_width_low` attributes are
independent positioned scalar laws. No clock/control name, absent opposite-edge
table, or sequential declaration creates a pulse requirement.

The admitted table profile is one actual `related_pin_transition` axis with the
original indexed values. An explicit `scalar` table has exactly one value and no
axes; a missing template never becomes a scalar. Scalar pin attributes need no
axis. Extra dimensions, unsupported axis variables, missing/ambiguous tables,
conditional timing, nonfinite/negative data and inconsistent dimensions fail
intake. Ordinary parsing uses the same law representation and retains ordinary LUT
extrapolation through declared values; strict evaluation never extrapolates.
The old `minPulseWidth` property is only a compatibility summary of actual scalar
laws. Multipoint tables are never reduced to a first table/value summary.

`CharacterizedTimingLibrary` publishes the source law inventory and evaluates one
exact source identity/pin/opening edge at the actual input slew. It reuses TimingLUT
interpolation by storing the one-dimensional law against an internal constant
second coordinate; that coordinate is representation only and is absent from the
public `TimingPulseWidthSample`. A table sample retains actual query/domain,
result and source/table positions. Scalar samples retain no fictitious query or
domain. Decoded observations must match exact retained-owner reevaluation.

The STA owner computes received waveform widths, applicability, clock/control
assumptions, slack and complete required-law outcomes. Core owns no waveform or
pass/fail policy. No-law inventory is empty source evidence, distinct from a
missing measurement of an existing law. All parser work, law arrays, tables and
source identities use the existing cumulative accountant and cancellation checks.

`LibertyPulseWidthTests` verifies rise-only latch, both-edge FF and fall-only reset
laws, distinct high/low scalar positions, nonconstant interpolation and boundaries,
ordinary/owned/JSON retention, forged receipts, invalid axes and resource refusal.

### Directional asynchronous-control source arcs

`TimingCell.directionalControlArcs` separately retains actual `clear` and `preset`
timing groups, related input/output pins, sense, source position and each present
delay/transition table. A fall-only clear arc is never discarded, converted into a
normal four-table TimingArc, or supplied with invented rise tables. Strict intake
checks each present table's actual NLDM axes and values. This inventory grants no
dynamic clock/data propagation or state proof authority.

The STA owner binds exact source arcs to source-owned static control/state outcomes
and no-transition dispositions. An explicit checked directional-control evaluation
requires both actual delay and transition tables for its requested output edge;
missing direction/table is a typed failure. Existing numerical sample receipts
retain the two actual table positions and are revalidated against the admitted
owner. Source control/state interpretation stays with the sequential helper.
`LibertyPulseWidthTests` covers fall-only clear/preset retention, static inventory,
requested-direction refusal and exact checked-table receipt replay.

### Checked normal-power source conditions

`LibertyNormalPowerValidating` and `LibertyNormalPowerValidator` own requirements
and validation against an exact retained `OwnedLibertySource` and selected cell.
`LibertyPGCondition` is a common binary transport value, never source authority.
Requirements retain all PG declarations and all pin/declaration power-down origins.
A cell requires a condition when either inventory is nonempty; consumers do not
reimplement this classification. Unsupported functional source groups refuse
because complete power-down absence cannot be established for their contents.

The initial checked normal-power subset refuses `test_cell` as an explicit
unsupported functional source group. Alternate test-mode pins and FF declarations
are not interpreted as ordinary-mode absence, even when direct normal pins have no
power-down function. Owned projection retains the group rather than dropping it;
there is no claim of test-mode execution or all-mode power qualification.

Validation requires exactly one explicit binary value for every declared PG pin,
including declarations unused by a function. Unknown, duplicate, conflicting,
missing, foreign, non-PG, missing-type or mismatched-type conditions refuse. Values
are never inferred from PG type, terminal names, voltage names or nominal voltage.
Every original pin and sequential-declaration power-down function is evaluated.
Unassigned physical inputs and current-state symbols have the full binary domain;
there is no static-input substitution in this profile. The shared pure Boolean
evaluator conservatively returns false, true or unknown. Only false admits a
function, soundly for every residual binary assignment. Unknown is unsupported and
true is powered down. There is no SAT search, assignment enumeration or default
state. Output references, ambiguous slots and unsupported programs refuse.

`CheckedLibertyNormalPower` is internally constructed and non-Codable. It retains
the original source and live receipt backing/reservation. Its Codable receipt
records exact cell position, every PG declaration/type/value/position, every
function owner/position, ordered symbol queries with explicit binary domains, and
false results. A no-law cell still retains all explicit PG declarations and values.
The receipt proves conditional source Boolean behavior, not measured supplies,
electrical qualification, process/corner meaning, mapping eligibility or proof.
Artifact, instance, corner and expansion-policy joins remain consumer-owned.
Decoded receipts must be compared with a new validation against the exact owner.

Both public operations use the existing cumulative
`LibertySourceResourceAccounting` retained by the exact source owner, with no
accountant override. They receive one synchronous nonescaping
`admit(workUnits, logicalStateSlots, exactReservationBytes)` callback. Each loop/comparison/evaluation is
charged before execution; each materialization is admitted before allocation.
Checked capacity/stride arithmetic precedes temporary/live byte reservations.
There is no new operational quota, reset, accountant close, detached task or
callback retention. Temporary reservations release on every exit; the checked
owner retains actual live payload and its receipt until its last reference drops.
External accounting/admission/cancellation failures preserve their typed cause in
`LibertyNormalPowerError.resource`. Source-semantic failures are distinct typed
cases and publish no partial checked owner.

The package-visible `LibertySourceBooleanEvaluation` owns the mechanical normalized
Boolean DAG loop shared with STA. Its slot callback does not interpret state, clock
or reset policy. STA retains those policies and supplies its cumulative budget
admission/checkpoint callbacks. Logic consumes only the checked normal-power API.

`LibertyNormalPowerTests` owns total/duplicate/foreign PG refusals, all positioned
functions, masked and unresolved binary domains, source absence, receipt replay,
resource/cancellation boundaries and retained-owner release. STA strict regression
and actual-source tests own composition; Logic owns conditional compilation and
Physical owns same-candidate joins.

Every new reservation reports its actual byte count before source reservation and
allocation. Consumers never convert slot counts into guessed bytes. The source
accountant/control retains its original run deadline. A later run consumes checked
immutable outcomes, not a new validation against an expired previous-run budget;
reload qualification creates a fresh exact source owner and revalidates there.

### Source-qualified interval evaluation

The immutable characterized owner also evaluates closed input-slew/load/control-slew
rectangles. Every endpoint must remain in each required original table domain;
point evaluation and ordinary extrapolation contracts remain unchanged. Delay and
transition bounds are independent extrema. Every intersected bilinear rectangle
is clipped to the query and all its vertices are enclosed with package-only
[NumericBounds](../NumericBounds/DESIGN.md) arithmetic. Interior nonmonotone knots
are included. No endpoint-only monotonicity assumption or delay-to-slew proxy is
permitted. Constraint bounds remain signed. Pulse laws keep their actual scalar
or one-dimensional source identity, without an invented axis.

Range samples retain exact original group/table identity, queried ranges, actual
source domains and result endpoints. Decoding a sample grants no authority:
`validate` reevaluates it against the admitted immutable owner. Source work uses
that owner's existing cumulative accountant, without reset or a new quota.
Full-domain output-transition bounds scan all original rise/fall values of the
selected exact propagation or directional-control arc. A nonpositive transition
minimum fails the positive-slope authority operation explicitly. The STA owner
must join every relevant arc and edge for each driver; Core grants only source
NLDM bounds, not physical current/CCS guarantees or switching policy.

`LibertyCodecTests/CharacterizedRangeEvaluationTests.swift` owns clipped and interior
extrema, independent delay/slew knots, signed checks, pulse/control ranges,
source-domain refusal and forged sample reevaluation. Existing point tests retain
compatibility ownership. No new mutable or target-specific state is introduced.


### Controlled Owned Threshold Diagnostics

OwnedLibertySource owns the canonical text for its retained threshold issue.
Its package-scoped withThresholdIssueDescription operation uses the existing
TimingCharacterizationError.errorDescription implementation, with a capacity plan
derived from the enum's literal punctuation, source String fields and the fixed
Swift 6.4 numeric-description contract in
[SourceTransforms](../SourceTransforms/DESIGN.md#controlled-diagnostic-failure).
It does not describe an unknown Error or depend on Optional/enum reflection.
The nil issue has the exact static text nil; a missing formatter for a present
issue is an invariant failure rather than a successful diagnostic substitute.

Before invoking that formatter, the operation admits description UTF-8 storage,
the fixed String value fields and any numeric-format intermediate capacities on
the supplied original accountant, then charges construction work and checks
cancellation. The callback borrows the description while those temporary leases
remain alive. Return or throw drops the description before refunding scratch;
work is cumulative. A caller publishing a copied combined diagnostic must admit
and retain that separate text through its own prepaid terminal failure boundary.
This seam changes no threshold validation, source facts, error case or parser
acceptance. DistributedRC's controlled failure selects this canonical text;
its legacy unaccounted branch retains its historical reflection description.
