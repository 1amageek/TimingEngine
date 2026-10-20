# Initial Prescribed Source Families

## Purpose and Scope

Child of [ConservativeCoupling](../DESIGN.md), with no children. Own the versioned
initialRoots source-context projection, outward normalized value/slope queries,
and sealed joint initial/window projections of the same source family. Time uses the retained TimingCore SI seconds, including negative times.
The existing NativeSTAConservativeWires producer selects every source and its
owned characterization domain. This component adds no response solver or Core
integration.

## Responsibilities and Boundaries

The snapshot precedes solver preparation, source-response refinement and derived
clock/Q histories. It includes every preserved boundary source, explicitly tagged
primaryPort or prescribedCellOutput. A cell entry is an assumed NLDM boundary,
not an independent physical source. Primary clocks retain every integer cycle;
other histories remain unrestricted. No finite past or initial plateau is added.

## Related Designs

| Design | Relationship | Contract Used | Caution |
|---|---|---|---|
| [ConservativeCoupling](../DESIGN.md) | parent | Full-rail history and slope authority | No root or physical drive guarantee |
| [PathAnalysis](../../PathAnalysis/DESIGN.md) | producer | Shared source/constants/load selection | No duplicate source-builder decisions |
| [PreparedExecution](../../../PreparedExecution/DESIGN.md) | depends on | Exact retained inputs, configuration and resource owner | No source rereads |
| [NumericBounds](../../../../TimingCore/NumericBounds/DESIGN.md) | depends on | Finite outward arithmetic | Overflow refuses |

## Architecture

```text
retained prepared scenario -> shared constants/load/source producer
    -> initialRoots record (before any response)
    -> immutable checked context + same operation resource owner
    -> normalized slab values and both one-sided slope enclosures
serialized record -> exact prepared reconstruction/comparison -> checked context
```

## Contracts and Invariants

A record binds version, stage, mode/corner, input/configuration digests, thresholds,
source ordering, source/load/arc identities, explicit history and generation zero.
Missing history never defaults to unrestricted. Decoding checks structure only;
it cannot construct a checked context. Prepared replay must reproduce every field.
Existing delay payloads and algorithm identities are unchanged.

Dynamic unrestricted values lie in [0,1]; derivative bounds are the outward hull
of zero, positive rise span/slew and negative fall span/slew. Both one-sided
limits at a corner are included. This safely enlarges the original ramp family
to bounded absolutely continuous inputs without granting finite crossings,
non-Zeno behavior, a unique history, or an infinite-past physical tube. Known
primary clocks retain their exact root-relative references and all integer cycles.
Queries intersect every relevant rise/fall/plateau window using the existing
Clock.ramps authority. A whole-period query can use the global hull. Integer-cycle
or interval overflow refuses rather than clamping or choosing a phase.

## State, Ownership, and Lifecycle

Each operation uses the prepared limits, source accountant and cancellation plus
one existing NativeSTAStateBudget across all scenarios. Checked contexts share
one cumulative Mutex-protected work owner initialized with all builder work;
copies cannot reset it. Source callbacks run outside the lock. Checked arithmetic
and logical/storage admission precede output growth; retained context leases last
to the final copy. Producer record copies retain their logical-payload lease even after the checked context drops. Raw decoded records are caller-owned values and have no jet API.
There is no target-specific isolation, unsafe pointer, global cache or new quota.

## Failure, Concurrency, and Constraints

Unsupported preparation, malformed source/history/threshold bindings, duplicate
sources, nonfinite domains and unrepresentable cycles fail explicitly. Existing
capacity, source, cancellation and deadline failures propagate. An operation
publishes all selected scenario contexts or none. Core must separately bind the
physical rails/time and actual qualified voltage-source parametric law.

## Verification and Change Impact

STAInitialSourceContextTests owns before-response availability despite a failing
response, ordinary producer domain parity, exact prepared replay, strict codec
and missing-history refusals, negative-time periodicity, corner/interval/constant
jets, internal-source origin, cumulative work/cancellation, preallocation refusal
and final-copy refunds. Existing conservative source-load/history/integration and
replay tests cover the mechanically shared producer's normal execution behavior.

