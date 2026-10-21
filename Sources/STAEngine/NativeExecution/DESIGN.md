# NativeExecution

## Purpose and Scope
Own native STA composition and scenario analysis. Parent: [STAEngine](../DESIGN.md). Children: [PathAnalysis](PathAnalysis/DESIGN.md), [DistributedRC](DistributedRC/DESIGN.md), [ClockPropagation](ClockPropagation/DESIGN.md), [PulsePropagation](PulsePropagation/DESIGN.md).

## Responsibilities and Boundaries
Consume exact prepared inputs, propagate timing by physical net, retain endpoint
observations, and publish raw reports. No circuit functional proof or release approval.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [STAEngine](../DESIGN.md) | parent | STAExecuting | Native backend | Not qualification |
| [CanonicalModel](../../TimingCore/CanonicalModel/DESIGN.md) | depends on | Port/net bindings and constants | Validated physical connectivity | Constants never seed transitions |
| [PreparedExecution](../PreparedExecution/DESIGN.md) | coordinates with | Exact source/configuration owner | Retained preparation | No source rereads during analysis |

## Architecture
```text
prepared design/library/constraints -> physical-net topology -> arrivals
  -> per-port constrained endpoints + static checks + unconstrained endpoints
  -> retained STAPayload -> report
```

## Contracts and Invariants
Native producer 3.4.0 retains request/result schema v4 with additive endpoint facts.
Each output alias uses its own delay/required time while sharing physical arrival
and load. Input and clock source port identities resolve through explicit net bindings.
Binary constant nets are topology sources with no arrival/slew/transition. Direct
constant output and sequential data endpoints retain `staticValue` and `staticChecks`;
setup/hold slacks remain nil and no fabricated critical path is generated. Dynamic
pins still propagate their library arcs; constant pins never seed a timing arc.
Unsupported conditional pruning is still explicitly refused. Exact-route exception
semantics and workspace bounds belong to [PathAnalysis](PathAnalysis/DESIGN.md).
Every output endpoint is classified: a missing constraint is retained separately,
and a constrained dynamic endpoint without arrival fails. All-static constrained
analysis completes with nil aggregate slack and checked static evidence. Empty,
unconstrained or unsupported analysis cannot claim a static pass. Static data does not suppress the existing independent recovery/removal/pulse-width
checks; missing control constraints still fail.

## State, Ownership, and Lifecycle
Scenario dictionaries and path reconstruction are run-local. Prepared data is
immutable. The request-owned logical state counter uses a common Mutex; no target-dependent isolation or unsafe access is introduced.

## Failure, Concurrency, and Constraints
Driver/clock ambiguity, unsupported control analysis, missing dynamic propagation,
and empty constrained coverage fail explicitly. Native transform ceilings retain
their existing scope; no strict allocation-accounting claim is added.

## Verification and Change Impact
[STAConnectivityTests](../../../Tests/TimingEngineTests/STAConnectivityTests.swift)
checks alias constraints, static/mixed endpoints, connected constants, failure and
payload reconstruction. Runtime owns required-slack admission and source-to-real-cell
proof/save/reload; it may admit nil slack only with complete relevant static checks.

Physical zero-input literal TIE coverage belongs to [PathAnalysis](PathAnalysis/DESIGN.md).
Selected owned Liberty facts remain alive through analysis; no mapped instance, pin
or TimingDesign constant-driver mutation occurs.

Child [DistributedRC](DistributedRC/DESIGN.md) owns opt-in prescribed-ramp passive RC propagation. Native 3.5 retains distinct cap-load and distributed evidence; prepared source inventory and actual sink arrival/slew flow into PathAnalysis.

Child [ClockPropagation](ClockPropagation/DESIGN.md) owns explicit propagated primary buffer/inverter clocks, receiver-specific sequential timing and common physical segment semantics. Native3.6/configurationv6 binds the new actual clock source facts.

Clock characterization is injected through the public LibertySourceCharacterizationParsing protocol, independently of ordinary source intake. Its immutable admitted owner is retained per exact corner; it grants checked table evaluation rather than source/artifact qualification.

