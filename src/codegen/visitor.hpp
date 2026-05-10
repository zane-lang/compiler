#pragma once

#include "ast/ast_helpers.hpp"
#include "codegen/type_mapper.hpp"
#include "package/package.hpp"
#include "utils/console.hpp"

#include <llvm/IR/Constants.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/IR/Module.h>
#include <llvm/IR/Type.h>
#include <algorithm>
#include <unordered_map>
#include <vector>

class LLVMVisitor {
private:
	static inline constexpr char packageAliasSeparator = '$';

	llvm::LLVMContext& context;
	llvm::IRBuilder<>& builder;
	llvm::Module& module;
	TypeMapper typeMapper;
	std::unordered_map<std::string, llvm::AllocaInst*> namedValues;
	std::unordered_map<std::string, std::vector<llvm::Function*>> functionsByAlias;

	llvm::Value* defaultValue(llvm::Type* type) {
		if (type == nullptr) {
			return nullptr;
		}

		return llvm::Constant::getNullValue(type);
	}

	llvm::Value* currentReturnFallback() {
		auto* block = builder.GetInsertBlock();
		if (block == nullptr) {
			return nullptr;
		}

		auto* function = block->getParent();
		if (function == nullptr || function->getReturnType()->isVoidTy()) {
			return nullptr;
		}

		return defaultValue(function->getReturnType());
	}

	void emitReturnValue(llvm::Value* value) {
		if (value != nullptr) {
			builder.CreateRet(value);
			return;
		}

		if (auto* fallback = currentReturnFallback()) {
			builder.CreateRet(fallback);
			return;
		}

		builder.CreateRetVoid();
	}

	const ir::Node* findCallableBody(const ir::Node* declaration) const {
		if (declaration == nullptr) {
			return nullptr;
		}

		for (const auto* child : declaration->children) {
			if (
				child != nullptr
				&& (child->kind == "block_body" || child->kind == "expr_body")
			) {
				return child;
			}
		}

		return nullptr;
	}

	std::vector<std::string> collectParameters(const ir::Node* declaration) const {
		std::vector<std::string> parameters;
		if (declaration == nullptr) {
			return parameters;
		}

		for (const auto* child : declaration->children) {
			if (child != nullptr && child->kind == "param_decl") {
				parameters.push_back(child->value);
			}
		}

		return parameters;
	}

	std::shared_ptr<semantic::ValueSymbol> resolveCallableSymbol(
			const ir::Node* declaration,
			const std::shared_ptr<semantic::PackageInfo>& packageInfo) const {
		if (packageInfo == nullptr) {
			return nullptr;
		}

		auto symbol = ast::makeCallableSymbol(declaration, packageInfo->packageName);
		if (!symbol) {
			return nullptr;
		}

		auto it = packageInfo->symbols.find(symbol->getMangledName());
		if (it != packageInfo->symbols.end()) {
			return it->second;
		}

		return symbol;
	}

	void registerFunctionAlias(const std::string& alias, llvm::Function* function) {
		if (alias.empty() || function == nullptr) {
			return;
		}

		auto& functions = functionsByAlias[alias];
		if (std::find(functions.begin(), functions.end(), function) == functions.end()) {
			functions.push_back(function);
		}
	}

	void registerFunctionAliases(
			const std::shared_ptr<semantic::ValueSymbol>& funcSymbol,
			llvm::Function* function) {
		if (!funcSymbol || function == nullptr) {
			return;
		}

		registerFunctionAlias(funcSymbol->getMangledName(), function);
		registerFunctionAlias(funcSymbol->name, function);

		if (funcSymbol->packageName.has_value()) {
			auto packageQualifiedName =
				funcSymbol->packageName.value() + packageAliasSeparator + funcSymbol->name;
			registerFunctionAlias(
				packageQualifiedName,
				function);
			registerFunctionAlias(
				semantic::getMangledPackageName(funcSymbol->packageName.value())
					+ packageAliasSeparator + funcSymbol->name,
				function);
		}
	}

