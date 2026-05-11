#!/usr/bin/env python3

import pathlib
import sys
import textwrap


def main() -> int:
	if len(sys.argv) != 5:
		raise SystemExit("usage: embed_text.py <input> <output> <namespace> <function>")

	input_path = pathlib.Path(sys.argv[1])
	output_path = pathlib.Path(sys.argv[2])
	namespace = sys.argv[3]
	function_name = sys.argv[4]

	source = input_path.read_bytes()
	
	# Convert bytes to hex escapes
	hex_chars = [f"\\x{byte:02x}" for byte in source]
	
	# Wrap lines every 16 bytes
	chars_per_line = 16
	lines = []
	for i in range(0, len(hex_chars), chars_per_line):
		chunk = hex_chars[i:i + chars_per_line]
		lines.append('"' + "".join(chunk) + '"')
	
	# Join lines with a newline and 4 spaces (or tab) for C++ indentation
	# Note: We indent each line here so they align inside the C++ function
	literal_body = "\n\t".join(lines)

	# Use textwrap.dedent to remove the common leading whitespace from the f-string
	# This lets you indent the f-string nicely in Python without affecting the output
	output_content = textwrap.dedent(f"""\
		#include "compiler/helios_symbols.hpp"

		namespace {namespace} {{

		std::string_view {function_name}() {{
			static constexpr char content[] = 
				{literal_body};
			return std::string_view(content, sizeof(content) - 1);
		}}

		}} // namespace {namespace}
		""")

	output_path.write_text(output_content, encoding="utf-8")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
