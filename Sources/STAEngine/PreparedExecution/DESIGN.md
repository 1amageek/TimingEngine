# Prepared STA Execution

## Purpose and Scope

Status: implemented. Parent: [STAEngine](../DESIGN.md). No children.
Own immutable native STA preparation, effective configuration identity and exact
handoff to scenario execution. Preserve strict process/corner/source rules.

## Responsibilities and Boundaries

ProcessCorners owns manifest/source joins. TimingCore owns grammar, graph,
constraints and numerical values. This component composes actual outputs and
settings before analysis. PDK owns expectation/matching; host owns availability,
DB/ledger and qualification policy. NativeSTAEngine still conforms directly to
STAExecuting; no factory or compatibility envelope is introduced.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Module](../DESIGN.md) | parent | Native engine/report behavior | Same scenario algorithm | Immutable checked owner and v4 observations |
| [ProcessCorners](../ProcessCorners/DESIGN.md) | depends on | Exact per-corner library and selection | Strict join | No merged library or PVT interpolation |
| [LibertyCodec](../../TimingCore/LibertyCodec/DESIGN.md) | depends on | Owned real library/raw conditions | Shared grammar | Numeric process is not named-process proof |
| [Inspection](../../TimingPDKProfileInspection/DESIGN.md) | optional depends on | Retained inspected catalog | Parse once through analysis | No reverse TimingCore/PDKKit dependency |
| [Host](../../../../Xcircuite/Sources/Xcircuite/ProfileExecution/DESIGN.md) | used by | Actual prepared input/config observations | Compare before execution | Caller digest is only an expectation |

## Architecture

```text
exact readers/catalog -> process join + design/SDC/optional SPEF intake
 -> effective scenarios/characterization/config -> PreparedSTAExecution
 -> host PDK match -> same owner scenario analysis -> retained result
```

## Contracts and Invariants

Current facts: STATimingProcessInputs checks exact manifest/source joins and reuses
retained owned Liberty grammar or parses verified bytes through the same codec.
STARequest.configurationDigest is an optional expected identity. References:
[loader](../ProcessCorners/STATimingProcessInputs.swift), [request](../STARequest.swift),
[engine](../NativeSTAEngine.swift).

ST-01: Verify actual design, SDC, optional SPEF and manifest inputs. Profile mode
uses the exact inspected catalog; ordinary mode uses the same owned codec on
verified bytes. Retain complete input identity, parser/policy identities, actual
libraries and declared per-corner PVT. Corner libraries stay separate. Execute
never reopens input availability or replaces a prepared library.

ST-02: Effective config includes actual resolved modes/corners/scenarios, analysis
kinds, maxPaths, variation/derates, post-layout requirement, global input slew and
default-rule versions, characterization policy/bindings, algorithm/reduction
identities and any effective seed/semantic limit. Hash actual resolved values in
versioned domain-separated canonical framing. Caller configurationDigest becomes
an optional expected digest and must match, never supplying actual provenance.
Resolve empty requested modes against actual constraints first. Unknown or ignored
settings cannot claim application. Source identity is separate; run ID, timestamps,
availability and source-intake ceilings are excluded. Effective output/analysis
limits remain inside config identity. Preserve precedence and reject nonfinite/overflow.
The initial deterministic native lane does not consume randomSeed; a supplied seed
is typed unsupported rather than hashed and reported as effective. Only settings
actually used by the scenario algorithm may enter an applied-configuration record.

ST-03: STACharacterizationPolicy has `declaredCornerSelection` and
`requireObservedConditions`. The first proves exact declared source selection and
retains raw metadata without claiming a selected observed characterization group.
The second requires explicit condition-name bindings per corner, resolves each
against that exact library and compares observed voltage/temperature exactly with
the selected nominal values. Missing/duplicate/incomplete groups fail. Preserve
numeric process as unmapped metadata; an additional explicit numeric-value demand
requires actual equality, but neither case manufactures named-process evidence.
No first group or assumed default is selected. Unselected groups are not operating
points. STA has no solved circuit supply/temperature trace and must not publish one.
Neither case qualifies models or provides complete named-process sourcePVT coverage.

ST-04: PreparedSTAExecution is a Sendable internal-constructor, non-Codable owner
of real libraries/catalog, graph, resolved constraints, parasitic reduction,
scenarios, identities and observations. The same owner supplies analysis and output
claims. Mutable workspace is per execution, not shared with immutable libraries.

