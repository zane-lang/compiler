#include "package/parser_context.hpp"

#include "ast/ast_helpers.hpp"
#include "ast.hpp"
#include "lexer.hpp"

#include <parser.hpp>
#include <sstream>

namespace {

std::string getPackageNameFromTree(const zane::Node* root) {
	return ast::declaredPackageName(root);
}

} // namespace

ParserContext::ParserContext(const std::string& src)
	: source(src) {
	zane::Lexer lexer(source);
	lexer.reset();
	zane::Node* root = nullptr;

	if (yyparse(&lexer, &root) == 0 && root != nullptr) {
		tree.reset(root);

		std::ostringstream output;
		zane::printNode(tree.get(), output);
		astJson = output.str();
		packageName = getPackageNameFromTree(tree.get());
	}
	else if (root != nullptr) {
		delete root;
	}
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
