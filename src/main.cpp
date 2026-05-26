#include "ast/.hpp"
#include "parser.tab.h"
#include <iostream>
#include <string>
#include <fstream>

int yylex(yy::Parser::semantic_type* yylval, yy::Parser::location_type* yylloc,
	const char*& cursor, const char*& marker, const char* limit,
	ast::nodes::Package*& ast, int& line, const char*& line_start);

std::string readFile(const std::string& path) {
	std::ifstream file(path);
	if (!file.is_open())
		throw std::runtime_error("Could not open file: " + path);
	return std::string((std::istreambuf_iterator<char>(file)),
	                    std::istreambuf_iterator<char>());
}

int main() {
	std::string input = readFile("test-parser/main.zn");

	const char* cursor     = input.c_str();
	const char* marker     = cursor;
	const char* limit      = cursor + input.size();
	const char* line_start = cursor;
	int line               = 1;
	ast::nodes::Package* ast = nullptr;

	yy::Parser parser(cursor, marker, limit, ast, line, line_start);
	int res = parser.parse();

	if (ast != nullptr) {
		std::cout << ast::evaluators::ToString{}(*ast) << '\n';
		delete ast;
	}

	return res;
}
