# Propagated Primary Clocks

## Purpose and Scope

Parent: [NativeExecution](../DESIGN.md). No children. Own exact primary-clock
buffer/inverter tree propagation and receiver-specific sequential timing consumers.
The nil-distributed lane retains its existing explicitly ideal-clock behavior.

## Responsibilities and Boundaries

TimingCore owns explicit SDC clock sources: waveform, per-edge transition,
uncertainty and propagated selection. This component resolves exact clock topology,
consumes characterized selected-corner cell arcs and DistributedRC receiver response,
and supplies FF clock-to-Q, setup/hold, recovery/removal and pulse-width checks.
Compiled source plans supply the exact FF/latch receiver pin and edge roles,
including every connected sequential output. Conditional normal-power facts are
validated by PathAnalysis before this traversal; names and nominal voltage grant
no operating assumption. Strict buffer evaluations record every actual checked
delay/slew query in the PathAnalysis receipt arena, using its shared work/state
admission and retained source deadline.
No generated clock, gating/multiinput logic, dynamic latency command, CCS, process
qualification or guessed transition is provided. Those profiles fail explicitly.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [NativeExecution](../DESIGN.md) | parent | Exact scenario/report | Clock/data composition | No partial report |
| [PathAnalysis](../PathAnalysis/DESIGN.md) | used by | Launch/capture/check timing | Actual receiver clock edges | Root edge/polarity retained |
| [DistributedRC](../DistributedRC/DESIGN.md) | depends on | Exact bounded periodic RC response | Same G/C and cumulative budgets as data | Numerical agreement is observed, not certified error |
| [PathConstraints](../../../TimingCore/PathConstraints/DESIGN.md) | depends on | Explicit primary waveform/transitions/propagation | Source authority | Legacy defaults cannot become propagated evidence |
| [LibertyCodec](../../../TimingCore/LibertyCodec/DESIGN.md) | depends on | Characterized arcs, thresholds and normalized functions | Buffer/inverter/FF source meaning | Missing or contradictory facts refuse |

## Architecture

```text
explicit primary source waveform + rise/fall transition + propagated declaration
 -> reverse trace actual FF clock pins to one root through exact buffer/inverter cells
 -> forward per-edge characterized cell delay/slew + periodic nodal RC response
 -> exact root edge, physical segments, FF receiver arrival/slew
 -> clock-to-Q + setup/hold/control/pulse-width + common-segment correction
 -> per-corner clock observations and required physical net coverage
```

## Contracts and Invariants

Each propagated primary clock is driven by an explicit input port and requires an explicit two-edge waveform with
0 <= rise < fall < period and finite positive source rise/fall transitions.
set_propagated_clock selects it explicitly. No global data default substitutes a
clock source fact. set_clock_latency and generated-clock propagation remain typed
unsupported. Ideal-clock declarations do not cover finite-R clock networks.

A clock cone contains exactly one driver per net and only characterized one-input,
one-output buffer/inverter cells. Owned normalized Boolean functions must agree
with the selected unate arc. Clock FF control is an actual one-symbol rising/falling
edge with a matching explicit clock-to-Q timing edge. Latches use the compiled
unary gate and opening edge; actual gate/data transfers remain owned by
SequentialExecution. Additional clock controls, ambiguous/missing arcs, loops
and clock-as-data fanout refuse.
Every propagated clock wire has exact admitted SPEF R/C and source/receiver CONN;
uncovered wires cannot become ideal-clock coverage. Each requested exact corner
uses its own immutable owned Liberty cells, thresholds and pin capacitances.

Clock wires consume prescribed periodic linear voltage ramps with the actual
source rise/fall phases and slew. Ramp overlap, missing crossings or insufficient
horizon refuses. The same backward-Euler G/C operator is integrated across complete
periods until two consecutive cycles agree in measured rise/fall arrival and slew
within the caller crossing tolerance. Grid halving must independently agree too.
stopTime bounds the whole warmup per grid; maximumSteps/path work bound the whole
request across warmup, refinement, clock/data and all scenarios. No full-settling
initial state or independent isolated-clock-edge assumption is fabricated.

At an FF, launch clock arrival/slew feeds actual clock-to-Q LUTs. Setup uses the
next receiver clock edge's early arrival/slew against late data; hold uses the
current receiver edge's late arrival/slew against early data. Source edge/polarity
and explicit phase stay attached across inversions and cycles. Recovery/removal
use those same exact related edges and slew. Pulse width uses observed receiving
rise/fall times and uncertainty. Cell/wire derates retain distinct meanings.

Common-path correction compares identical retained physical timed segment IDs,
root clock identity and root source edge. For setup it restores common late-minus-
early contribution; for hold it removes the corresponding capture-late/launch-early
contribution from required time. Exact same leaf paths cancel their common timing
under the static selected derates. Logical net names do not imply correlation.
Different receiver transfer functions inside one distributed mesh are not decomposed
into invented common delay; their independent bounds retain residual pessimism.
No statistical correlation or generalized generated-clock phase model is claimed.

## State, Ownership, and Lifecycle

One scenario owns clock cone/value caches and physical segment paths. Source and
library owners remain immutable through execution. The shared logical-state counter is owned by parent NativeExecution; no pointer or
target-dependent isolation is added. Temporary path/state/work admission precedes
publication; a clock failure discards the scenario and publishes no report.

## Failure, Concurrency, and Constraints

