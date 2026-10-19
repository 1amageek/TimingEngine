# TimingEngine module

## Purpose and Scope
Own timing service and corpus/correlation composition. Parent: [TimingEngine package](../../DESIGN.md). Child: [ScalarReference](ScalarReference/DESIGN.md).

## Responsibilities and Boundaries
Compose native engines and retained evidence/correlation protocols. STA algorithms,
canonical timing values and process admission belong to their respective modules.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Evidence ownership | Composition product | No approval authority |
| [ScalarReference](ScalarReference/DESIGN.md) | child | TimingReferenceAnalyzer | Ordinary correlation profile | Added connectivity refused |
| [STAEngine](../STAEngine/DESIGN.md) | depends on | STAExecuting | Native observations | Scope is not qualification |

## Architecture
```text
corpus inputs -> direct native engines + scalar reference -> raw comparison/evidence
```

## Contracts and Invariants
Retained observations are distinct from qualified process evidence. Scalar scope
never expands from the native backend's capabilities.

## Verification and Change Impact
TimingEngineTests corpus/native tests own composition. Added connectivity must
retain explicit refusal in consumers whose algorithm does not support it.

## External process consumption

LocalTimingExternalOracleRunner consumes caller-selected timeout, combined raw output
byte budget and cleanup budget from TimingExternalOracleRequest schema 3. No output
or cleanup limit is guessed by the adapter. TimedProcessRunner owns pipe drain and
child/group cleanup. Its typed TimedProcessError propagates unchanged, retaining the
first cause, exact Data and pending TimedProcessCleanupHandle. Callers own bounded
close/reconciliation of any returned pending handle. No unjoined monitor is created;
optional TimedProcessControl uses the lower synchronized API directly. Successful
process output is decoded only after the lower runner confirms clean termination.
CorpusTests and TimedOracleConsumerTests own actual success, timeout, cancellation,
output-cap and cleanup-handle consumption. Process evidence is not qualification.

Execution timeout, TERM grace, and post-KILL cleanup confirmation are separate
phases. The local runner retains the lower default TERM grace; caller cleanup
budget starts after KILL and terminal observation wins over an expired confirmation
budget. A tiny confirmation budget therefore does not require a pending handle.
TimedOracleConsumerTests conditionally closes actual Local failures and separately
passes the real lower zero-grace/productive-output failure through the existing
oracle protocol, preserving exact cause, bytes and handle identity. This separate
handoff proof is not a claim that the Local default-grace invocation produced pending cleanup.
