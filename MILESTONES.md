# TimingEngine Release Milestones

This document defines the release path for TimingEngine. A milestone is complete only when its implementation, retained evidence, and reproducible verification are present.

## North-star release contract

```mermaid
flowchart LR
    Canonical["Canonical timing state"] --> Parse["Standard parsers"]
    Parse --> Analyze["MMMC STA / SI"]
    Analyze --> Evidence["Retained corpus + diagnostics"]
    Evidence --> Correlate["Independent oracle correlation"]
    Correlate --> Qualify["PDK/process qualification"]
    Qualify --> Headless["Xcircuite headless flow"]
    Headless --> Review["Human review / resume artifacts"]
    Review --> Release["Release gate"]
```

## Milestone matrix

| ID | Scope | Exit criteria | Status |
|---|---|---|---|
| M0 | Scope and acceptance contract | Public responsibilities, non-goals, and release gates are written and testable | Complete |
| M1 | Canonical timing semantics | Standard input/output identities, CircuiteFoundation artifact/evidence contracts, provenance digests, path groups, clock groups, power metadata, backward-compatible payload decoding, and typed unsupported semantics are covered by tests | Complete |
| M2 | Retained corpus | Positive, negative, blocked, and SI cases are versioned with a manifest and deterministic CLI/test replay artifacts | Complete |
| M3 | Independent oracle correlation | Scalar reference and external-process adapters compare identical payloads with explicit slack, mode, corner and provenance tolerances | Complete for Sky130A/OpenSTA 3.1; 1 ps tolerance is retained in the evidence |
| M4 | Process qualification | PDK manifest validity, required asset digests, corner/mode matrix, corpus pass rate and oracle evidence produce a retained qualification decision | Complete for the checked-in Sky130A TT profile; not foundry signoff equivalence |
| M5 | Xcircuite headless integration | Timing STA and SI stages execute through typed flow inputs, persist artifacts, expose review gates, and support resume/replay | Complete for the TimingEngine Foundation contract; external package adapter migration is separate |
| M6 | Release gate | Package builds, focused tests, CLI replay, corpus replay, qualification decision, and integration evidence all pass | Scoped Sky130A profile passed; broader signoff profile remains open |

## Gate policy

The following states are intentionally distinct:

```mermaid
stateDiagram-v2
    [*] --> Implemented
    Implemented --> Correlated: retained reference agrees
    Correlated --> Qualified: process evidence complete
    Qualified --> ReleaseReady: integration and replay pass
    Implemented --> Blocked: required external evidence unavailable
    Correlated --> Blocked: qualification evidence incomplete
```

- `Implemented` means the native backend and typed contract are present.
- `Correlated` means an independent reference has passed for the declared scope.
- `Qualified` means a named PDK/process scope has retained evidence.
- `ReleaseReady` is not allowed while an external oracle or process gate is merely assumed.
- `Blocked` is a structured release state with a reason and next action, not a successful result.

## Immediate execution order

1. Complete M1 provenance and canonical semantic gaps. **Done**
2. Implement M2 manifest-driven retained corpus and replay artifacts. **Done**
3. Implement M3 independent reference correlation and explicit external-oracle availability. **Done for the retained Sky130A/OpenSTA profile**
4. Implement M4 process qualification evidence and decision logic. **Done for the retained Sky130A profile**
5. Complete M5 STA/SI headless integration, review artifacts, and resume coverage. **Done**
6. Run M6 as a release audit and update `GOAL_STATUS.md` with evidence paths.

## Current known release blockers

- The external OpenSTA binary remains an environment prerequisite and is not distributed by this package.
- The retained process profile is intentionally narrow: one Sky130A TT Liberty and one DFF case.
- The native backend must not be described as foundry signoff-qualified; SPEF/PEX and broader PVT/library evidence remain required.
- External Xcircuite stage executors may retain a deprecated compatibility envelope during the workspace migration; the canonical TimingEngine service, corpus, CLI and OpenSTA paths already consume Foundation results.
