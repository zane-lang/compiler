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

[working-directory: "test"]
test:
	rm -rf test/.cache
	../build/zane build
	pwsh.exe -Command ./build/windows-x64/test.exe 2>&1

[working-directory: "test"]
run:
	../build/zane run 2>&1 | python3 ../scripts/prettify.py

check:
	clang-check -p build src/*.*
