#pragma once

#include "ast/ast_helpers.hpp"
#include "ast/symbol_collector.hpp"
#include "ir/node.hpp"
#include "ir/nodes.hpp"
#include "parser/ZaneParser.h"
#include "utils/aliases.hpp"
#include "utils/console.hpp"
#include "utils/types.hpp"

#include <antlr4-runtime.h>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <tree/ParseTree.h>
#include <unordered_set>
#include <vector>
#include <zane-cpp.hpp>

using namespace parser;

class Visitor : public CustomZaneVisitor {
	std::shared_ptr<ir::GlobalScope> globalScope;
	std::unordered_set<std::string> builtinSymbols;
	Stack<std::map<std::string, std::shared_ptr<ir::ValueSymbol>>> scopeSymbols;
	zane::ref<SymbolCollector> symbolCollector;
	std::string packageName;

	std::shared_ptr<ir::Type> makeConceptType(const std::string& name) {
		auto typeSymbol = std::make_shared<ir::TypeSymbol>();
		typeSymbol->packageName = "@concepts";
		typeSymbol->name = name;
		return std::make_shared<ir::Type>(typeSymbol);
	}

	std::vector<std::shared_ptr<ir::IRNode>> collectArguments(
			ZaneParser::CollectionContext* ctx) {
		std::vector<std::shared_ptr<ir::IRNode>> args;
		if (!ctx) {
			return args;
		}

		for (auto valueCtx : ctx->value()) {
			args.push_back(get<ir::IRNode>(valueCtx));
		}

		return args;
	}

	std::shared_ptr<ir::FuncType> buildFuncType(
			std::shared_ptr<ir::Type> returnType,
			ZaneParser::AbortClauseContext* abortClause,
			ZaneParser::ParamsContext* params,
			bool isMutable) {
		auto funcType = std::make_shared<ir::FuncType>();
		funcType->returnType = std::move(returnType);
		funcType->isMutable = isMutable;

		if (abortClause) {
			funcType->abortType = get<ir::Type>(abortClause->type());
		}

		if (!params) {
			return funcType;
		}

		for (auto paramCtx : params->param()) {
			if (paramCtx->receiver) {
				funcType->hasReceiver = true;
				funcType->paramTypes.push_back(get<ir::Type>(paramCtx->receiverType));
				continue;
			}

			auto paramType = get<ir::Type>(paramCtx->type());
			if (paramCtx->refModifier()) {
				paramType->isRef = true;
			}
			funcType->paramTypes.push_back(paramType);
		}

		return funcType;
	}

	void pushFunctionParameters(
			ZaneParser::ParamsContext* params,
			std::shared_ptr<ir::FuncDef> funcDef,
			std::shared_ptr<ir::FuncType> funcType) {
		scopeSymbols.push({});

		if (!params) {
			return;
		}

		for (auto paramCtx : params->param()) {
			auto paramSymbol = std::make_shared<ir::ValueSymbol>();
			if (paramCtx->receiver) {
				paramSymbol->name = "this";
				paramSymbol->type = get<ir::Type>(paramCtx->receiverType);
				funcDef->parameters.push_back("this");
				funcType->hasReceiver = true;
			} else {
				paramSymbol->name = paramCtx->name->getText();
				paramSymbol->type = get<ir::Type>(paramCtx->type());
				if (paramCtx->refModifier()) {
					paramSymbol->type->isRef = true;
				}
				funcDef->parameters.push_back(paramSymbol->name);
			}
			scopeSymbols.top()[paramSymbol->name] = paramSymbol;
		}
	}

	std::shared_ptr<ir::Scope> buildScope(ZaneParser::FuncBodyContext* ctx) {
		if (!ctx) {
			return nullptr;
		}

		if (ctx->scope()) {
			return get<ir::Scope>(ctx->scope());
		}

		auto scope = std::make_shared<ir::Scope>();
		auto retStat = std::make_shared<ir::ReturnStatement>();
		retStat->value = get<ir::IRNode>(ctx->arrowFunction()->value());
		scope->statements.push_back(retStat);
		return scope;
	}

