# ParasiticReduction

## Purpose and Scope

Own the explicit equipotential cap-load approximation over admitted TimingParasitics
v2 source inventory. Parent: [TimingCore](../DESIGN.md). No children. No distributed
RC solver, extraction, logical binding inference or process qualification is owned.

## Responsibilities and Boundaries

TimingParasiticReducing publishes immutable TimingLumpedParasitics. The concrete
EquipotentialTimingParasiticReducer validates inventory, normalizes repeated cross-net
listings, derives loads and retains reduction evidence. Parsing owns exact endpoints,
network declarations and physical source identifiers; consumers own propagation and
analysis limits. D_NET declarations never become derived load values.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [TimingCore](../DESIGN.md) | parent | Source inventory v2 | Input authority | Unknown/conflicting owners remain failure |
| [STAEngine](../../STAEngine/DESIGN.md) | used by | Derived effectiveLoads and evidence | Cell LUT cap-load analysis | Not distributed RC delay |
| [SignalIntegrityEngine](../../SignalIntegrityEngine/DESIGN.md) | used by | Normalized coupling and evidence | Lumped noise/delta analysis | No invented missing victim R |

## Architecture

```text
Source CAP records + D_NET declarations
    -> inventory validation -> mirrored multiset normalization
    -> Ceff(net) = ground(net) + incident unique inter-net capacitance
    -> effectiveLoads + normalized coupling + explicit reduction evidence
    -> Native STA / SI payloads and diagnostics
```

## Contracts and Invariants

Source records retain enclosing net, local identifier, physical line, complete
expanded endpoint name, exact owner net and finite nonnegative farads. Ground CAP
belongs to its enclosing known net. A two-terminal CAP belongs to one of its exact
owners; an unscoped design-known external root may lack D_NET coverage.

For a capacitor C between distinct nodes, its matrix is C*b*b^T with b=e_a-e_b.
The declared equipotential net projection P gives P^T*b=0 for same-net endpoints,
so its reduced contribution is zero. Every such source record/value remains in
collapsedIntraNetCapacitances. This does not claim the finite-R dynamic response is
unchanged; distributed timing and intra-net dynamics are explicit lost semantics.
No internal capacitance is added to ground. Inter-net capacitance contributes once
to each incident net under an explicit stationary-other-net load assumption.

Complete unordered endpoint pairs group cross-net records. A one-sided listing
retains all parallel records. Listings from both owners collapse only when their
value multisets and multiplicities exactly match. Conflicting mirrored lists fail.
All source IDs remain in the normalized evidence; same-owner parallel operators
never disappear. No all-pairs endpoint search is used.

Declared inventory, local record totals and normalized incident operator totals are retained separately. Incoming-only listings are distinguished from declaration/incident disagreement.
Disagreement is a diagnostic observation, never an invented load. A positive D_NET
with no globally resolved incident CAP evidence is representable as source inventory but cannot be reduced. A receiving network may have no local CAP listing when another network lists its incident operator.
Derived load keys include bare external root endpoints without synthesizing network,
ground capacitance or resistance coverage. SI victim scopes are only explicitly
declared source networks; no missing external victim resistance is invented.

## Runtime Flows

Validate once, normalize source listings, derive finite grounded and incident sums,
then publish atomically with policy ID, assumptions, complete internal loss records,
mirrored groups and declaration comparisons. Consumers retain that evidence in the
same payload as numerical results and exact input artifact identities.

## State, Ownership, and Lifecycle

Call-local value collections only. Evidence sizes are bounded by admitted source
records and identifiers; no shared cache, pointer or target-conditioned state exists.

## Failure, Concurrency, and Constraints

Invalid source schema, ownership, local IDs, nonfinite/negative values or overflowing
aggregates fail before publication. Missing CAP records and ambiguous mirror listings
throw typed reduction errors wrapped in TimingError. Work is linear in source records
plus deterministic sorting; storage is linear in source bytes/records. Artifact read
budgets bound input bytes; no Cartesian allocation or recursive graph solver is used.

## Verification and Change Impact

[TimingParasiticReductionTests](../../../Tests/TimingEngineTests/TimingParasiticReductionTests.swift)
rejects grounded/internal corruption, missing partial incident loads, double-counted
mirrors, lost parallel records, ambiguous mirror admission, header-derived loads,
unknown owners, missing positive inventory and invalid numeric/schema values.
Native STA/SI tests prove actual LUT/noise consumption, loss diagnostics and payload
round-trip. Changes invalidate those consumers and canonical database preservation.