	llvm::Function* resolveFunctionByName(
			const ir::Node* callee,
			std::size_t argumentCount) {
		if (callee == nullptr) {
			return nullptr;
		}

		auto flatName = ast::flattenName(callee);
		if (flatName.empty()) {
			return nullptr;
		}

		if (auto* function = module.getFunction(flatName)) {
			if (function->arg_size() == argumentCount) {
				return function;
			}
			DEBUG(
				"Function '" << flatName << "' exists with " << function->arg_size()
				<< " args, but call expected " << argumentCount);
			return nullptr;
		}

		auto it = functionsByAlias.find(flatName);
		if (it == functionsByAlias.end()) {
			return nullptr;
		}

		llvm::Function* match = nullptr;
		std::vector<std::string> ambiguousMatches;
		for (auto* function : it->second) {
			if (function != nullptr && function->arg_size() == argumentCount) {
				ambiguousMatches.push_back(function->getName().str());
				if (match != nullptr && match != function) {
					DEBUG(
						"Ambiguous function lookup for '" << flatName
						<< "' with " << argumentCount << " args: "
						<< ambiguousMatches[0] << " vs " << ambiguousMatches.back());
					return nullptr;
				}
				match = function;
			}
		}

		if (match == nullptr) {
			DEBUG("No function overload for '" << flatName << "' with " << argumentCount << " args");
		}

		return match;
	}

	llvm::Value* emitName(const ir::Node* node) {
		if (node == nullptr) {
			return nullptr;
		}

		auto it = namedValues.find(node->value);
		if (it != namedValues.end()) {
			return builder.CreateLoad(
				it->second->getAllocatedType(), it->second, node->value);
		}

		if (auto* function = resolveFunctionByName(node, 0)) {
			return function;
		}

		DEBUG("Unknown symbol: " << node->value);
		return nullptr;
	}

	llvm::Value* emitQualifiedName(const ir::Node* node) {
		return resolveFunctionByName(node, 0);
	}

	llvm::Value* emitCall(const ir::Node* node) {
		if (node == nullptr || node->children.empty()) {
			return nullptr;
		}

		std::vector<llvm::Value*> args;
		for (std::size_t index = 1; index < node->children.size(); ++index) {
			const auto* argumentNode = node->children[index];
			if (argumentNode != nullptr && !argumentNode->children.empty()) {
				if (argumentNode->kind == "named_arg" || argumentNode->kind == "field_arg") {
					argumentNode = argumentNode->children.front();
				}
			}

			auto* value = emitNode(argumentNode);
			if (value == nullptr) {
				return nullptr;
			}
			args.push_back(value);
		}

		const auto* callee = node->children.front();
		if (auto* function = resolveFunctionByName(callee, args.size())) {
			auto* call = builder.CreateCall(function, args);
			call->setCallingConv(function->getCallingConv());
			return call;
		}

		DEBUG("Unknown callee for: " << node->getNodeName());
		return nullptr;
	}

	llvm::Value* emitNode(const ir::Node* node) {
		if (node == nullptr) {
			return nullptr;
		}

		if (node->kind == "name") {
			return emitName(node);
		}

		if (node->kind == "qualified_name") {
			return emitQualifiedName(node);
		}

		if (node->kind == "string_literal") {
			return builder.CreateGlobalString(node->value);
		}

		if (node->kind == "call_expr") {
			return emitCall(node);
		}

		if (node->kind == "expression_stmt") {
			return emitNode(ast::childAt(node, 0));
		}

		return nullptr;
	}

	void emitSymbolDecl(const ir::Node* node) {
		const auto* storageDecl = ast::childAt(node, 0);
		if (storageDecl == nullptr || storageDecl->kind != "storage_decl") {
			return;
		}

		const std::string& varName = storageDecl->value;

		// Child at index 0 of storage_decl is always the type expression
		const auto* typeNode = ast::childAt(storageDecl, 0);
		std::string typeName = ast::flattenName(typeNode);

		llvm::Type* llvmType = typeMapper.toLLVMType(typeName);
		if (llvmType == nullptr) {
			DEBUG("Unknown type for local variable '" << varName << "': " << typeName);
			return;
		}

		auto* alloca = builder.CreateAlloca(llvmType, nullptr, varName);
		namedValues[varName] = alloca;

		// Handle assign_init node (e.g. `= expression`) for initialization
		const auto* initNode = ast::findChild(storageDecl, "assign_init");
		if (initNode != nullptr && !initNode->children.empty()) {
			auto* initValue = emitNode(initNode->children.front());
			if (initValue != nullptr) {
				builder.CreateStore(initValue, alloca);
			}
		}
	}

	void emitReturn(const ir::Node* node) {
		emitReturnValue(emitNode(ast::childAt(node, 0)));
	}

