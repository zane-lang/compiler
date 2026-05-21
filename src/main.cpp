#include "ast/logic.hpp"
#include "parser.tab.h"
#include <iostream>
#include <string>

int yylex(yy::Parser::semantic_type* yylval, yy::Parser::location_type*, 
          const char*& cursor, const char*& marker, const char* limit);

int main(int argc, char** argv) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <expression>\n";
        return 1;
    }
    
    std::string input = argv[1];
    const char* cursor = input.c_str();
    const char* marker = cursor;
    const char* limit = cursor + input.size();
    
    yy::Parser parser(cursor, marker, limit);
    int res = parser.parse();
    
    if (res == 0) {
        std::cout << "Parsed successfully\n";
    } else {
        std::cerr << "Parsing failed\n";
    }
    
    return res;
}
