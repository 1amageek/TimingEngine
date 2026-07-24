# TimingEngine Capability and Limitation Report

## Native capabilities

The machine-readable declarations are owned by `NativeSTAEngine.capability`
and `NativeSignalIntegrityEngine.capability`. The `timingengine capabilities`
command emits their schema-versioned records.

| Area | Implemented behavior | Evidence |
|---|---|---|
| Liberty | Units, operating conditions, pins, NLDM tables, unate arcs, sequential constraints and power metadata | Parser and native-engine tests |
| SDC | Clocks, IO delays, uncertainty, exceptions, path groups, clock groups and mode-specific binary case analysis with collection expansion and conflict rejection | Parser tests |
| Design graph | Canonical JSON IR and deterministic structural Verilog subset | `TimingDesignParser` |
| MMMC STA | Requested mode/corner expansion, rise/fall propagation and setup/hold checks | `NativeSTAEngine` |
| Variation | Declared early/late cell and interconnect derates | Native STA tests |
| Signal integrity | SPEF coupling delta delay and noise ratio | `NativeSignalIntegrityEngine` |
| SDF | Import/export of cell I/O delay annotations | Round-trip tests |
| Evidence | Retained corpus, provenance-bound results and workspace-relative correlation artifacts | Corpus tests |
| Correlation | Independent reference and bounded external OpenSTA execution with metric/provenance reconstruction | Correlation tests |
| Assessment | Derived pass/blocked/failed observation without production promotion | `TimingEvidenceAssessment` |

## Explicit limitations

- Liberty support is a deterministic subset; unsupported templates and vendor attributes are blocked.
- Statistical OCV, AOCV/POCV correlation, waveform-resolved noise and CCS/ECSM are not implemented.
- The retained Sky130A profile is narrow and does not establish foundry signoff equivalence.
- Ideal-interconnect results cannot satisfy post-layout signoff requirements.
- OpenSTA availability alone is not correlation evidence.
- TimingEngine does not qualify itself. ToolQualification must validate raw process evidence, and DesignFlowKernel must apply promotion policy.
