#pragma once
#include <memory>
namespace ast {
	struct Node;
	using NodePtr = std::unique_ptr<Node>;
}
