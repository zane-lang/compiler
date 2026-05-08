#pragma once

#include <memory>
#include <string>

namespace zane {
	struct Node;
}

struct ParserContext {
	std::string source;
	std::unique_ptr<zane::Node> tree;
	std::string astJson;
	std::string packageName;

	ParserContext(const std::string& src);
	~ParserContext();

	const zane::Node* getTree() const;
	bool hasTree() const;
	const std::string& getAstJson() const;
	const std::string& getPackageName() const;
};