	std::shared_ptr<ir::FuncCall> makeCall(
			ir::CallKind kind,
			std::shared_ptr<ir::IRNode> callee,
			std::vector<std::shared_ptr<ir::IRNode>> arguments) {
		auto call = std::make_shared<ir::FuncCall>();
		call->kind = kind;
		call->callee = std::move(callee);
		call->arguments = std::move(arguments);

		if (kind == ir::CallKind::Constructor || kind == ir::CallKind::Subscript) {
			return call;
		}

		if (auto resolved = resolveOverload(call->callee, call->arguments)) {
			call->callee = resolved;
			resolveUntypedArgs(call, resolved);
		}

		return call;
	}

	std::shared_ptr<ir::IRNode> buildOperatorCall(
			const std::string& op,
			std::vector<std::shared_ptr<ir::IRNode>> arguments) {
		auto callee = std::make_shared<ir::ValueSymbol>();
		callee->name = op;
		return makeCall(ir::CallKind::Operator, callee, std::move(arguments));
	}

	std::shared_ptr<ir::IRNode> appendPipeArgument(
			std::shared_ptr<ir::IRNode> left,
			std::shared_ptr<ir::IRNode> right) {
		if (auto existingCall = std::dynamic_pointer_cast<ir::FuncCall>(left)) {
			existingCall->arguments.push_back(right);
			existingCall->kind = ir::CallKind::Pipe;
			if (auto resolved = resolveOverload(existingCall->callee, existingCall->arguments)) {
				existingCall->callee = resolved;
				resolveUntypedArgs(existingCall, resolved);
			}
			return existingCall;
		}

		return makeCall(ir::CallKind::Pipe, left, { right });
	}

	std::any visitGlobalScope(ZaneParser::GlobalScopeContext *ctx) override {
		globalScope->packageName = ctx->pkgDef()->name->getText();

		for (auto decl : ctx->declaration()) {
			if (decl->varDef()) {
				globalScope->body.push_back(get<ir::VarDef>(decl->varDef()));
			} else if (decl->funcDef()) {
				globalScope->body.push_back(get<ir::FuncDef>(decl->funcDef()));
			} else if (decl->ctorDef()) {
				globalScope->body.push_back(get<ir::FuncDef>(decl->ctorDef()));
			}
		}

		return std::static_pointer_cast<ir::IRNode>(globalScope);
	}

	std::any visitRetStat(ZaneParser::RetStatContext *ctx) override {
		auto retStat = std::make_shared<ir::ReturnStatement>();
		retStat->value = get<ir::IRNode>(ctx->value());
		return std::static_pointer_cast<ir::IRNode>(retStat);
	}

	std::any visitFuncDef(ZaneParser::FuncDefContext *ctx) override {
		auto funcDef = std::make_shared<ir::FuncDef>();
		funcDef->symbol = std::make_shared<ir::ValueSymbol>();
		funcDef->symbol->name = ctx->name->getText();
		funcDef->symbol->packageName = packageName;

		auto funcType = buildFuncType(
			get<ir::Type>(ctx->returnType),
			ctx->abortClause(),
			ctx->params(),
			ctx->methodMut() != nullptr);

		pushFunctionParameters(ctx->params(), funcDef, funcType);
		funcDef->scope = buildScope(ctx->funcBody());
		scopeSymbols.pop();

		funcDef->symbol->type = std::make_shared<ir::Type>(funcType);
		funcDef->type = funcType;

		return std::static_pointer_cast<ir::IRNode>(funcDef);
	}

	std::any visitCtorDef(ZaneParser::CtorDefContext *ctx) override {
		auto funcDef = std::make_shared<ir::FuncDef>();
		funcDef->symbol = std::make_shared<ir::ValueSymbol>();
		funcDef->symbol->name = ctx->name->getText();
		funcDef->symbol->packageName = packageName;

		auto returnTypeSymbol = std::make_shared<ir::TypeSymbol>();
		returnTypeSymbol->name = ctx->name->getText();
		returnTypeSymbol->packageName = packageName;
		auto funcType = buildFuncType(
			std::make_shared<ir::Type>(returnTypeSymbol),
			nullptr,
			ctx->params(),
			false);

		pushFunctionParameters(ctx->params(), funcDef, funcType);
		funcDef->scope = buildScope(ctx->funcBody());
		scopeSymbols.pop();

		funcDef->symbol->type = std::make_shared<ir::Type>(funcType);
		funcDef->type = funcType;

		return std::static_pointer_cast<ir::IRNode>(funcDef);
	}

