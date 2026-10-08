# Timing PDK Profile Inspection

## Purpose and Scope

Status: proposed optional SwiftPM product/target, not implemented or added to the
manifest yet. Parent: [TimingEngine](../../DESIGN.md). No children. Own the adapter
between TimingCore's owned Liberty grammar and PDK profile inspection.

## Responsibilities and Boundaries

Depend on TimingCore, PDKCore, PDKProfileAdmission and the capture product actually
used. TimingCore does not depend on PDKKit; PDKKit does not depend on TimingEngine.
Putting this adapter in PDKKit would create a package cycle because TimingEngine
already consumes PDKKit. STAEngine may opt into this target during implementation;
the standalone Liberty codec remains independently buildable without it.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Optional domain integration | Native host adapter | New product and exact adoption required |
| [LibertyCodec](../TimingCore/LibertyCodec/DESIGN.md) | depends on | LibertySourceParsing, OwnedLibertySource | Real grammar/library/facts | Numeric process is not named PDK process |
| [Admission](../../../PDKKit/Sources/PDKProfileAdmission/Admission/DESIGN.md) | depends on | PDKProfileSourceInspecting and checked capture/context | Actual source facts | Inspector success is not admission authority |
| [STA preparation](../STAEngine/PreparedExecution/DESIGN.md) | used by | Retained actually inspected library catalog | Avoid duplicate parse | Keep owner/receipts, not bare library copies |

## Architecture

```text
checked capture -> scoped inspector session -> LibertySourceParsing
                        +-> actual PDK mapping/coverage facts -> admission
                        +-> retained OwnedLibertySource -> STA preparation
```

## Contracts and Invariants

The proposed concrete TimingPDKProfileInspectionSession conforms directly to the
existing PDKProfileSourceInspecting protocol. It translates a bounded capture
borrow into LibertySourceParsing with an adapter to the same invocation resource
owner. Actual cells/pins and raw condition facts come from that result. Leaf
coverage requires actual grammar proof. JSON/include/section remain typed unsupported.

Do not convert numeric process to tt/ss/ff or fill absent fields from expected PVT.
Raw partial metadata remains domain evidence. Complete named-process sourcePVT
demand cannot be satisfied by this initial adapter; refuse coverage explicitly.
Existing PDK fact/admission rules remain unchanged; STA owns characterization selection.

The session retains actual OwnedLibertySource values under exact full reference
and parser/policy identity, separate from corner bindings. Inspection and execution
use the same library owner. Sharing immutable grammar backing does not erase full
descriptors or contextual fact occurrences. There is no global cache or weak backing.

Proposed `retainedSources(for: AdmittedPDKProfile) async throws(TimingProfileInspectionError)
-> TimingInspectedLibertySources` validates the session's actual references/context
against the admitted source graph before exporting an internal-constructor immutable
catalog. It retains actual capture/library/accounting owners and supplies exact
lookup/borrow, not corner qualification or an admission token.

## Runtime Flows

Collecting -> parse/retain -> actual admission succeeds -> validate/export catalog
-> preparation retains catalog -> await session shutdown. Admission failure awaits
shutdown and publishes no catalog. Further inspection/export after shutdown fails;
exported immutable catalog copies remain valid. Ordinary STA uses the same codec directly.

## State, Ownership, and Lifecycle

An actor owns ordered async session state and entries. No accounting callback runs
under Mutex locks. Receipts survive to the final catalog/prepared copy. shutdown()
clears session references without revoking exported owners. Closed admission
counters are not reopened to reuse immutable library storage.
Track in-flight inspection across actor suspension. Export requires all structured
inspection children to have joined; shutdown closes admission, joins pending work
and prevents a resumed inspection from republishing cache state. Failure/cancellation
releases each in-flight owner before shutdown returns.

## Failure, Concurrency, and Constraints

Preserve codec/capture/resource/cancellation/profile causes; distinguish wrong
reference/context, conflicting entry, closed session and unsupported demanded facts.
Policies supply nesting/work/capacity ceilings. Translate metrics before operations;
do not materialize unaccounted Data/String or charge a parse only afterward.
Native host evidence does not establish other platforms or numerical quality.

## Verification and Change Impact

Proposed TimingPDKProfileInspectionTests depends on this target and real admission,
without STA/Xcircuite. Prove cells/pins, raw process/partial metadata, demanded coverage
refusal, exact lookup, one parse shared through execution, shutdown/last-copy
retention and budget/cancellation propagation. Reuse valid LibertyCodec proof.
Changes affect registration, STA preparation and fresh-replay inspector factories.
