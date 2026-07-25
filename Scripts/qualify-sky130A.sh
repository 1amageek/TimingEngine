#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PACKAGE_ROOT="$SCRIPT_DIR"
SKY130_ROOT=${SKY130_ROOT:-"$HOME/.volare/sky130A"}
OPENSTA_BIN=${OPENSTA_BIN:-}
OPENSTA_VERSION=${OPENSTA_VERSION:-}
OUTPUT_ROOT=${OUTPUT_ROOT:-}

if [ -z "$OPENSTA_BIN" ]; then
    OPENSTA_BIN=$(command -v opensta 2>/dev/null || true)
fi
if [ -z "$OPENSTA_BIN" ]; then
    OPENSTA_BIN=$(command -v sta 2>/dev/null || true)
fi

if [ -z "$OPENSTA_BIN" ] || [ ! -x "$OPENSTA_BIN" ]; then
    echo "Set OPENSTA_BIN to an independent OpenSTA executable." >&2
    exit 2
fi
if [ -z "$OPENSTA_VERSION" ]; then
    echo "Set OPENSTA_VERSION to the exact version token reported by '$OPENSTA_BIN -version'." >&2
    exit 2
fi

if [ -z "$OUTPUT_ROOT" ]; then
    mkdir -p "$PACKAGE_ROOT/.build/qualification"
    OUTPUT_ROOT=$(mktemp -d "$PACKAGE_ROOT/.build/qualification/sky130A.XXXXXX")
else
    if [ -e "$OUTPUT_ROOT" ]; then
        echo "OUTPUT_ROOT must identify a new evidence directory: $OUTPUT_ROOT" >&2
        exit 2
    fi
    mkdir -p "$OUTPUT_ROOT"
fi
RUNTIME_ROOT="$OUTPUT_ROOT/runtime"
mkdir -p "$RUNTIME_ROOT"
cp "$SCRIPT_DIR/Qualification/sky130A/pdk.json" "$RUNTIME_ROOT/pdk.json"
cp "$SCRIPT_DIR/Qualification/sky130A/corpus.json" "$RUNTIME_ROOT/corpus.json"
cp "$SCRIPT_DIR/Qualification/sky130A/sky130_top.v" "$RUNTIME_ROOT/sky130_top.v"
cp "$SCRIPT_DIR/Qualification/sky130A/sky130.sdc" "$RUNTIME_ROOT/sky130.sdc"
cp "$SCRIPT_DIR/Qualification/sky130A/sky130.spef" "$RUNTIME_ROOT/sky130.spef"

for mapping in \
    "ss-100C-1v60:sky130_fd_sc_hd__ss_100C_1v60.lib:sky130_ss.lib" \
    "tt-025C-1v80:sky130_fd_sc_hd__tt_025C_1v80.lib:sky130_tt.lib" \
    "ff-n40C-1v95:sky130_fd_sc_hd__ff_n40C_1v95.lib:sky130_ff.lib"
