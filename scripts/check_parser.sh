#!/usr/bin/env bash
set -euo pipefail

ROOT=.
OUTPUT=$ROOT/test-parser/main.ast.json
INPUT=${1:-$ROOT/test-parser/main.zn}

"$ROOT/scripts/generate_parser.sh"
"$BUILD_DIR/zane-parser" "$INPUT" > "$OUTPUT"
echo "AST written to $OUTPUT"