	std::any visitVarDef(ZaneParser::VarDefContext *ctx) override {
		auto symbol = std::make_shared<ir::ValueSymbol>();
		symbol->name = ctx->name->getText();
		symbol->type = get<ir::Type>(ctx->storageType());

		if (scopeSymbols.empty()) {
			symbol->packageName = packageName;
		} else {
			scopeSymbols.top()[symbol->name] = symbol;
		}

		auto varDef = std::make_shared<ir::VarDef>();
		varDef->symbol = symbol;

		if (ctx->varInitializer()) {
			if (ctx->varInitializer()->value()) {
				varDef->value = get<ir::IRNode>(ctx->varInitializer()->value());
			} else if (ctx->varInitializer()->ctorInit()) {
				auto ctorCall = std::make_shared<ir::FuncCall>();
				ctorCall->kind = ir::CallKind::Constructor;
				ctorCall->callee = std::make_shared<ir::TypeSymbol>();
				symbol->type->value.match([&](std::shared_ptr<ir::TypeSymbol> typeSymbol) {
					auto callee = std::make_shared<ir::TypeSymbol>();
					*callee = *typeSymbol;
					ctorCall->callee = callee;
				});
				ctorCall->arguments = collectArguments(ctx->varInitializer()->ctorInit()->collection());
				varDef->value = ctorCall;
			}
		}

		return std::static_pointer_cast<ir::IRNode>(varDef);
	}

	std::any visitValue(ZaneParser::ValueContext *ctx) override {
		return visit(ctx->comparisonExpr());
	}

	std::any visitComparisonExpr(ZaneParser::ComparisonExprContext *ctx) override {
		auto left = get<ir::IRNode>(ctx->additiveExpr(0));
		if (!ctx->comparisonOperator()) {
			return std::static_pointer_cast<ir::IRNode>(left);
		}

		auto right = get<ir::IRNode>(ctx->additiveExpr(1));
		return buildOperatorCall(
			ctx->comparisonOperator()->getText(),
			{ left, right });
	}

	std::any visitAdditiveExpr(ZaneParser::AdditiveExprContext *ctx) override {
		auto current = get<ir::IRNode>(ctx->multiplicativeExpr(0));
		for (size_t i = 1; i < ctx->multiplicativeExpr().size(); ++i) {
			current = buildOperatorCall(
				ctx->additiveOperator(i - 1)->getText(),
				{ current, get<ir::IRNode>(ctx->multiplicativeExpr(i)) });
		}
		return current;
	}

	std::any visitMultiplicativeExpr(ZaneParser::MultiplicativeExprContext *ctx) override {
		auto current = get<ir::IRNode>(ctx->pipeExpr(0));
		for (size_t i = 1; i < ctx->pipeExpr().size(); ++i) {
			current = buildOperatorCall(
				ctx->multiplicativeOperator(i - 1)->getText(),
				{ current, get<ir::IRNode>(ctx->pipeExpr(i)) });
		}
		return current;
	}

	std::any visitPipeExpr(ZaneParser::PipeExprContext *ctx) override {
		auto current = get<ir::IRNode>(ctx->unaryExpr(0));
		for (size_t i = 1; i < ctx->unaryExpr().size(); ++i) {
			current = appendPipeArgument(current, get<ir::IRNode>(ctx->unaryExpr(i)));
		}
		return current;
	}

	std::any visitUnaryExpr(ZaneParser::UnaryExprContext *ctx) override {
		if (ctx->postfixExpr()) {
			return visit(ctx->postfixExpr());
		}

		auto operand = get<ir::IRNode>(ctx->unaryExpr());
		return buildOperatorCall("~", { operand });
	}

