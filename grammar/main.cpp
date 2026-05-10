#include <fstream>
#include <iostream>
#include <memory>
#include <parser.hpp>
#include <sstream>
#include <string>

#include "ast.hpp"
#include "lexer.hpp"

static std::string readFile(const std::string& path) {
	std::ifstream input(path);
	if (!input) {
		throw std::runtime_error("failed to open " + path);
	}

	std::ostringstream buffer;
	buffer << input.rdbuf();
	return buffer.str();
}

int main(int argc, char** argv) {
	if (argc != 2) {
		std::cerr << "usage: zane-parser <file>\n";
		return 1;
	}

	try {
		std::string source = readFile(argv[1]);
		zane::Lexer lexer(std::move(source));
		lexer.reset();
		zane::Node* root = nullptr;

		if (yyparse(&lexer, &root) != 0 || root == nullptr) {
			std::cerr << "parse failed\n";
			return 1;
		}

		std::unique_ptr<zane::Node> tree(root);
		zane::printNode(tree.get(), std::cout);
		std::cout << '\n';
		return 0;
	} catch (const std::exception& error) {
		std::cerr << error.what() << '\n';
		return 1;
	}
}
