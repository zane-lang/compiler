#pragma once

#include <any>

namespace ir {

struct IRNode;
struct Node;
struct FuncDef;
struct VarDef;
struct GlobalScope;
struct Scope;
struct FuncCall;
struct StringLiteral;
struct FuncType;
struct ReturnStatement;
struct Type;
struct ValueSymbol;
struct TypeSymbol;
struct Lambda;

class IRVisitor {
public:
	virtual ~IRVisitor() = default;
	virtual std::any visit(IRNode* node);

	virtual std::any visitFuncDef(FuncDef*) { return {}; }
	virtual std::any visitGlobalScope(GlobalScope*) { return {}; }
	virtual std::any visitScope(Scope*) { return {}; }
	virtual std::any visitFuncCall(FuncCall*) { return {}; }
	virtual std::any visitStringLiteral(StringLiteral*) { return {}; }
	virtual std::any visitType(Type*) { return {}; }
	virtual std::any visitFuncType(FuncType*) { return {}; }
	virtual std::any visitVarDef(VarDef*) { return {}; }
	virtual std::any visitReturnStatement(ReturnStatement*) { return {}; }
	virtual std::any visitValueSymbol(ValueSymbol*) { return {}; }
	virtual std::any visitTypeSymbol(TypeSymbol*) { return {}; }
	virtual std::any visitLambda(Lambda*) { return {}; }
	virtual std::any visitNode(Node*) { return {}; }
};

} // namespace ir
