build:
	meson compile -C build

init:
	git submodule update --init --recursive
	vcpkg install
	CXX=clang++ meson setup build --buildtype=debug --reconfigure --cmake-prefix-path "$(realpath vcpkg_installed/x64-linux)"

release:
	git submodule update --init --recursive
	vcpkg install
	CXX=clang++ meson setup build --buildtype=release --reconfigure --cmake-prefix-path "$(realpath vcpkg_installed/x64-linux)"

check:
	clang-check -p build src/*.*

[working-directory: "."]
check-parser:
	scripts/check_parser.sh
