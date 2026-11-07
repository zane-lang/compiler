# Sourced by pixi when it activates the environment (pixi.toml), after
# each package's own activation: what the build reads besides the tools
# on PATH (README.md, "Setup").

# The project's opam root and switch, which `pixi run setup` makes. conda's
# opam package points OPAMROOT at a root of its own, with a switch named
# `conda` in it; the project keeps one inside the environment's directory.
export OPAMROOT="$PIXI_PROJECT_ROOT/.pixi/opam"
unset OPAMSWITCH

# The repository's own commands, and the C compiler `zanec` compiles the
# runtime and links with: clang linking with LLD (dev/bin/clang-lld).
export PATH="$PIXI_PROJECT_ROOT/dev/bin:$PATH"
export ZANE_CC="${ZANE_CC:-$PIXI_PROJECT_ROOT/dev/bin/clang-lld}"

# The LLVM the compiler's bindings and stubs build against
# (lib/llvm/config/discover.ml).
export LLVM_CONFIG="$CONDA_PREFIX/bin/llvm-config"

# LLVM's archive tools, which the tests' archives are made with, in place
# of the platform's that conda's compiler activation names (cctools' on
# macOS).
export AR=llvm-ar STRIP=llvm-strip

# The switch's tools and libraries, once it has been made.
if [ -d "$PIXI_PROJECT_ROOT/_opam" ]; then
	eval "$(opam env --switch="$PIXI_PROJECT_ROOT" --set-switch --shell=sh)"
fi
