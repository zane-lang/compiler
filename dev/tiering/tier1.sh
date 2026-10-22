#!/bin/sh
# tier1.sh ZANEC PACKAGE SO: the optimized shared object, put in place whole.
set -e
"$1" --object "$3.o" --optimize --package "$2"
cc -shared -Wl,-Bsymbolic "$3.o" -o "$3.tmp"
mv "$3.tmp" "$3"
