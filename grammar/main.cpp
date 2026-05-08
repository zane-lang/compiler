#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>

#include "ast.hpp"
#include "lexer.hpp"

int yyparse();
extern zane::Node* g_root;

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
zane::g_lexer = &lexer;
g_root = nullptr;

if (yyparse() != 0 || g_root == nullptr) {
std::cerr << "parse failed\n";
return 1;
}

std::unique_ptr<zane::Node> root(g_root);
g_root = nullptr;
zane::printNode(root.get(), std::cout);
std::cout << '\n';
return 0;
} catch (const std::exception& error) {
std::cerr << error.what() << '\n';
return 1;
}
}