	std::any visitPostfixExpr(ZaneParser::PostfixExprContext *ctx) override {
		std::shared_ptr<ir::IRNode> current = get<ir::IRNode>(ctx->atom());
		if (!current) {
			return {};
		}

		for (auto suffixCtx : ctx->postfixSuffix()) {
			if (auto funcCallCtx = dynamic_cast<ZaneParser::FuncCallSuffixContext*>(suffixCtx)) {
				auto kind = std::dynamic_pointer_cast<ir::TypeSymbol>(current)
					? ir::CallKind::Constructor
					: ir::CallKind::Free;
				current = makeCall(
					kind,
					current,
					collectArguments(funcCallCtx->collection()));
			} else if (auto methodCtx = dynamic_cast<ZaneParser::MethodCallSuffixContext*>(suffixCtx)) {
				auto args = collectArguments(methodCtx->collection());
				args.insert(args.begin(), current);
				current = makeCall(
					ir::CallKind::Method,
					get<ir::IRNode>(methodCtx->methodName),
					std::move(args));
			} else if (auto mutatingCtx = dynamic_cast<ZaneParser::MutatingMethodCallSuffixContext*>(suffixCtx)) {
				auto args = collectArguments(mutatingCtx->collection());
				args.insert(args.begin(), current);
				current = makeCall(
					ir::CallKind::MutatingMethod,
					get<ir::IRNode>(mutatingCtx->methodName),
					std::move(args));
			} else if (auto subscriptCtx = dynamic_cast<ZaneParser::SubscriptSuffixContext*>(suffixCtx)) {
				current = makeCall(
					ir::CallKind::Subscript,
					current,
					collectArguments(subscriptCtx->collection()));
			}
		}

		return std::static_pointer_cast<ir::IRNode>(current);
	}

	std::any visitLambda(ZaneParser::LambdaContext *ctx) override {
		static int lambdaCounter = 0;

		auto lambda = std::make_shared<ir::Lambda>();
		lambda->name = "__lambda_" + std::to_string(lambdaCounter++);
		lambda->isMutable = ctx->methodMut() != nullptr;

		if (ctx->lambdaParams()) {
			for (auto param : ctx->lambdaParams()->lambdaParam()) {
				if (param->receiver) {
					lambda->hasReceiver = true;
					lambda->parameters.push_back("this");
				} else {
					lambda->parameters.push_back(param->name->getText());
				}
			}
		}

		lambda->ctx = ctx;
		return std::static_pointer_cast<ir::IRNode>(lambda);
	}

	std::shared_ptr<ir::FuncDef> makeFuncDefFromLambda(std::shared_ptr<ir::Lambda> lambda) {
		auto funcDef = std::make_shared<ir::FuncDef>();
		funcDef->symbol = std::make_shared<ir::ValueSymbol>();
		funcDef->symbol->name = lambda->name;
		funcDef->symbol->packageName = packageName;
		funcDef->symbol->type = std::make_shared<ir::Type>(lambda->type);
		funcDef->type = lambda->type;
		funcDef->parameters = lambda->parameters;
		funcDef->scope = lambda->scope;
		return funcDef;
	}

	void resolveFuncArg(std::shared_ptr<ir::IRNode> arg, std::shared_ptr<ir::Type> expectedType) {
		if (auto lambda = std::dynamic_pointer_cast<ir::Lambda>(arg)) {
			expectedType->value.match([&](std::shared_ptr<ir::FuncType> expectedFt) {
				lambda->type = expectedFt;

				scopeSymbols.push({});
				for (size_t i = 0; i < lambda->parameters.size(); ++i) {
					if (i >= expectedFt->paramTypes.size()) {
						break;
					}
					auto paramSym = std::make_shared<ir::ValueSymbol>();
					paramSym->name = lambda->parameters[i];
					paramSym->type = expectedFt->paramTypes[i];
					scopeSymbols.top()[paramSym->name] = paramSym;
				}

				lambda->scope = buildScope(lambda->ctx->funcBody());
				scopeSymbols.pop();

				globalScope->body.push_back(makeFuncDefFromLambda(lambda));

				auto symbol = std::make_shared<ir::ValueSymbol>();
				symbol->name = lambda->name;
				symbol->packageName = packageName;
				symbol->type = std::make_shared<ir::Type>(expectedFt);
				symbolCollector->getPackageInfo()->symbols[symbol->getMangledName()] = symbol;
			});
			return;
		}

		if (auto sym = std::dynamic_pointer_cast<ir::ValueSymbol>(arg)) {
			expectedType->value.match([&](std::shared_ptr<ir::FuncType> expectedFt) {
				auto packageInfo = symbolCollector->getPackageInfo();
				for (auto& [key, symbol] : packageInfo->symbols) {
					if (symbol->name != sym->name) continue;
					symbol->type->value.match([&](std::shared_ptr<ir::FuncType> candidateFt) {
						if (*candidateFt == *expectedFt) *sym = *symbol;
					});
				}
			});
		}
	}

