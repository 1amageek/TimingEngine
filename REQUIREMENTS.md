# TimingEngine Requirements

## Goal

Provide standard-constrained multi-corner timing and signal-integrity analysis with reproducible, machine-readable evidence.

## Required functions

| Function | Required behavior | Priority |
|---|---|---:|
| Liberty parsing | Parse cells, pins, arcs, tables, constraints, power and operating conditions | P0 |
| SDC parsing | Parse clocks, IO delays, uncertainty, exceptions and path groups | P0 |
| Timing graph | Build stable identities from logic and physical/parasitic handoffs | P0 |
| MMMC STA | Evaluate setup/hold and declared sequential checks across modes/corners | P0 |
| Reports | Emit machine-readable paths, diagnostics and repair candidates | P0 |
| SDF | Import/export annotated timing | P1 |
| Variation | Support declared derates and advanced-variation lanes | P1 |
| Signal integrity | Consume coupling parasitics and report crosstalk effects | P1 |

## Evidence requirements

- Every timing result names its mode, corner, constraints, PDK and parasitic identity.
- External correlation reopens raw native/oracle outputs and recomputes metrics.
- Correlation artifacts use workspace-relative locations under one explicit root.
- Persisted assessment outcome is derived from findings.
- Timing evidence remains distinct from ToolQualification acceptance and DesignFlowKernel approval.
- Ideal-interconnect results do not satisfy post-layout signoff.

## Developer surfaces

- Protocol-first typed API
- Deterministic JSON CLI
- Positive, negative and blocked fixtures
- Retained corpus and raw correlation report
- Structured errors and diagnostics
- Capability and limitation report
