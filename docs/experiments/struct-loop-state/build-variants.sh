#!/bin/sh
# build-variants.sh TAG COMPILERDIR : the LangArena zane port built with COMPILERDIR's
# zanec once per Brainfuck::Array variant (brainfuck/*.zn), into $OUT/la-TAG-VARIANT.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
S=${OUT:-$HERE/out}; mkdir -p "$S"
export PATH=$HOME/.local/bin:$PATH
export LANGARENA=${LANGARENA:-/home/user/la-zane}
F=$LANGARENA/zane/lib/brainfuck/brainfuck.zn
for v in ${VARIANTS:-locals worker counted}; do
  cp $HERE/brainfuck/$v.zn $F
  COMPILER=$2 sh $HERE/../langarena-vs-goose/build.sh $S/la-$1-$v 2>&1 | tail -3
done
cp $HERE/brainfuck/worker.zn $F
