#pragma once

#include "ir/node.hpp"
#include "ir/nodes.hpp"
#include "parser/ZaneBaseVisitor.h"
#include "parser/ZaneParser.h"

#include <antlr4-runtime.h>
#include <memory>
#include <stdexcept>
#include <string>
#include <tree/ParseTree.h>
#include <utils/embedded_types.hpp>
#include <vector>

using namespace parser;

class CustomZaneVisitor : public ZaneBaseVisitor {
protected:
	template<typename T>
	std::shared_ptr<T> toIRNode(const std::any& result) {
		if (!result.has_value()) return nullptr;

		if (result.type() == typeid(std::shared_ptr<T>)) {
			return std::any_cast<std::shared_ptr<T>>(result);
		}

		if (result.type() == typeid(std::shared_ptr<ir::IRNode>)) {
			auto base = std::any_cast<std::shared_ptr<ir::IRNode>>(result);
			return std::dynamic_pointer_cast<T>(base);
		}

		std::string expectedType = typeid(std::shared_ptr<T>).name();
		std::string actualType = result.type().name();

		throw std::runtime_error(
			"IR Type Mismatch!\n"
			"  Expected: " + expectedType + "\n"
			"  Actual:   " + actualType + "\n"
		);
	}

	template<typename T>
	std::shared_ptr<T> get(antlr4::tree::ParseTree* tree) {
		return toIRNode<T>(visit(tree));
	}

	std::shared_ptr<ir::Type> buildType(
			ZaneParser::TypePrimaryContext* primary,
			bool isRef) {
		auto type = std::make_shared<ir::Type>();
		type->isRef = isRef;
		auto typeSymbolCtx = primary->typeSymbol();

		if (typeSymbolCtx) {
			type->value = { get<ir::TypeSymbol>(typeSymbolCtx) };
		} else if (primary->funcType()) {
			type->value = { get<ir::FuncType>(primary->funcType()) };
		}

		if (typeSymbolCtx) {
			for (auto generic : primary->type()) {
				type->value.match([&](ir::TypeSymbol& typeSymbol) {
					typeSymbol.generics.push_back(get<ir::Type>(generic));
				});
			}
		}

		return type;
	}

public:
	std::any visitTypeSymbol(ZaneParser::TypeSymbolContext *ctx) override {
		auto typeSymbol = std::make_shared<ir::TypeSymbol>();
		typeSymbol->name = ctx->name->getText();

		if (ctx->package) {
			typeSymbol->packageName = ctx->package->getText();
		}

		return std::static_pointer_cast<ir::IRNode>(typeSymbol);
	}

	std::any visitFuncType(ZaneParser::FuncTypeContext *ctx) override {
		auto funcType = std::make_shared<ir::FuncType>();
		funcType->returnType = get<ir::Type>(ctx->returnType);

		if (ctx->abortClause()) {
			funcType->abortType = get<ir::Type>(ctx->abortClause()->type());
		}

		funcType->isMutable = ctx->methodMut() != nullptr;

		if (ctx->funcTypeParams()) {
			for (auto paramCtx : ctx->funcTypeParams()->funcTypeParam()) {
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
		}

		return std::static_pointer_cast<ir::IRNode>(funcType);
	}

	std::any visitType(ZaneParser::TypeContext *ctx) override {
		auto type = buildType(ctx->typePrimary(), ctx->refModifier() != nullptr);
		return std::static_pointer_cast<ir::IRNode>(type);
	}

	std::any visitStorageType(ZaneParser::StorageTypeContext *ctx) override {
		auto type = buildType(ctx->typePrimary(), ctx->refModifier() != nullptr);
		return std::static_pointer_cast<ir::IRNode>(type);
	}
};
