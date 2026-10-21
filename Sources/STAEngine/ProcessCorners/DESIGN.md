# Process Corners

## Purpose and Scope

Admit exact native STA process/corner inputs. Parent: [STAEngine](../DESIGN.md).
No children.

## Responsibilities and Boundaries

Decode and validate the verified manifest, match request identity, resolve explicit
corners to exact Liberty assets, and retain each parsed library separately.
PDKCore owns manifest semantics and TimingCore owns standard parsing. This component
does not characterize timing models or qualify a process.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [STAEngine](../DESIGN.md) | parent / used by | Request and asynchronous artifact reader | Native scenario intake | Failure precedes analysis/report publication |
| [PDKKit](../../../../PDKKit/DESIGN.md) | depends on | PDKManifest, corner PVT and Liberty view mapping | Process authority | Cross-view mapping and exact content are required |
| [Prepared execution](../PreparedExecution/DESIGN.md) | used by | Exact selected source/library join | Proposed config/characterization selection | Preserve strict declared corner equality |

## Architecture

```text
Verified manifest -> identity/semantic validation -> requested corner
    -> explicit Liberty view asset -> exact source digest/size -> parsed library
    -> per-corner library dictionary + retained STAProcessSelection
```

## Contracts and Invariants

- Requested corner IDs are explicit, nonempty and unique; no default is selected.
- Manifest process/version match the request. Manifest binding is input-role JSON
  with SHA-256 identity. Manifest semantic validation must pass.
- Each selected corner has finite positive voltage, finite temperature and a
  nonempty process name. Its Liberty view names an asset in `assetIDs`, and the
  asset and a Liberty cross-view mapping explicitly declare that corner.
- Each supplied library explicitly declares unique supported corners. Each
  requested corner has exactly one supplied library, whose verified SHA-256 and
  byte count match its selected manifest asset. Missing integrity is rejected.
- Sources remain separate by corner, including when cells share names. Analysis
  does not interpolate PVT or use another corner's models.
- Completed payloads retain process/version, exact manifest identity, selected
  PDK corner definitions and the corner-to-Liberty artifact identities. Retained
  PVT is a declaration bound to exact source bytes, not independent foundry proof.

## Runtime Flows

Verified read -> decode/validate -> match identity -> admit each source/mapping
-> parse once per source -> selected immutable libraries -> scenario analysis.

## State, Ownership, and Lifecycle

One invocation owns all values. Reader owns verified materialization. No mutable
shared state or target-specific storage is added.

## Failure, Concurrency, and Constraints

Typed TimingError values become blocked envelopes. Unknown corners, missing or
ambiguous mapping, malformed manifest, source mismatch and absent selection fail
before publication. Reads follow asynchronous reader contracts and cancellation
checks between sources. Limits are explicit source count and request scenarios.

## Verification and Change Impact

[STAProcessCornerTests](../../../Tests/TimingEngineTests/STAProcessCornerTests.swift)
uses the actual native API to distinguish corner delays and reject invalid inputs.
Parent owns CLI and retained report reconstruction. A mapping/selection change
requires parent scenario and caller regression verification.

### Proposed common-profile consumption handoff

The current native intake already proves the corner-to-Liberty/PVT guarantees
above; preserve them. The implemented
[PDK profile](../../../../PDKKit/Sources/PDKCore/Profile/DESIGN.md) supplies the
explicit stage subset and parent selection identity. Native intake returns its
actual STAProcessSelection plus exact source/section evidence for comparison by
[profile admission](../../../../PDKKit/Sources/PDKProfileAdmission/DESIGN.md).
Do not replace current source checks with a profile success flag. A requested
corner/library must match the profile projection as well as the manifest.
Manifest, selected libraries and operating-condition evidence remain in provenance;
unrelated optional profile sources need not be analyzed. Retained PVT remains
source-bound declaration evidence rather than independent foundry proof.

The prepared boundary owns declared-corner versus raw-characterization meaning.
This component exports validated declaration evidence; it must not fill raw process
or runtime conditions from the selected corner. Implementation consumes the retained
actually parsed library catalog rather than independently reparsing it.

STAProcessCornerTests adds wrong parent profile, wrong required subset, altered
PVT/library identity and extra contributing source refusal. Domain result/request
schemas advance only when new consumed-profile fields are implemented, and their
callers/retained readers migrate together without legacy fallback.

The prepared native path retains `OwnedLibertySource` per exact supplied source.
Profile mode consumes the checked retained catalog; ordinary mode verifies source
identity through the reader and owned codec. Execution retains distinct source
owners and never reopens source paths. [PreparedExecution](../PreparedExecution/DESIGN.md)
owns effective settings, explicit characterization policies and handoff lifetime.

## Strict Input Join

The strict lane reads the exact manifest through the controlled reader and uses
PDKDiscovery's audited raw-span decode/validation. The original artifact reference
remains request authority; the raw decoder's nil sourceReference grants none.
The complete manifest/report handle is retained by the selected process inputs,
including every copy, so selected corner subvalues never shed their leases.
Concrete corner/asset/reference/source tables are admitted before construction on
the same Native transform budget. Whitespace/digest comparisons borrow the actual
strings; no unaccounted trimming/lowercase result is synthesized. Liberty reads
retain their read anchor through actual byte comparison/parse, and the parser's
owned source thereafter owns the bytes. Failures preserve whole PDK controlled
failure anchors, including source-derived diagnostic strings. Legacy load is
unchanged. Actual strict join tests passed within the selected
[Native qualification](../PreparedExecution/DESIGN.md#strict-native-qualification-scope).
