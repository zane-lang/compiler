build:
	meson compile -C build

init:
	rm -rf build
	test -d .git/modules || git submodule update --init --recursive
	vcpkg install
	CXX=clang++ meson setup build --buildtype=debug --cmake-prefix-path "$(realpath vcpkg_installed/x64-linux)"

release:
	rm -rf build
	test -d .git/modules || git submodule update --init --recursive
	vcpkg install
	CXX=clang++ meson setup build --buildtype=release --cmake-prefix-path "$(realpath vcpkg_installed/x64-linux)"

check:
	clang-check -p build src/*.*

generate-parser:
	scripts/generate_parser.sh

check-parser:
	scripts/check_parser.sh

link:
	ln -sf build/zane bin/zane
