# Read by every non-interactive bash on Windows, through BASH_ENV
# (dev/setup/activate.bat). opam needs git, and conda's git brings an MSYS
# whose root is the environment's Library directory: there Library\bin reads
# as /bin, which MSYS mounts onto /usr/bin, and Library\lib as /lib, onto
# /usr/lib. So the environment's own tools -- OCaml, opam, LLVM, zig, just --
# drop off PATH as bash reads it. Their drive-letter names, which no mount
# shadows, go back on it. A bash that a Windows program starts (pixi, just,
# dune) reads PATH from Windows' form afresh, so each bash puts them back.
if [[ -n ${CONDA_PREFIX:-} ]]; then
	prefix=${CONDA_PREFIX//\\//}
	if [[ $prefix == ?:* ]]; then
		drive=${prefix%%:*}
		prefix="/${drive,,}${prefix#*:}"
	fi
	PATH="$prefix/Library/bin:$prefix/Library/lib/ocaml/stublibs:$PATH"
	unset prefix drive
fi

# OCaml's MSVC build links through MSVC's link.exe, which the MSYS's
# coreutils `link` would shadow: MSVC's tools go first.
if cl=$(command -v cl 2>/dev/null); then
	PATH="${cl%/*}:$PATH"
fi
unset cl
export PATH
