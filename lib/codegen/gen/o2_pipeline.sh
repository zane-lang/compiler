#!/bin/sh
# LLVM's own `default<O2>` pipeline as text, as an OCaml string, with two
# passes added (lib/codegen/passes.ml): jump threading at the end of the
# first function simplification, once each function's locals are in
# registers, and inductive range check elimination after the loop passes
# that first rotate each loop and hoist what it reads. Then the same with
# runtime loop unrolling off, for tier 1 (docs/design/tiers.md T2). The
# `opt` of the LLVM `$LLVM_CONFIG` names prints it, so it is that LLVM's
# pipeline.
set -eu
llvm_config=${LLVM_CONFIG:-llvm-config}
opt="$("$llvm_config" --bindir)/opt"
pipeline=$(echo 'define void @f() { ret void }' | "$opt" -passes='default<O2>' -print-pipeline-passes -disable-output -)

# The pipeline with the text $2 put between the first $1 and the $3 that
# follows it at once.
add() {
  case "$pipeline" in
  *"$1$3"*) ;;
  *)
    echo "o2_pipeline.sh: no $1 followed by $3 in: $pipeline" >&2
    exit 1
    ;;
  esac
  pipeline="${pipeline%%"$1$3"*}$1$2$3${pipeline#*"$1$3"}"
}

add 'sroa<modify-cfg>,early-cse<>' ',jump-threading' ')'
add 'simple-loop-unswitch<no-nontrivial;trivial>)' ',irce' ',simplifycfg'
printf 'let optimized = "%s"\n' "$pipeline"
add 'loop-unroll<O2' ';no-runtime' '>'
printf 'let tier1 = "%s"\n' "$pipeline"
