# TimingEngine capability and limitation report

## Native capabilities

| Area | Implemented behavior | Result evidence |
|---|---|---|
| Liberty | Parses library units, operating conditions, pins, NLDM delay/transition tables, unate arcs, sequential timing constraints and cell power metadata | `LibertyParser`, parser tests |
| SDC | Parses clocks, generated clocks, input/output delays, uncertainty, false paths, multicycle paths, path groups, clock groups and max/min path constraints | `SDCParser`, parser tests |
| Design graph | Loads canonical JSON IR and a deterministic structural Verilog subset | `TimingDesignParser` |
| MMMC STA | Expands requested modes/corners, propagates rise/fall arrival and slew, evaluates setup/hold and sequential checks | `NativeSTAEngine`, native STA tests |
| Variation | Applies declared early/late cell and interconnect derates | `STAVariation`, native backend |
| SI | Parses SPEF ground/coupling capacitance and resistance, computes delta delay and noise ratio | `NativeSignalIntegrityEngine`, SI tests |
| SDF | Imports and exports cell I/O delay annotations | `SDFParser`, `SDFWriter`, round-trip test |
| Developer surface | Typed API, deterministic JSON CLI, positive and negative fixtures, structured diagnostics | `timingengine`, tests |
| Evidence | Manifest-driven retained corpus, blocked/negative cases, provenance-bound results and replay report | `Corpus/timing-corpus.json`, `LocalTimingCorpusRunner` |
| Correlation | Independent scalar reference analyzer plus external-process Foundation-result adapter with explicit metric, mode, corner and provenance checks | `TimingReferenceAnalyzer`, `TimingExternalOracleCorrelator`, `LocalTimingExternalOracleRunner` |
| Qualification | PDK manifest validation, required-asset digest evidence, corner/mode matrix and corpus/oracle gate | `LocalTimingPDKQualificationEvidenceBuilder`, `TimingQualificationEvaluator`, `TimingQualificationReport` |
| Xcircuite | Headless `timing.sta` and `timing.signal-integrity` adapters with digest verification and result artifact persistence | `TimingSTAFlowStageExecutor`, `TimingSIFlowStageExecutor` |
| CircuiteFoundation | Foundation-native STA/SI requests and results with verified artifact references, execution evidence and typed diagnostics | `STAFoundationEngine`, `SignalIntegrityFoundationEngine`, `STAExecutionResult`, `SignalIntegrityExecutionResult` |

## Explicit limitations

- Liberty support is a deterministic signoff-oriented subset; uncommon table templates and vendor-specific attributes are blocked with a typed diagnostic.
- The native STA backend is not process-qualified and does not claim foundry signoff.
- Statistical OCV, AOCV/POCV correlation, waveform-resolved crosstalk noise and CCS/ECSM remain outside the native subset.
- The independent scalar reference oracle is implemented for the retained subset; no external digital STA executable is available locally, so external correlation and process qualification remain blocked.
- External oracle execution accepts a fixed executable path and argument array, enforces a request timeout with process-tree cleanup, validates the returned run ID, and requires a completed canonical `STAExecutionResult` on stdout. Obsolete result schemas are rejected; availability is not treated as correlation evidence.
- Qualification remains a separate ToolQualification evidence state and must be established per PDK/process/corner.
- TimingEngine has no compatibility envelope or adapter boundary. The service, corpus, CLI and OpenSTA paths all exchange Foundation-native requests and results.
