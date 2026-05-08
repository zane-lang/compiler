#include "package/parser_context.hpp"

#include "ast/ast_helpers.hpp"
#include "ast.hpp"
#include "lexer.hpp"

#include <parser.hpp>
#include <sstream>

int yyparse();
extern zane::Node* g_root;

namespace {

std::string getPackageNameFromTree(const zane::Node* root) {
	return ast::declaredPackageName(root);
}

} // namespace

ParserContext::ParserContext(const std::string& src)
	: source(src) {
	zane::Lexer lexer(source);
	lexer.reset();
	zane::g_lexer = &lexer;
	g_root = nullptr;

	if (yyparse() == 0 && g_root != nullptr) {
		tree.reset(g_root);
		g_root = nullptr;

		std::ostringstream output;
		zane::printNode(tree.get(), output);
		astJson = output.str();
		packageName = getPackageNameFromTree(tree.get());
	}
	else if (g_root != nullptr) {
		delete g_root;
		g_root = nullptr;
	}

	zane::g_lexer = nullptr;
}

ParserContext::~ParserContext() = default;

const zane::Node* ParserContext::getTree() const {
	return tree.get();
}

bool ParserContext::hasTree() const {
	return tree != nullptr;
}

const std::string& ParserContext::getAstJson() const {
	return astJson;
}

const std::string& ParserContext::getPackageName() const {
	return packageName;
}