	void resolveUntypedArgs(std::shared_ptr<ir::FuncCall> funcCall, std::shared_ptr<ir::ValueSymbol> resolved) {
		resolved->type->value.match([&](std::shared_ptr<ir::FuncType> ft) {
			for (size_t i = 0; i < funcCall->arguments.size(); ++i) {
				if (i >= ft->paramTypes.size()) break;
				auto arg = funcCall->arguments[i];
				auto sym = std::dynamic_pointer_cast<ir::ValueSymbol>(arg);
				auto lambda = std::dynamic_pointer_cast<ir::Lambda>(arg);
				if ((sym && !sym->type) || lambda) {
					resolveFuncArg(arg, ft->paramTypes[i]);
				}
			}
		});
	}

	std::shared_ptr<ir::Type> getNodeType(
			std::shared_ptr<ir::IRNode> node,
			std::shared_ptr<ir::Type> expectedType = nullptr) {
		if (auto lambda = std::dynamic_pointer_cast<ir::Lambda>(node)) {
			auto ft = std::make_shared<ir::FuncType>();
			ft->hasReceiver = lambda->hasReceiver;
			ft->isMutable = lambda->isMutable;
			return std::make_shared<ir::Type>(ft);
		}

		if (auto sym = std::dynamic_pointer_cast<ir::ValueSymbol>(node)) {
			if (sym->type) return sym->type;
			if (expectedType) {
				auto packageInfo = symbolCollector->getPackageInfo();
				for (auto& [key, symbol] : packageInfo->symbols) {
					if (symbol->name == sym->name &&
						symbol->type->getMangledName() == expectedType->getMangledName()) {
						return symbol->type;
					}
				}
			}
			return nullptr;
		}

		if (std::dynamic_pointer_cast<ir::StringLiteral>(node)) {
			return makeConceptType("Text");
		}

		if (std::dynamic_pointer_cast<ir::NumberLiteral>(node)) {
			return makeConceptType("Number");
		}

		if (std::dynamic_pointer_cast<ir::TupleLiteral>(node)) {
			return makeConceptType("Tuple");
		}

		if (auto funcCall = std::dynamic_pointer_cast<ir::FuncCall>(node)) {
			if (auto callee = std::dynamic_pointer_cast<ir::ValueSymbol>(funcCall->callee)) {
				if (callee->type) {
					std::shared_ptr<ir::Type> retType;
					callee->type->value.match([&](std::shared_ptr<ir::FuncType> ft) {
						retType = ft->returnType;
					});
					return retType;
				}
			}
		}

		return nullptr;
	}

	std::shared_ptr<ir::PackageInfo> getPackageInfo(const std::string& pkgName) {
		return symbolCollector->getPackageInfo(pkgName);
	}

	std::shared_ptr<ir::ValueSymbol> resolveOverload(
			std::shared_ptr<ir::IRNode> calleeNode,
			const std::vector<std::shared_ptr<ir::IRNode>>& args) {
		auto sym = std::dynamic_pointer_cast<ir::ValueSymbol>(calleeNode);
		if (!sym) return nullptr;

		std::vector<std::shared_ptr<ir::ValueSymbol>> candidates;
		auto searchIn = [&](std::shared_ptr<ir::PackageInfo> info) {
			if (!info) return;
			for (auto& [key, symbol] : info->symbols) {
				if (symbol->name == sym->name) candidates.push_back(symbol);
			}
		};

		if (sym->packageName.has_value()) {
			searchIn(getPackageInfo(sym->packageName.value()));
		} else {
			searchIn(symbolCollector->getPackageInfo());
		}

		for (auto& candidate : candidates) {
			std::shared_ptr<ir::FuncType> funcType;
			candidate->type->value.match([&](std::shared_ptr<ir::FuncType> ft) {
				funcType = ft;
			});
			if (!funcType || funcType->paramTypes.size() != args.size()) continue;

			bool match = true;
			for (size_t i = 0; i < args.size(); ++i) {
				auto argType = getNodeType(args[i], funcType->paramTypes[i]);
				if (!argType) {
					match = false;
					break;
				}
				if (argType->getMangledName() != funcType->paramTypes[i]->getMangledName()) {
					match = false;
					break;
				}
			}
			if (match) return candidate;
		}

		return nullptr;
	}