Protocols implemented directly by NativeSTAEngine:

```swift
public protocol STAExecutionPreparing: Sendable {
    func prepare(_ request: STARequest, resources: STAExecutionResources)
        async throws(STAPreparationError) -> PreparedSTAExecution
}
public protocol STAPreparedExecuting: Sendable {
    func execute(_ prepared: PreparedSTAExecution)
        async throws(STAExecutionError) -> STAExecutionResult
}
```

STAExecutionResources supplies verified readers, optional inspected catalog,
source/accounting policies and finite scenario/execution limits. It grants
availability, not semantic identity. Ordinary STAExecuting.execute(request)
delegates prepare/execute; profile callers use the explicit prepared boundary
to match before execution. Protocol implementations delegate checked owner
construction; no public unchecked prepared initializer is provided.

## Runtime Flows

Verify/intake -> strict process join -> resolve config -> final cancellation check
-> prepared owner -> caller profile match -> actual scenarios -> domain-valid
completed output -> exact report. Failure publishes no completed report.

## State, Ownership, and Lifecycle

Prepared storage is immutable; each run owns workspace, cancellation and report
capacity. Catalog/codec receipts live to last prepared/result copy. Raw library
extraction does not transfer managed lifetime. Stage accounting owns new non-PDK
inputs and scenario materialization, not a reopened admission counter. Reader
sessions await close. Concurrency never weakens storage/isolation by target.

## Failure, Concurrency, and Constraints

Typed failures preserve source/process/corner/resource/cancellation causes and
distinguish expected config mismatch, missing/unsupported characterization and
unsupported bounded transform. Liberty codec bounds cover Liberty only. Other
design/SDC/SPEF/graph/analysis transforms have explicit budgets or refuse before
an unbounded operation; they cannot inherit the codec's proof. Native macOS
evidence establishes no WASM/Embedded or process qualification.

## Verification and Change Impact

STAPreparedExecutionTests uses real distinct-corner delays. Prove effective
variation/mode/maxPaths/slew/policy identity changes, wrong caller digest, execution
after path mutation, raw numeric process/partial metadata, explicit group selection,
missing/wrong voltage/temperature, independent concurrent runs and budget/cancellation.
Reuse unchanged strict STAProcessCornerTests and codec evidence. Implement request/
result/report schema v4 with actual input/config and characterization records;
migrate CLI, corpus, external correlation readers and host together. Current schema is v4. Older schemas fail explicitly; external producers
can report only their actually implemented scope.

## Implemented Read Contract and Limits

`PreparedSTAExecution` exposes immutable request/input references, a domain-framed
`executionInputIdentity`, `effectiveConfiguration`/`configurationDigest`, exact
`processSelection`, raw/selected characterization, graph-selected `libraryConsumption`
and optional `inspectedSources`.
The latter retains the actual admitted contextual graph; source contexts are never
copied from a consumption expectation. Execution uses its retained libraries and
parsed inputs after source paths change. Each invocation allocates new scenario
workspace and never shares mutable algorithm state.

`STAExecutionLimits` independently caps input bytes before native transforms,
design elements, scenario fan-out and requested paths. `STALibertyResources` caps
actual grammar work/live+temporary payload bytes and checks one monotonic deadline.
These are distinct scope contracts: transform ceilings are not allocator/RSS
accounting and do not inherit the strict Liberty storage guarantee. Unavailable
strict transform accounting is explicitly refused when requested. Intake limits
are excluded from effective config; the requested semantic path output limit is
included. The native lane is deterministic and rejects a supplied randomSeed.

The effective config decoder recomputes the digest from the retained values and
rejects tampering. Default mode is resolved before hashing. Global input slew and
output load are taken from parsed constraints. Source IDs and materialization paths
are outside configuration identity. Report/result v4 contains the actual effective
configuration and raw/selected observations; external engines omit records outside
their implemented scope.

Behavioral owners:
[STAPreparedExecutionTests](../../../Tests/NativePreparedProof/Tests/STAPreparedExecutionTests)
and unchanged strict process-corner regression. Tests are ordinary SwiftPM targets;
[the independent proof package](../../../Tests/NativePreparedProof/Package.swift)
selects those same sources without compiling unrelated legacy test products.
