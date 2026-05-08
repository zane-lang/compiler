#!/usr/bin/env bash
set -euo pipefail

ROOT=.
BUILD_DIR=${BUILD_DIR:-$ROOT/parser}

mkdir -p "$BUILD_DIR"

bison --defines="$BUILD_DIR/parser.hpp" --output="$BUILD_DIR/parser.cpp" "$ROOT/grammar/parser.y"
re2c --output "$BUILD_DIR/lexer.cpp" "$ROOT/grammar/lexer.re"
clang++ -std=c++23 -Wall -Wextra -pedantic \
-I"$ROOT/grammar" \
-I"$BUILD_DIR" \
"$ROOT/grammar/main.cpp" \
"$BUILD_DIR/parser.cpp" \
"$BUILD_DIR/lexer.cpp" \
-o "$BUILD_DIR/zane-parser"
