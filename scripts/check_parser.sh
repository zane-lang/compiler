#!/usr/bin/env bash
set -euo pipefail

ROOT=.
"$ROOT/scripts/generate_parser.sh"

"$BUILD_DIR/zane-parser" "$INPUT" > "$OUTPUT"
echo "AST written to $OUTPUT"