Clock state admission uses existing path-state limits; topology/function/cell and
numerical work share the cumulative path-work limit. Periodic RC shares cumulative
maximumSteps with data propagation. Cancellation is checked during tracing, functions,
cell evaluation and every transient step. Missing source facts and unsupported
profiles are typed failures and cannot silently select ideal propagation.

## Verification and Change Impact

STAPropagatedClockTests owns explicit SDC admission, periodic analytical RC,
characterized buffered/inverted trees at exact corners, FF launch/capture slew and
phase, common physical path correction, control checks and rejected horizons,
missing/unsupported/loop/budget/cancel/stale evidence. Actual CLI/API/save/reload
uses one exact design/SPEF/Liberty candidate and externally required clock net
coverage. Parent host integration owns adoption and real physical required scope;
this native profile alone does not complete system GP3 or qualify a process.

Explicit max/min-delay overrides on propagated launch/capture paths remain unsupported until their clock-latency reference contract is defined. Existing multicycle setup/hold period shifts retain exact root edge/polarity and static common-segment correction; the nil-distributed profile preserves its prior max/min behavior. Pulse-width retains the existing high-pulse scalar constraint scope and measures the actual receiver high width; no new low-pulse/table constraint semantics are inferred.

The effective configuration binds the exact candidate-derived mode/corner/root/FF
receiver inventory. Reconstruction and the host coverage gate require exactly both
observed edges for every retained receiver; removing a complete receiver cannot be
made complete by rehashing a result. Artifact identity remains externally checked.
Capture cycles are selected by source root phases: setup/recovery use the next
nominal root edge, hold/removal the previous nominal root edge. Derived latency
never chooses a different nominal cycle. Equal source phases use the next setup
cycle and current hold cycle; opposite edges retain their actual half-cycle relation.

The prepared owner retains the original source accountant. Cooperative checks
continue during clock/data work and numerical steps so caller deadline and external
cancellation remain cumulative across preparation and execution. Native path work
and RC step budgets remain their explicitly configured separate resource measures;
no source-accountant work counter is reset.


## Certified Coupled Boundary Model

Certified mode uses the [PathAnalysis](../PathAnalysis/DESIGN.md) independent
arrival/slew interval contract for every physical wire and buffer/inverter LUT.
[ConservativeCoupling](../ConservativeCoupling/DESIGN.md) retains active clock
sources in the full coupled operator. Periodic source ramps must have proved
nonoverlapping full-rail histories. FF launch/capture use actual receiving bounds;
no favorable shared-path correlation is assumed. Exact receiver scope and replay
remain mandatory for this distinct model.


### Certified Source-History Publication

The lower history mathematics and internal value contract are owned by
[ConservativeCoupling](../ConservativeCoupling/DESIGN.md#staged-source-history-certificates).
This component owns their existing clock/BUF authority and stage order. It collects
all buffer/inverter cones before querying FF leaves. Each frontier's inputs are
proved using the previous complete source box/history, then the existing exact
function/unate-arc, normal-power and selected Liberty range evaluation produces
owned source waves. Publish the complete frontier only after these checks; its proved per-edge wave
slews restrict the old source ranges through the lower atomic publication contract.
Do not
use same-frontier publications to prove their own prerequisites. Retain primary
root identity/period/edge/phase, exact driver/receiver/arc/load and original checked
range receipts. The source waves are envelopes for every cycle and every admitted
root phase, not one observed phase or an invented periodic steady state.

Only after all BUF source waves are available does the existing FF-leaf pass run.
Both receiving CLK directions must complete their original unique-event contract.
An unproved leaf cannot supply a sequential history restriction. Wire preparation
receives only these internally owned facts and advances its cache generation; no
new external history input or duplicate Boolean evaluator is introduced. The nil-
distributed/observed modes retain their existing behavior. Verification covers
shared/inverted cones, frontier ordering, wrong-root and whole-band fallback,
unknown histories, cumulative limits and exact fresh replay.


## Strict Transform Payload Ownership

Optional transform accounting is borrowed from the original scenario state
budget. Exact clock topology collections and per-event segment arrays are
admitted by their concrete element types before filling or concatenating. Local
cone/frontier scratch ends at its lexical operation; escaping wave/observation
owners retain their reservations across copies. Text concatenations admit their
actual source UTF-8 lengths before allocation. The same accountant receives
scheduled work and pre/post callback cancellation checks, without a new budget.

Nil-accountant propagation, edge identity, polarity, phase, interval arithmetic
and guards remain unchanged. New `NativeStrictNumerical` tests cover actual
propagated clock construction and refusal/refund boundaries. Qualification waits
for the stable combined source and runtime; no source-family scope is extended.

Preparation occurs before a Native logical-state owner exists. Its trailing
`transformResources` is the original intake accountant, not a new budget.
`NativeSTAClockCharacterization` retains its exact sorted inventories and receiver
UTF-8 names across copies; lexical cone/set/sort buffers return on exit. Runtime
uses the existing state budget. Each event owns its typed segment array and a
separate immutable text lineage; copying a path preserves shared text admission
without retaining dead predecessor array reservations. `finishTransformRetention`
seals the final map/observation carrier after all queries. PulsePropagation uses
the same segment construction contract. Source pin and arc scans use stored
collections or bounded admitted filters rather than unadmitted computed arrays.
The direct accountant uses the same check/work/cancel ordering without inventing
a preparation logical-state ceiling.