	std::any visitValueSymbol(ZaneParser::ValueSymbolContext *ctx) override {
		auto name = ctx->name->getText();

		if (!ctx->package) {
			for (auto it = scopeSymbols.rbegin(); it != scopeSymbols.rend(); ++it) {
				auto found = it->find(name);
				if (found != it->end()) {
					return std::static_pointer_cast<ir::IRNode>(found->second);
				}
			}
		}

		std::shared_ptr<ir::PackageInfo> searchInfo;
		if (ctx->package) {
			searchInfo = getPackageInfo(ctx->package->getText());
		}
		if (!searchInfo) {
			searchInfo = symbolCollector->getPackageInfo();
		}

		std::vector<std::shared_ptr<ir::ValueSymbol>> candidates;
		for (auto& [key, symbol] : searchInfo->symbols) {
			if (symbol->name == name) candidates.push_back(symbol);
		}

		if (candidates.size() == 1) {
			return std::static_pointer_cast<ir::IRNode>(candidates[0]);
		}

		auto symbol = std::make_shared<ir::ValueSymbol>();
		symbol->name = name;
		if (ctx->package) symbol->packageName = ctx->package->getText();

		if (!candidates.empty()) {
			return std::static_pointer_cast<ir::IRNode>(symbol);
		}

		return std::static_pointer_cast<ir::IRNode>(symbol);
	}

	std::any visitString(ZaneParser::StringContext *ctx) override {
		auto stringLit = std::make_shared<ir::StringLiteral>();
		std::string text = ctx->STRING()->getText();

		if (text.length() >= 2 && text.front() == '"' && text.back() == '"') {
			stringLit->value = text.substr(1, text.length() - 2);
		} else {
			stringLit->value = text;
		}
		return std::static_pointer_cast<ir::IRNode>(stringLit);
	}

	std::any visitNumber(ZaneParser::NumberContext *ctx) override {
		auto numberLit = std::make_shared<ir::NumberLiteral>();
		numberLit->value = ctx->NUMBER()->getText();
		return std::static_pointer_cast<ir::IRNode>(numberLit);
	}

	std::any visitTuple(ZaneParser::TupleContext *ctx) override {
		auto tuple = std::make_shared<ir::TupleLiteral>();
		tuple->values = collectArguments(ctx->collection());
		return std::static_pointer_cast<ir::IRNode>(tuple);
	}

	void processStatement(ZaneParser::StatementContext *statement, std::shared_ptr<ir::Scope> scope) {
		auto irNode = toIRNode<ir::IRNode>(visitChildren(statement));
		if (irNode) {
			scope->statements.push_back(irNode);
		}
	}

	std::any visitScope(ZaneParser::ScopeContext *ctx) override {
		auto scope = std::make_shared<ir::Scope>();

		for (auto statement : ctx->statement()) {
			processStatement(statement, scope);
		}

		return std::static_pointer_cast<ir::IRNode>(scope);
	}

	std::any visitStatement(ZaneParser::StatementContext *ctx) override {
		return visitChildren(ctx);
	}

public:
	Visitor(zane::ref<SymbolCollector> symbolCollector)
			: globalScope(std::make_shared<ir::GlobalScope>())
			, symbolCollector(symbolCollector) {
		builtinSymbols = utils::getBuiltinSymbols();
	}

	void buildTree(parser::ZaneParser::GlobalScopeContext* globalScopeCtx) {
		if (!globalScopeCtx) {
			throw std::runtime_error("Global scope context is null");
		}

		packageName = globalScopeCtx->pkgDef()->name->getText();
		visit(globalScopeCtx);
	}

	std::shared_ptr<ir::GlobalScope> getGlobalScope() {
		return globalScope;
	}
};
