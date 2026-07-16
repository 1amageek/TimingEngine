#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PACKAGE_ROOT="$SCRIPT_DIR"
SKY130_ROOT=${SKY130_ROOT:-"$HOME/.volare/sky130A"}
OPENSTA_BIN=${OPENSTA_BIN:-}
OUTPUT_ROOT=${OUTPUT_ROOT:-"$PACKAGE_ROOT/.build/qualification/sky130A"}
RUNTIME_ROOT="$OUTPUT_ROOT/runtime"

if [ -z "$OPENSTA_BIN" ]; then
    OPENSTA_BIN=$(command -v opensta 2>/dev/null || true)
fi
if [ -z "$OPENSTA_BIN" ]; then
    OPENSTA_BIN=$(command -v sta 2>/dev/null || true)
fi

LIBERTY_SOURCE="$SKY130_ROOT/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
if [ ! -f "$LIBERTY_SOURCE" ]; then
    echo "Sky130A Liberty was not found at $LIBERTY_SOURCE" >&2
    exit 2
fi
if [ -z "$OPENSTA_BIN" ] || [ ! -x "$OPENSTA_BIN" ]; then
    echo "Set OPENSTA_BIN to an independent OpenSTA executable." >&2
    exit 2
fi

mkdir -p "$RUNTIME_ROOT"
cp "$SCRIPT_DIR/Qualification/sky130A/pdk.json" "$RUNTIME_ROOT/pdk.json"
cp "$SCRIPT_DIR/Qualification/sky130A/corpus.json" "$RUNTIME_ROOT/corpus.json"
cp "$SCRIPT_DIR/Qualification/sky130A/sky130_top.v" "$RUNTIME_ROOT/sky130_top.v"
cp "$SCRIPT_DIR/Qualification/sky130A/sky130.sdc" "$RUNTIME_ROOT/sky130.sdc"
cp "$LIBERTY_SOURCE" "$RUNTIME_ROOT/sky130_tt.lib"
cp "$OPENSTA_BIN" "$RUNTIME_ROOT/opensta"
chmod +x "$RUNTIME_ROOT/opensta"
RETAINED_OPENSTA_BIN="$RUNTIME_ROOT/opensta"

cd "$PACKAGE_ROOT"
swift run timingengine run-corpus \
    --manifest "$RUNTIME_ROOT/corpus.json" \
    --root "$RUNTIME_ROOT" \
    --run-id sky130-corpus \
    --out "$OUTPUT_ROOT/sky130-corpus-report.json" > "$OUTPUT_ROOT/sky130-corpus-envelope.json"

swift run timingengine run-sta \
    --workspace-root "$OUTPUT_ROOT" \
    --design "$RUNTIME_ROOT/sky130_top.v" \
    --library "$RUNTIME_ROOT/sky130_tt.lib" \
    --constraints "$RUNTIME_ROOT/sky130.sdc" \
    --pdk-manifest "$RUNTIME_ROOT/pdk.json" \
    --process sky130A \
    --pdk-version c6d73a35f524070e85faff4a6a9eef49553ebc2b \
    --mode functional \
    --corner tt-025C-1v80 \
    --top top \
    --run-id sky130-native > "$OUTPUT_ROOT/sky130-native.json"

swift build --product opensta-oracle-adapter > /dev/null
ADAPTER_BIN=$(swift build --show-bin-path --product opensta-oracle-adapter)
"$ADAPTER_BIN/opensta-oracle-adapter" \
    --workspace-root "$OUTPUT_ROOT" \
    --sta "$RETAINED_OPENSTA_BIN" \
    --oracle-id opensta \
    --oracle-version 3.1 \
    --design "$RUNTIME_ROOT/sky130_top.v" \
    --library "$RUNTIME_ROOT/sky130_tt.lib" \
    --constraints "$RUNTIME_ROOT/sky130.sdc" \
    --pdk-manifest "$RUNTIME_ROOT/pdk.json" \
    --process sky130A \
    --pdk-version c6d73a35f524070e85faff4a6a9eef49553ebc2b \
    --mode functional \
    --corner tt-025C-1v80 \
    --top top \
    --run-id sky130-opensta > "$OUTPUT_ROOT/sky130-opensta.json"

swift run timingengine correlate-oracle \
    --workspace-root "$OUTPUT_ROOT" \
    --native-report "$OUTPUT_ROOT/sky130-native.json" \
    --oracle-report "$OUTPUT_ROOT/sky130-opensta.json" \
    --corpus-report "$OUTPUT_ROOT/sky130-corpus-report.json" \
    --pdk-manifest "$RUNTIME_ROOT/pdk.json" \
    --process sky130A \
    --pdk-version c6d73a35f524070e85faff4a6a9eef49553ebc2b \
    --oracle-id opensta \
    --oracle-version 3.1 \
    --oracle-path "$RETAINED_OPENSTA_BIN" \
    --tolerance 1e-12 \
    --out "$OUTPUT_ROOT/sky130-correlation.json" > /dev/null

swift run timingengine assess-evidence \
    --workspace-root "$OUTPUT_ROOT" \
    --corpus-report "$OUTPUT_ROOT/sky130-corpus-report.json" \
    --pdk-manifest "$RUNTIME_ROOT/pdk.json" \
    --process sky130A \
    --pdk-version c6d73a35f524070e85faff4a6a9eef49553ebc2b \
    --mode functional \
    --corner tt-025C-1v80 \
    --oracle-id opensta \
    --oracle-version 3.1 \
    --oracle-path "$RETAINED_OPENSTA_BIN" \
    --correlation-report "$OUTPUT_ROOT/sky130-correlation.json" \
    --out "$OUTPUT_ROOT/sky130-evidence-assessment.json" > /dev/null

echo "Sky130A timing evidence artifacts written to $OUTPUT_ROOT"
