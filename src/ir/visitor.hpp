#pragma once

#include <any>

namespace ir {

struct IRNode;
struct Node;
struct FuncType;
struct Type;
struct ValueSymbol;
struct TypeSymbol;

class IRVisitor {
public:
	virtual ~IRVisitor() = default;
	virtual std::any visit(IRNode* node);

	virtual std::any visitType(Type*) { return {}; }
	virtual std::any visitFuncType(FuncType*) { return {}; }
	virtual std::any visitValueSymbol(ValueSymbol*) { return {}; }
	virtual std::any visitTypeSymbol(TypeSymbol*) { return {}; }
	virtual std::any visitNode(Node*) { return {}; }
};

} // namespace ir
