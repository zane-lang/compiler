#include "src/ast/.hpp"
#include "parser.tab.h"
#include <iostream>
#include <string>
#include <fstream>
#include <variant>

int yylex(yy::Parser::semantic_type* yylval, yy::Parser::location_type*, 
	const char*& cursor, const char*& marker, const char* limit,
	ast::nodes::Program*& ast);

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
	ast::nodes::Program* ast = nullptr;
	
	yy::Parser parser(cursor, marker, limit, ast);
	int res = parser.parse();
	
	if (ast != nullptr) {
		std::cout << std::visit(ast::evaluators::ToString {}, ast->valueNode->data);
		delete ast;
	}
	
	return res;
}
