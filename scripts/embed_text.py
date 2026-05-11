#!/usr/bin/env python3

import json
import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 5:
        raise SystemExit("usage: embed_text.py <input> <output> <namespace> <function>")

    input_path = pathlib.Path(sys.argv[1])
    output_path = pathlib.Path(sys.argv[2])
    namespace = sys.argv[3]
    function_name = sys.argv[4]

    source = input_path.read_text(encoding="utf-8")
    output_path.write_text(
        f"""#include "compiler/helios_symbols.hpp"

namespace {namespace} {{

std::string_view {function_name}() {{
    static constexpr std::string_view content = {json.dumps(source)};
    return content;
}}

}} // namespace {namespace}
""",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
