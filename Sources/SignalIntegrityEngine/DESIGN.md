# SignalIntegrityEngine

## Purpose and Scope
Own native lumped signal-integrity observations. Parent: [TimingEngine](../../DESIGN.md). No children.

## Responsibilities and Boundaries
Consume explicit TimingCore cap-load reduction and retain numerical observations,
input identities, approximation evidence and diagnostics. No distributed waveform
solver, extraction, process qualification or flow approval is owned.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [TimingCore reduction](../TimingCore/ParasiticReduction/DESIGN.md) | depends on | Normalized inter-net C and evidence | Cap-load approximation | Internal C is retained as lost dynamic semantics |
| [TimingEngine](../../DESIGN.md) | parent | Typed result/evidence | Host composition | Completion is not qualification |

## Architecture
```text
Exact SPEF -> source inventory -> explicit reduction -> declared victim R/Cg
    -> noise/delta observations + retained reduction evidence/diagnostics
```

## Contracts and Invariants
Only normalized inter-net physical capacitance contributes to lumped noise and
0.69*R*C delta estimates. Same-net C never becomes grounded or inter-net noise.
Victim scopes remain explicit source-declaring networks, and missing victim R fails.
Evidence retains internal loss, mirror IDs and header comparisons. Source identities
are unchanged. Producer algorithm identity is 2.0.0 and request/result schema v3
rejects old result bytes; no new production qualification is claimed.

## State, Ownership, and Lifecycle
Invocation-local immutable inputs and value collections; no shared mutable state.

## Failure, Concurrency, and Constraints
Typed parsing/reduction/coverage/numeric failures become blocked inputs. Every
numeric ratio/delta/aggregate must remain finite. Records and evidence are bounded
by admitted source bytes/records; no distributed RC solver or Cartesian work occurs.

## Verification and Change Impact
TimingParasiticReductionTests owns raw inventory and reducer invariants. Native
consumer tests own actual noise values, approximation diagnostics and payload
round-trip. Source/schema changes require STA/SI and database composition checks.
