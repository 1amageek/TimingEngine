# TimingEngine Goal Status

## Current state

**Native backend, retained replay, external OpenSTA correlation, process-specific Sky130A evidence and Xcircuite headless contracts are implemented for the declared standards-constrained subset. The release profile is qualified locally; broader foundry/signoff equivalence remains an explicit limitation.**

| Maturity gate | Status | Evidence |
|---|---|---|
| Responsibility boundary | Complete | README.md and DESIGN.md |
| Public package products | Complete | Package.swift and public targets |
| Shared Foundation execution contract | Complete | `STAFoundationRequest`, `SignalIntegrityFoundationRequest`, domain results and `Engine` seams |
| Foundation request/result contract | Canonical | Native engines directly implement Foundation protocols; no compatibility envelope or artifact adapter is shipped |
| Contract build | Passed | swift build |
| Contract test | Passed locally | timeout-bounded SwiftPM Testing run: 28 tests in 6 suites, including the Foundation boundary and artifact persistence; no Xcode test scheme is configured for this package |
| Domain implementation | Implemented | Native parser, timing graph, MMMC STA and SI backends |
| CLI implementation | Implemented | `timingengine` JSON CLI |
| Fixture corpus | Retained replay complete | `Corpus/timing-corpus.json`, positive/blocked/SI cases and CLI replay |
| Oracle correlation | Local reference complete | `TimingReferenceAnalyzer`, tolerance comparison and retained correlation result |
| External oracle evidence | Complete for the retained profile | Bounded OpenSTA adapter emits `STAExecutionResult`; Sky130A correlation passes at 1 ps tolerance with matching input digests |
| Process qualification | Complete for the retained Sky130A profile | `Qualification/sky130A`, PDK manifest validation, Liberty asset digest evidence, corpus replay and qualification decision all pass |
| Runtime integration seam | Implemented | Foundation requests/results are consumable by DesignFlowKernel and Xcircuite runtime stages |
| CircuiteFoundation boundary | Canonical | `NativeSTAEngine`, `NativeSignalIntegrityEngine`, service, corpus, CLI and OpenSTA exchange Foundation requests/results |
| End-to-end flow evidence | Complete for native STA/SI contracts | Runtime integration consumes typed requests/results; flow review and resume remain runtime responsibilities |
| Public source distribution | Published and clone-resolvable | `https://github.com/1amageek/TimingEngine`; isolated clones use public revision pins for CircuiteFoundation and LogicDesign, while the full workspace selects sibling packages |
| Release readiness | Scoped profile passed; broader signoff blocked | Sky130A TT local qualification passes; no foundry signoff equivalence is claimed without parasitics and broader PVT/cell coverage |

## Function status

| Function | Contract | Implementation | Validation corpus | Qualification |
|---|---|---|---|---|
| Liberty parsing | Contract defined | Native subset implemented | Positive and malformed parser tests | No process qualification |
| SDC parsing | Contract defined | Native subset implemented | Clock/IO/exception tests | No process qualification |
| SDF support | Contract defined | Import/export implemented | Round-trip test | No process qualification |
| Timing graph construction | Contract defined | JSON and structural Verilog implemented | Stable graph test | No process qualification |
| MMMC STA | Contract defined | Native setup/hold/recovery/removal/pulse-width lanes | Deterministic native STA plus retained reference correlation | External oracle unavailable |
| Variation modeling | Contract defined | Declared early/late derates implemented | Capability report | No statistical qualification |
| Signal integrity | Contract defined | SPEF coupling delta delay/noise ratio implemented | Crosstalk violation test | No waveform-resolved qualification |
| Reports and ECO candidates | Contract defined | Structured paths, violations and repair candidates | Native STA payload assertions | No process qualification |

## Goal progression

```text
contract scaffold
      ↓
narrow implementation
      ↓
negative-path fixtures
      ↓
corpus validation
      ↓
reference-oracle correlation
      ↓
process-scoped qualification
      ↓
Xcircuite integration and repair loop
      ↓
release-profile eligibility
```

## Completion definition

The package goal is complete only when every P0 function has a concrete backend, structured failure behavior, retained corpus, reference correlation where an oracle exists, process-scoped qualification where required, a deterministic CLI and a passing Xcircuite headless integration test.

## Current blockers

- Advanced vendor-specific parser semantics are intentionally blocked with structured diagnostics.
- The external OpenSTA executable is an environment prerequisite; the repository ships the adapter contract, not the oracle binary.
- The Sky130A profile covers one TT DFF case and one Liberty asset; broader PVT, cell-family, SI, extraction and foundry signoff coverage remain open.
- Native post-layout signoff remains blocked without SPEF/PEX evidence.
- Flow-stage persistence, approval and resume are intentionally outside TimingEngine and are supplied by the runtime integration.

## Final audit evidence

The latest audit on 2026-07-13 passed the following controlled checks:

- `swift build`
- `swift test` with a bounded process timeout
- fresh public clone resolve/build/test at the pinned dependency revisions: 28 tests in 6 suites, including the Foundation boundary and artifact persistence
- `timingengine capabilities`
- retained corpus replay with `isValid: true`
- public-clone corpus replay with `isValid: true` and qualification blocked only by `external_sta_oracle_unavailable` when the fixture version is supplied
- PDK manifest and required-asset evidence generation
- `Scripts/qualify-sky130A.sh` with local Volare Sky130A and OpenSTA 3.1: corpus `isValid: true`, correlation `passed: true`, qualification `decision: qualified`
- qualification decision serialization with an explicit missing-correlation gate
- CLI oracle-correlation schema smoke using two identical retained native reports
- Xcircuite `TimingHeadlessFlowTests` through SwiftPM Testing with a bounded process timeout

The retained Sky130A evidence uses an independent OpenSTA process and matching design, Liberty, SDC and PDK manifest digests. It is a scoped local qualification result, not a blanket foundry signoff claim.

This file must be updated by implementation agents whenever a maturity gate changes. A source file or type name alone is never evidence of implementation or qualification.
