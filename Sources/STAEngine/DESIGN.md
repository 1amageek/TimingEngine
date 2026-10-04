# STAEngine

## Purpose and Scope

Own native static timing analysis. Parent: [TimingEngine](../../DESIGN.md).
Child: [ProcessCorners](ProcessCorners/DESIGN.md).

## Responsibilities and Boundaries

Own request admission, scenario analysis and raw report persistence. PDKCore owns
manifest semantics; TimingCore owns Liberty parsing and canonical timing values.
ProcessCorners owns exact process and corner source admission. Qualification,
flow approval, extraction and physical mutation remain outside this module.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Raw observations and trust ownership | Native analysis | Completion is not process qualification |
| [ProcessCorners](ProcessCorners/DESIGN.md) | child | Validated per-corner library and selection | Scenario input admission | Never merge libraries across corners |
| [PDKKit](../../../PDKKit/DESIGN.md) | depends on | Manifest validation and exact corner mappings | Process authority | PDK identity must match the request |

## Architecture

```text
NativeSTAEngine -> ProcessCorners -> per-corner TimingLibrary
    -> canonical validation -> mode/corner analysis -> retained STAPayload
TimingCLI / corpus runner -> same STAExecuting path
```

## Contracts and Invariants

Each requested corner has one exact manifest-mapped Liberty input. Every scenario
and canonical validation uses that corner's library. The payload retains the
validated selection, and the persisted report round-trips that same value.
Rejected inputs publish no report. Detailed intake rules belong to ProcessCorners.

## Runtime Flows

Verified manifest/source reads precede canonical validation and analysis. Only
completed analysis reaches the optional artifact store. The CLI requires explicit
`--corner`, `--process` and `--pdk-version`; it does not invent identities.

## State, Ownership, and Lifecycle

Libraries and selection are immutable invocation-local values. No shared state,
cache, pointer or target-dependent isolation is introduced.

## Failure, Concurrency, and Constraints

Manifest parsing, identity, integrity, corner and mapping failures become structured
blocked results. Work is bounded by supplied source count and selected scenarios.
This macOS Foundation package does not claim WASM/Embedded verification.

## Verification and Change Impact

[STAProcessCornerTests](../../Tests/TimingEngineTests/STAProcessCornerTests.swift)
owns process/corner rejection, distinct per-corner numerical behavior and retained
selection. [TimingCLIProcessTests](../../Tests/TimingEngineTests/TimingCLIProcessTests.swift)
owns executable success/failure and persisted report reconstruction. Native STA,
execution-contract and corpus tests verify composing callers. Native analysis,
CLI selection and corpus binding changes require these checks with a timeout.
CLI process tests locate the executable relative to their own resource bundle,
so verification does not depend on another test loading a bundle first.
