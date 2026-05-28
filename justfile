debug:
	rm -rf build
	vcpkg install
	CXX=clang++ meson setup build --buildtype=debug --cmake-prefix-path "$(realpath vcpkg_installed/x64-linux)"

release:
	rm -rf build
	vcpkg install
	CXX=clang++ meson setup build --buildtype=release --cmake-prefix-path "$(realpath vcpkg_installed/x64-linux)"

test-parser:
	meson compile -C build
	./build/zane test-parser/main.zn

glr-stats:
	meson compile -C build
	ELKHOUND_DEBUG=1 ./build/zane test-parser/main.zn 2>/dev/null

grammar-conflicts:
	elkhound -v -tr conflict,prec src/grammar/parser.gr
