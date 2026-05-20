#include "ast/logic.hpp"
#include "parser.tab.h"
#include <iostream>
#include <string>

int main(int argc, char** argv) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " \"<expr>\"\n";
        return 1;
    }

    std::string src = argv[1];
    const char* cursor = src.data();
    const char* marker = cursor;
    const char* limit = cursor + src.size();

    yy::Parser parser;
    int res = parser.parse(cursor, marker, limit);

    if (res == 0) std::cout << "✓ Parsed\n";
    return res;
}