do
    corner=${mapping%%:*}
    remainder=${mapping#*:}
    source_name=${remainder%%:*}
    retained_name=${remainder#*:}
    liberty_source="$SKY130_ROOT/libs.ref/sky130_fd_sc_hd/lib/$source_name"
    if [ ! -f "$liberty_source" ]; then
        echo "Sky130A Liberty for $corner was not found at $liberty_source" >&2
        exit 2
    fi
    cp "$liberty_source" "$RUNTIME_ROOT/$retained_name"
done

cp "$OPENSTA_BIN" "$RUNTIME_ROOT/opensta"
chmod +x "$RUNTIME_ROOT/opensta"
RETAINED_OPENSTA_BIN="$RUNTIME_ROOT/opensta"

cd "$PACKAGE_ROOT"
BIN_PATH=$(swift build --show-bin-path)
# Build once so every qualification stage reuses the same executable bytes.
swift build
TIMING_BIN="$BIN_PATH/timingengine"
ADAPTER_BIN="$BIN_PATH/opensta-oracle-adapter"

"$TIMING_BIN" run-corpus \
    --manifest "$RUNTIME_ROOT/corpus.json" \
    --root "$RUNTIME_ROOT" \
    --run-id sky130-corpus \
    --out "$OUTPUT_ROOT/sky130-corpus-report.json" > "$OUTPUT_ROOT/sky130-corpus-envelope.json"

for mapping in \
    "ss-100C-1v60:sky130_ss.lib" \
    "tt-025C-1v80:sky130_tt.lib" \
    "ff-n40C-1v95:sky130_ff.lib"
do
    corner=${mapping%%:*}
    library_name=${mapping#*:}
    native_report="$OUTPUT_ROOT/sky130-$corner-native.json"
    oracle_report="$OUTPUT_ROOT/sky130-$corner-opensta.json"
    correlation_report="$OUTPUT_ROOT/sky130-$corner-correlation.json"
    assessment_report="$OUTPUT_ROOT/sky130-$corner-evidence-assessment.json"

    "$TIMING_BIN" run-sta \
        --workspace-root "$OUTPUT_ROOT" \
        --design "$RUNTIME_ROOT/sky130_top.v" \
        --library "$RUNTIME_ROOT/$library_name" \
        --constraints "$RUNTIME_ROOT/sky130.sdc" \
        --spef "$RUNTIME_ROOT/sky130.spef" \
        --requires-post-layout-inputs \
        --pdk-manifest "$RUNTIME_ROOT/pdk.json" \
        --process sky130A \
        --pdk-version c6d73a35f524070e85faff4a6a9eef49553ebc2b \
        --mode functional \
        --corner "$corner" \
        --top top \
        --run-id "sky130-$corner-native" > "$native_report"

    "$ADAPTER_BIN" \
        --workspace-root "$OUTPUT_ROOT" \
        --sta "$RETAINED_OPENSTA_BIN" \
        --oracle-id opensta \
        --oracle-version "$OPENSTA_VERSION" \
        --design "$RUNTIME_ROOT/sky130_top.v" \
        --library "$RUNTIME_ROOT/$library_name" \
        --constraints "$RUNTIME_ROOT/sky130.sdc" \
        --spef "$RUNTIME_ROOT/sky130.spef" \
        --pdk-manifest "$RUNTIME_ROOT/pdk.json" \
        --process sky130A \
        --pdk-version c6d73a35f524070e85faff4a6a9eef49553ebc2b \
        --mode functional \
        --corner "$corner" \
        --top top \
        --run-id "sky130-$corner-opensta" > "$oracle_report"

    "$TIMING_BIN" correlate-oracle \
        --workspace-root "$OUTPUT_ROOT" \
        --native-report "$native_report" \
        --oracle-report "$oracle_report" \
        --corpus-report "$OUTPUT_ROOT/sky130-corpus-report.json" \
        --pdk-manifest "$RUNTIME_ROOT/pdk.json" \
        --process sky130A \
        --pdk-version c6d73a35f524070e85faff4a6a9eef49553ebc2b \
        --oracle-id opensta \
        --oracle-version "$OPENSTA_VERSION" \
        --oracle-path "$RETAINED_OPENSTA_BIN" \
        --tolerance 1e-12 \
        --out "$correlation_report" > /dev/null

    "$TIMING_BIN" assess-evidence \
        --workspace-root "$OUTPUT_ROOT" \
        --corpus-report "$OUTPUT_ROOT/sky130-corpus-report.json" \
        --pdk-manifest "$RUNTIME_ROOT/pdk.json" \
        --process sky130A \
        --pdk-version c6d73a35f524070e85faff4a6a9eef49553ebc2b \
        --mode functional \
        --corner "$corner" \
        --oracle-id opensta \
        --oracle-version "$OPENSTA_VERSION" \
        --oracle-path "$RETAINED_OPENSTA_BIN" \
        --correlation-report "$correlation_report" \
        --out "$assessment_report" > /dev/null
done

echo "Sky130A timing evidence artifacts written to $OUTPUT_ROOT"