	void emitStatement(const ir::Node* node) {
		if (node == nullptr || builder.GetInsertBlock()->getTerminator()) {
			return;
		}

		if (node->kind == "return_stmt") {
			emitReturn(node);
			return;
		}

		if (node->kind == "symbol_decl") {
			emitSymbolDecl(node);
			return;
		}

		(void)emitNode(node);
	}

	void emitBody(const ir::Node* body) {
		if (body == nullptr) {
			return;
		}

		if (body->kind == "expr_body") {
			auto* value = emitNode(ast::childAt(body, 0));
			if (builder.GetInsertBlock()->getTerminator()) {
				return;
			}

			emitReturnValue(value);
			return;
		}

		if (body->kind != "block_body") {
			return;
		}

		const auto* block = ast::childAt(body, 0);
		if (block == nullptr) {
			return;
		}

		for (const auto* statement : block->children) {
			emitStatement(statement);
			if (builder.GetInsertBlock()->getTerminator()) {
				break;
			}
		}
	}

	void emitFunction(const ir::Node* declaration, const std::shared_ptr<semantic::PackageInfo>& packageInfo) {
		auto symbol = resolveCallableSymbol(declaration, packageInfo);
		if (!symbol) {
			return;
		}

		llvm::Function* function = module.getFunction(symbol->getMangledName());
		if (function == nullptr) {
			return;
		}

		auto parameters = collectParameters(declaration);
		if (function->arg_size() != parameters.size()) {
			DEBUG(
				"Parameter count mismatch for " << symbol->getMangledName()
				<< ": LLVM has " << function->arg_size()
				<< ", AST has " << parameters.size());
			return;
		}

		auto* entry = llvm::BasicBlock::Create(context, "entry", function);
		builder.SetInsertPoint(entry);
		namedValues.clear();

		std::size_t index = 0;
		for (auto& argument : function->args()) {
			const auto& name = parameters[index++];
			argument.setName(name);

			auto* alloca = builder.CreateAlloca(argument.getType(), nullptr, name);
			builder.CreateStore(&argument, alloca);
			namedValues[name] = alloca;
		}

		emitBody(findCallableBody(declaration));

		if (builder.GetInsertBlock()->getTerminator()) {
			return;
		}

		if (function->getReturnType()->isVoidTy()) {
			builder.CreateRetVoid();
			return;
		}

		builder.CreateRet(defaultValue(function->getReturnType()));
	}

public:
	LLVMVisitor(llvm::LLVMContext& ctx, llvm::IRBuilder<>& b, llvm::Module& m)
		: context(ctx), builder(b), module(m), typeMapper(ctx) {}

	void declareSignatures(zane::ref<Package> package) {
		declareSignatures(package->packageInfo);
	}

	void declareSignatures(const std::shared_ptr<semantic::PackageInfo>& packageInfo) {
		if (!packageInfo) {
			return;
		}

		for (const auto& [name, symbol] : packageInfo->symbols) {
			(void)name;
			declareSignature(symbol);
		}
	}

	void generateBodies(zane::ref<Package> package) {
		auto program = package->getIRProgram();
		if (!program) {
			return;
		}

		for (const auto* child : program->children) {
			if (child != nullptr && child->kind == "function_decl") {
				emitFunction(child, package->getPackageInfo());
			}
		}
	}

private:
	void declareSignature(const std::shared_ptr<semantic::ValueSymbol>& funcSymbol) {
		if (!funcSymbol) {
			return;
		}

		llvm::Type* returnType = nullptr;
		std::vector<llvm::Type*> params;
		bool supported = true;

		funcSymbol->type->value.match([&](std::shared_ptr<semantic::FuncType> funcType) {
			returnType = typeMapper.toLLVMType(funcType->returnType.get());
			if (returnType == nullptr) {
				supported = false;
				return;
			}

			for (auto& param : funcType->paramTypes) {
				auto* llvmType = typeMapper.toLLVMType(param.get());
				if (llvmType == nullptr) {
					supported = false;
					return;
				}
				params.push_back(llvmType);
			}
		});

		if (!supported || returnType == nullptr) {
			return;
		}

		llvm::Function* function = module.getFunction(funcSymbol->getMangledName());
		if (function == nullptr) {
			auto* functionType = llvm::FunctionType::get(returnType, params, false);
			function = llvm::Function::Create(
				functionType,
				llvm::Function::ExternalLinkage,
				funcSymbol->getMangledName(),
				module);
		}

		registerFunctionAliases(funcSymbol, function);
	}
};
