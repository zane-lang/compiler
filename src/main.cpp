#include "ast/nodes.hpp"
#include "parser.tab.h"
#include <iostream>
#include <string>
#include <fstream>

int yylex(yy::Parser::semantic_type* yylval, yy::Parser::location_type*, 
	const char*& cursor, const char*& marker, const char* limit);

std::string readFile(const std::string& path) {
    std::ifstream file(path);
    if (!file.is_open())
        throw std::runtime_error("Could not open file: " + path);

    return std::string((std::istreambuf_iterator<char>(file)),
                        std::istreambuf_iterator<char>());
}

int main(int argc, char** argv) {
	std::string input = readFile("test-parser/main.zn");
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
