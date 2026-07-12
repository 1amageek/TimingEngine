# TimingEngine Goal Status

## Current state

**Native backend, retained replay, local/external oracle contracts, PDK asset evidence and qualification decision infrastructure are implemented for the declared standards-constrained subset. External-oracle execution evidence and final process qualification remain separate blocked gates.**

| Maturity gate | Status | Evidence |
|---|---|---|
| Responsibility boundary | Complete | README.md and DESIGN.md |
| Public package products | Complete | Package.swift and public targets |
| Shared Xcircuite request/result contract | Complete | Public Swift protocols, payloads and provenance |
| Contract build | Passed | swift build |
| Contract test | Passed | timeout-bounded SwiftPM Testing run: 18 tests in 5 suites; no Xcode test scheme is configured for this package |
| Domain implementation | Implemented | Native parser, timing graph, MMMC STA and SI backends |
| CLI implementation | Implemented | `timingengine` JSON CLI |
| Fixture corpus | Retained replay complete | `Corpus/timing-corpus.json`, positive/blocked/SI cases and CLI replay |
| Oracle correlation | Local reference complete | `TimingReferenceAnalyzer`, tolerance comparison and retained correlation result |
| External oracle evidence | Contract complete; execution blocked | `LocalTimingExternalOracleRunner` and correlator implemented; no OpenSTA/PrimeTime/Tempus executable is present locally |
| Process qualification | PDK evidence complete; final qualification blocked | Manifest validation and required-asset digest evidence pass for the retained fixture; oracle gate remains blocked |
| Xcircuite stage adapters | Implemented | `TimingSTAFlowStageExecutor` and `TimingSIFlowStageExecutor` resolve, verify and persist artifacts |
| End-to-end flow evidence | Complete for native STA/SI adapters | Xcircuite focused Xcode test passed: 3 timing headless tests, including review/approval/resume artifact integrity |
| Public source distribution | Published and clone-resolvable | `https://github.com/1amageek/TimingEngine`; dependencies are public and revision-pinned |
| Release readiness | Blocked by qualification gates | Native/replay/integration gates pass; external oracle and process qualification remain absent |

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
- No external digital STA oracle has been selected or qualified; local probing reports unavailable.
- The retained process fixture has validated manifest/corner/asset evidence but is not a foundry qualification corpus.
- Xcircuite native integration is verified; release still requires external oracle correlation and a process-specific qualification corpus.

## Final audit evidence

The latest audit on 2026-07-13 passed the following controlled checks:

- `swift build`
- `swift test` with a 60-second process timeout
- `timingengine capabilities`
- retained corpus replay with `isValid: true`
- PDK manifest and required-asset evidence generation
- qualification decision serialization with an explicit `external_sta_oracle_unavailable` finding
- CLI oracle-correlation schema smoke using two identical retained native reports
- Xcircuite `TimingHeadlessFlowTests` through `xcodebuild test` with a bounded process timeout

The CLI correlation smoke is schema and provenance validation only. It is not external STA evidence because the local environment has no independent digital STA executable.

This file must be updated by implementation agents whenever a maturity gate changes. A source file or type name alone is never evidence of implementation or qualification.
