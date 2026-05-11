#!/usr/bin/env python3

import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 5:
        raise SystemExit("usage: embed_text.py <input> <output> <namespace> <function>")

    input_path = pathlib.Path(sys.argv[1])
    output_path = pathlib.Path(sys.argv[2])
    namespace = sys.argv[3]
    function_name = sys.argv[4]

    source = input_path.read_bytes()
    literal = "".join(f"\\x{byte:02x}" for byte in source)
    output_path.write_text(
        f"""#include "compiler/helios_symbols.hpp"

namespace {namespace} {{

std::string_view {function_name}() {{
    static constexpr char content[] = "{literal}";
    return std::string_view(content, sizeof(content) - 1);
}}

}} // namespace {namespace}
""",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