NativeSTAStateBudget is a request-owned logical construction-slot admission owner.
In distributed mode a single Mutex-protected counter is shared across scenario clock paths, RC matrix
workspace/cache/observations and data route records. Checked addition and admission
precede variable collection growth. Slots are cumulative conservative construction
charges, including released scenario workspace; they are not measured RSS or a
whole-transform byte guarantee. The latter remains explicitly unsupported. Nil-distributed execution retains its previous route/static capacity admission and diagnostics.

| State | Native / WASM / Embedded storage | Access | Release / scope |
|---|---|---|---|
| Cumulative logical state count | Same Mutex<Int> in common source; no target branch | Short synchronous reserve/check; no I/O/callback/await under lock | Request owner drops after execution; native macOS proof only |


## Certified Coupled Boundary Model

[ConservativeCoupling](ConservativeCoupling/DESIGN.md) is a child and owns exact
full-C operators and verified crossing certificates. Native composition joins
its source domains and results to exact input/configuration identities. The
model is normalized bounded-operating prescribed voltage history under the
retained NLDM load abstraction. It does not qualify that load approximation,
physical current drive, CCS or foundry behavior. No quiet, simultaneous, same-phase,
Miller or grounded-C substitution is made in the actual RC operator.

[PathAnalysis](PathAnalysis/DESIGN.md) owns interval composition/check semantics;
[PreparedExecution](../PreparedExecution/DESIGN.md) owns mode/configuration identity.
`conservativeWireObservations` retain source-authority domains, prescribed loads,
actual query and certificate bounds separately from observed-grid evidence.
Prepared replay compares exact receipts, queries, coverage and results. Required
scope remains caller-owned. Failed numerical certification yields a blocked typed
inconclusive diagnostic and no completed certificate/report.

## Strict Native Transform Payloads

The optional `PreparedSTAExecution.transformResources` is the SAME caller ledger
admitted by strict intake. A nil value keeps the existing legacy transform policy.
Native graph, scenario and output construction use `NativeSTAStateBudget` for two
separate contracts: `reserve(_:)` still counts cumulative logical state slots;
`reservePayload(_:capacity:kind:)` admits the checked concrete element stride and
capacity before a managed buffer is created or grown. It does not spend logical
slots. Owners separately admit collection headers/keys and retain returned leases
for their actual buffer lifetimes. Old and new buffers coexist during growth and
must both remain admitted until the copy ends. No maximum-stride inventory or
source-byte multiplier substitutes for typed payload admission.

`chargeScheduledWork(_:)` spends actual scheduled work on the original cumulative
caller ledger with cancellation checks before and after the callback. Neither
callback runs under the logical-slot mutex. Work is never refunded or reset at a
scenario boundary. Temporary graph/scenario reservations end after their last use;
immutable prepared/result copies share the reservations for their retained output
payloads until the last copy is released. This is logical managed payload, not
allocator buckets, opaque Foundation workspace or process RSS. The intake guard
remains closed until all composed strict paths and focused owner tests qualify.

The result-retention seam is component-local: scenario outputs transfer their
immutable transform anchors to the existing payload and execution result. The
carrier changes neither semantic Hashable/Equatable nor encoded bytes. Scratch
storage is not published as result storage. Callers extracting bare tables must
retain the whole controlled result for the table's claimed admission lifetime.

Controlled saved-result decoding uses the existing public PDK admission context
carried by the actual Decoder, reversed into the same Liberty accountant. The
custom payload/result initializers admit their own derived validation collections;
raw field decoding remains with the bounded decoder owner. Generic JSONDecoder
without that context preserves legacy semantics and supplies no controlled claim.
The evidence-regeneration call requires its lower canonical/hash allocation
contract in addition to field decoding. These owner contracts are composed in
the selected [Native qualification](../PreparedExecution/DESIGN.md#strict-native-qualification-scope).

Result evidence regeneration uses the dependency-owned public canonicalization
cost and SHA256 managed-cost contracts. The estimator callback spends planning
work immediately; returned factory work and SHA work are charged once before the
factory. Temporary admission sums canonical temporary, SHA temporary and SHA
retained bytes, because the digest is consumed inside the factory. Canonical
retained bytes are zero for this qualified profile; input owners remain retained
by the actual result. Native duplicates no private canonical encoding or hash.
