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
	./build/zane
