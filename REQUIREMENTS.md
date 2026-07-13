# TimingEngine Requirements

## Goal

Provide standard-constrained, multi-corner timing and signal-integrity analysis suitable for post-layout signoff.

## Required functions

| Function | Required behavior | Priority |
|---|---|---:|
| Liberty parsing | Parse cells, pins, arcs, tables, constraints, power and operating conditions. | P0 |
| SDC parsing | Parse clocks, generated clocks, IO delays, uncertainty, exceptions and path groups. | P0 |
| SDF support | Import and export annotated timing for gate-level verification. | P1 |
| Timing graph construction | Build stable graph identities from LogicDesign and physical/parasitic handoffs. | P0 |
| MMMC STA | Evaluate setup, hold, recovery, removal and pulse-width checks across modes and corners. | P0 |
| Variation modeling | Support derates, OCV and declared statistical or advanced variation lanes. | P1 |
| Signal integrity | Consume coupling parasitics and compute crosstalk delta delay and noise violations. | P1 |
| Reports and ECO candidates | Emit machine-readable paths, bottlenecks and repair candidates. | P0 |

## Required outcomes

- Every timing verdict names its mode, corner, constraints and parasitic digest.
- Ideal-interconnect results cannot satisfy post-layout signoff.
- Timing results are consumable by Xcircuite repair loops.

## Common platform requirements

- Public execution surfaces are protocol-first, Sendable and dependency-injected.
- Requests and payloads are Codable, Hashable and schema-versioned.
- Foundation-facing inputs and outputs use immutable `ArtifactReference` values with verified locations, digests and byte counts. No legacy artifact shape is exposed by this package.
- Diagnostics contain a stable code, severity, affected entity and suggested actions.
- Unsupported semantics and missing prerequisites produce blocked results.
- Native and external-tool backends conform to identical request and payload schemas.
- Execution capability, corpus validation, oracle correlation, process qualification and release approval remain distinct.
- Xcircuite owns flow construction, artifact persistence, qualification gates, repair loops, approval and resume.
- The package never imports Xcircuite or circuit-studio.

## Required developer surfaces

- Typed API
- Deterministic JSON CLI
- Positive and negative fixtures
- Contract and parser round-trip tests
- Reference corpus
- Capability and limitation report
- Foundation protocol integration tests at the consuming runtime boundary
