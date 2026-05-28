#include "ast/.hpp"
#include "glr.h"
#include "grammar/lexer.hpp"
#include "zane_parser.h"
#include <fstream>
#include <iostream>
#include <string>

std::string readFile(const std::string& path) {
	std::ifstream file(path);
	if (!file.is_open())
		throw std::runtime_error("Could not open file: " + path);
	return std::string((std::istreambuf_iterator<char>(file)),
	                    std::istreambuf_iterator<char>());
}

int main() {
	const std::string inputPath = "test-parser/main.zn";
	std::string input = readFile(inputPath);
	Lexer lexer(inputPath, input);
	Lexer::nextToken(&lexer);

	ZaneParser parser;
	GLR glr(&parser, parser.makeTables());
	glr.noisyFailedParse = false;

	SemanticValue result = NULL_SVAL;
	const bool success = glr.glrParse(lexer, result);
	if (!success) {
		lexer.reportParseError();
		return 1;
	}

	auto* ast = reinterpret_cast<ast::nodes::Package*>(result);

	if (ast != nullptr) {
		std::cout << (ast::evaluators::ToGraph {}(*ast)).render();
		delete ast;
	}

	return 0;
}