| Shared state | Native / WASM / Embedded storage | Read/mutation | Release |
|---|---|---|---|
| Context work | One common Mutex<UInt64> | finishBuilder before publication; checkpoint under the same lock | Last checked context/control copy |
| Logical construction count | Existing NativeSTAStateBudget / Mutex<Int> | Existing reserve only | Same operation control |

No conditional storage/conformance or unchecked Sendable path is introduced.
Native behavioral tests do not establish new WASM/Embedded execution evidence.
The package-only TimingCharacterizationThresholds initializer is exposed within
this package for the standalone record decoder; no new public unchecked threshold
constructor or old payload decoder behavior is added.

## Joint Initial/Window Projection

`STAConservativeSourceContext.jointSlice(sourceAt:initialTime:over:)` is the
only public producer of `STAConservativeSourceJointSlice`. The immutable,
non-Codable result has a private initializer and retains the actual checked
context and one admitted storage reservation. Its read-only fields are
`contextRecord`, `sourceIndex`, `initialTimeSI`, `windowSI`, `initialValue`,
`windowValue`, and `almostEverywhereSlope`. A decoded record, caller function,
independent jet or caller-supplied bound cannot construct a slice.

```text
same checked context / source / retained family
    + initial-time hull contained in time window (SI seconds)
    -> one preadmitted projection owner
    -> existing kernel at initial hull and whole window
    -> initial value / whole-window value / a.e. derivative outer bounds
```

Every admitted function of the original family is covered: for every initial
instant in `initialTimeSI`, its value is in `initialValue`; over `windowSI`, its
values are in `windowValue` and its derivative is in `almostEverywhereSlope`
almost everywhere. These are projections of one retained family, not a claim
that every tuple in their Cartesian product is realizable. The unrestricted
family remains all bounded absolutely continuous functions with values in
[0,1] and derivative in the retained rise/fall slope bounds, including zero.
It is not narrowed to a finite parameterization, finite ramps or an initial
plateau. Existence of one-sided derivatives is not required or promised.

Constants are nonempty by their constant member. Unrestricted families contain
constant members. For clocks, the checked record already requires finite,
positive slew/period and strictly separated outward rise/fall/next-rise windows.
Thus a permitted ramp/plateau member exists over every integer cycle. Selecting
one such member establishes nonemptiness only; the family and bounds still
cover every per-edge/per-cycle reference and slew choice admitted by the existing
history contract. Negative cycles are never clamped or replaced by a finite past.
The existing clock arithmetic and cycle/overflow refusals remain unchanged.

`initialTimeSI` and `windowSI` are finite Double hulls with the former contained
in the latter. Their original endpoints are retained without rounding or time
translation. An upper consumer with compensated times must prove that its exact
initial and terminal times are contained in these hulls; Timing neither truncates
those values nor acquires a CoreSpice dependency. Positive flow duration,
physical rails, actual voltage-law/source correspondence and common analysis
identity remain upper obligations. Source origin is preserved, so an assumed
prescribed cell output acquires no independent physical-source authority.

Before result admission the factory checks index and time containment using the
existing cumulative control. Checked addition admits the result value and
reservation metadata plus one existing state-budget slot before either kernel
query. The two synchronous queries use the same private arithmetic kernel and
same control. There are no intermediate arrays, caller callbacks, new limits or
budget resets. Work and cancellation are checked before publication. Failure
releases the temporary result lease; copies retain the context and reservation
until the final copy dies. The existing Mutex work owner, source accountant and
state budget remain shared on every target; all new stored state is immutable.

Focused `STAConservativeSourceJointSliceTests` must distinguish real prepared
context production, constant/all-AC preservation, periodic negative cycles,
phase/slew intervals, corners and whole periods, retained time hulls, invalid
index/time containment, storage refusal, mid-query cancellation, shared work
and final-copy refunds. `STAInitialSourceContextTests` remains the affected
existing owner regression. Qualification: all 15 selected declarations (eight new, seven existing) passed
with zero skips in two suites (0.169 seconds body time). `qualification-r1.json`
binds the exact source, build and runtime evidence; `joint-slice-review-r1.json`
(`fe02b63b6a45ab1edfdea5ddc6899b2ad153864f741ab7cfbdea1e600a88af9f`)
records the one scoped review closed with no findings. The final document-only
closure retains that finite behavioral scope.
