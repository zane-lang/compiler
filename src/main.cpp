#include "src/ast/.hpp"
#include "ast/evaluators/to_string.hpp"
#include "parser.tab.h"
#include <iostream>
#include <string>
#include <fstream>
#include <variant>

int yylex(yy::Parser::semantic_type* yylval, yy::Parser::location_type*, 
	const char*& cursor, const char*& marker, const char* limit,
	ast::nodes::ValueNode*& result);

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
	ast::nodes::ValueNode* result = nullptr;
	
	yy::Parser parser(cursor, marker, limit, result);
	int res = parser.parse();
	
	if (result != nullptr) {
		std::cout << std::visit(ast::evaluators::ToString{}, result->data);
		delete result;
	}
	
	return res;
}
