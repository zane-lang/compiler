#!/bin/sh
# LLVM's own `default<O2>` pipeline as text, with inductive range check
# elimination added after the loop passes that first rotate each loop and
# hoist what it reads (lib/codegen/passes.ml), as an OCaml string. The `opt`
# of the LLVM `$LLVM_CONFIG` names prints it, so it is that LLVM's pipeline.
set -eu
llvm_config=${LLVM_CONFIG:-llvm-config}
opt="$("$llvm_config" --bindir)/opt"
pipeline=$(echo 'define void @f() { ret void }' | "$opt" -passes='default<O2>' -print-pipeline-passes -disable-output -)
group='simple-loop-unswitch<no-nontrivial;trivial>)'
anchor="$group,simplifycfg"
case "$pipeline" in
*"$anchor"*) ;;
*)
  echo "o2_pipeline.sh: no loop group ending in $group in: $pipeline" >&2
  exit 1
  ;;
esac
printf 'let with_irce = "%s"\n' "${pipeline%%"$anchor"*}$group,irce,simplifycfg${pipeline#*"$anchor"}"
