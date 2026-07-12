# TimingEngine Implementation Plan

## Order

1. Liberty, SDC and SDF parsers
2. Timing graph and constraints
3. MMMC analysis
4. SPEF coupling and crosstalk
5. Retained corpus and independent reference correlation
6. Process qualification decision and Xcircuite headless integration

## First implementation slice

- Implemented the native standards-constrained slice: Liberty, SDC, SDF and SPEF parsing, canonical timing IR, structural design graph construction, MMMC STA, derates and coupling-aware SI.
- Added deterministic positive fixtures and negative-path fixtures.
- Added JSON request/payload and parser round-trip coverage.
- Added the `timingengine` deterministic JSON CLI.
- Added path/clock-group semantics, cell power metadata and provenance-bound payloads.
- Added a manifest-driven retained corpus with positive, blocked and SI cases and a CLI replay command.
- Added an independent scalar reference analyzer, explicit correlation tolerances and an external-oracle availability probe.
- Added an external-process oracle runner and envelope correlator that verify slack, mode, corner and provenance agreement.
- Added bounded external-process execution with structured launch, timeout, cancellation, non-zero-exit and invalid-envelope diagnostics.
- Added PDK manifest validation and required-asset digest evidence; the retained fixture process now has a complete manifest/asset evidence record.
- Added PDK/process qualification decision logic with evidence digests; the fixture remains blocked only because no external digital STA oracle is installed.
- Added Xcircuite `timing.sta` and `timing.signal-integrity` adapters with artifact verification, persistence and headless tests.

## Completion gates

- Public APIs remain protocol-first and Sendable.
- Every unsupported semantic produces a structured blocked result.
- Native and external backends produce the same result schema.
- No UI type enters a public contract.
- No result claims foundry qualification without process-scoped oracle evidence.
- Xcircuite can execute, persist, review and resume the timing stages without circuit-studio.
