#pragma once

#include "ast/ast_helpers.hpp"
#include "codegen/type_mapper.hpp"
#include "compiler/intrinsics.hpp"
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
				&& child->kind.is<ir::node_kind::block_body, ir::node_kind::expr_body>()
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
			if (child != nullptr && child->kind.is<ir::node_kind::param_decl>()) {
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

	const intrinsics::IntrinsicInfo* resolveIntrinsic(const ir::Node* node) const {
		if (node == nullptr) {
			return nullptr;
		}

		return intrinsics::get().find(ast::flattenName(node));
	}

	const intrinsics::IntrinsicInfo* resolveIntrinsic(
			const std::shared_ptr<semantic::ValueSymbol>& funcSymbol) const {
		if (!funcSymbol) {
			return nullptr;
		}

		const auto tryLookup = [&](const std::string& name) -> const intrinsics::IntrinsicInfo* {
			if (name.empty()) {
				return nullptr;
			}

			if (const auto* intrinsic = intrinsics::get().find(name)) {
				return intrinsic;
			}

			auto signatureStart = name.find('(');
			if (signatureStart != std::string::npos) {
				return intrinsics::get().find(name.substr(0, signatureStart));
			}

			return nullptr;
		};

		if (const auto* intrinsic = tryLookup(funcSymbol->name)) {
			return intrinsic;
		}

		auto mangledName = funcSymbol->getMangledName();
		return tryLookup(mangledName);
	}

	llvm::Function* resolveFunctionByName(const ir::Node* node, std::size_t expectedArgCount, const std::string& directName = "") {
		std::string functionName = directName.empty() ? ast::flattenName(node) : directName;
		if (functionName.empty()) {
			return nullptr;
		}

		// Try direct module lookup first
		if (auto* function = module.getFunction(functionName)) {
			if (expectedArgCount == 0 || function->arg_size() == expectedArgCount) {
				return function;
			}
			DEBUG(
				"Function '" << functionName << "' exists with " << function->arg_size()
				<< " args, but call expected " << expectedArgCount);
			return nullptr;
		}

		// Try alias-based lookup
		auto it = functionsByAlias.find(functionName);
		if (it == functionsByAlias.end()) {
			return nullptr;
		}

		llvm::Function* match = nullptr;
		std::vector<std::string> ambiguousMatches;
		for (auto* function : it->second) {
			if (function != nullptr && (expectedArgCount == 0 || function->arg_size() == expectedArgCount)) {
				ambiguousMatches.push_back(function->getName().str());
				if (match != nullptr && match != function) {
					DEBUG(
						"Ambiguous function lookup for '" << functionName
						<< "' with " << expectedArgCount << " args: "
						<< ambiguousMatches[0] << " vs " << ambiguousMatches.back());
					return nullptr;
				}
				match = function;
			}
		}

		if (match == nullptr && expectedArgCount != 0) {
			DEBUG("No function overload for '" << functionName << "' with " << expectedArgCount << " args");
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

	llvm::Value* emitIntrinsicName(const ir::Node* node) {
		return resolveFunctionByName(node, 0);
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
				if (argumentNode->kind.is<ir::node_kind::named_arg, ir::node_kind::field_arg>()) {
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
		std::string calleeName = ast::flattenName(callee);

		if (calleeName == "@Compiler$stringFromStringLiteral" && args.size() == 1) {
			const auto* sourceNode = node->children.size() > 1 ? node->children[1] : nullptr;
			if (sourceNode != nullptr) {
				std::string literalConcept =
					intrinsics::get().conceptForLiteralNode(sourceNode->kind);
				(void)literalConcept;
			}
			return args.front();
		}

		if (const auto* intrinsic = intrinsics::get().find(calleeName)) {
			if (intrinsic->isFunction()
					&& intrinsic->loweringKind == intrinsics::LoweringKind::RuntimeFunction
					&& !intrinsic->runtimeSymbol.empty()) {
				if (auto* function =
						resolveFunctionByName(callee, args.size(), intrinsic->runtimeSymbol)) {
					auto* call = builder.CreateCall(function, args);
					call->setCallingConv(function->getCallingConv());
					return call;
				}
			}
		}

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

		if (node->kind.is<ir::node_kind::name>()) {
			return emitName(node);
		}

		if (node->kind.is<ir::node_kind::intrinsic_name>()) {
			return emitIntrinsicName(node);
		}

		if (node->kind.is<ir::node_kind::qualified_name>()) {
			return emitQualifiedName(node);
		}

		if (node->kind.is<ir::node_kind::string_literal>()) {
			return builder.CreateGlobalString(node->value);
		}

		if (node->kind.is<ir::node_kind::call_expr>()) {
			return emitCall(node);
		}

		if (node->kind.is<ir::node_kind::expression_stmt>()) {
			return emitNode(ast::childAt(node, 0));
		}

		return nullptr;
	}

	void emitSymbolDecl(const ir::Node* node) {
		const auto* storageDecl = ast::childAt(node, 0);
		if (storageDecl == nullptr || !storageDecl->kind.is<ir::node_kind::storage_decl>()) {
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
		const auto* initNode = ast::findChild(storageDecl, ir::node_kind::assign_init{});
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

		if (node->kind.is<ir::node_kind::return_stmt>()) {
			emitReturn(node);
			return;
		}

		if (node->kind.is<ir::node_kind::symbol_decl>()) {
			emitSymbolDecl(node);
			return;
		}

		(void)emitNode(node);
	}

	void emitBody(const ir::Node* body) {
		if (body == nullptr) {
			return;
		}

		if (body->kind.is<ir::node_kind::expr_body>()) {
			auto* value = emitNode(ast::childAt(body, 0));
			if (builder.GetInsertBlock()->getTerminator()) {
				return;
			}

			emitReturnValue(value);
			return;
		}

		if (!body->kind.is<ir::node_kind::block_body>()) {
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

	void declareIntrinsicSignatures() {
		for (const auto& [fullName, intrinsic] : intrinsics::get().all()) {
			(void)fullName;
			if (
				!intrinsic.isFunction()
				|| intrinsic.callableSymbol == nullptr
				|| intrinsic.loweringKind != intrinsics::LoweringKind::RuntimeFunction
			) {
				continue;
			}

			llvm::Type* returnType = nullptr;
			std::vector<llvm::Type*> params;
			bool supported = true;

			intrinsic.callableSymbol->type->value.match(
				[&](std::shared_ptr<semantic::FuncType> funcType) {
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
				}
			);

			if (!supported || returnType == nullptr || intrinsic.runtimeSymbol.empty()) {
				continue;
			}

			auto* function = module.getFunction(intrinsic.runtimeSymbol);
			if (function == nullptr) {
				auto* functionType = llvm::FunctionType::get(returnType, params, false);
				function = llvm::Function::Create(
					functionType,
					llvm::Function::ExternalLinkage,
					intrinsic.runtimeSymbol,
					module);
			}

			registerFunctionAliases(intrinsic.callableSymbol, function);
		}
	}

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
			if (child != nullptr && child->kind.is<ir::node_kind::function_decl>()) {
				emitFunction(child, package->getPackageInfo());
			}
		}
	}

private:
	void declareSignature(const std::shared_ptr<semantic::ValueSymbol>& funcSymbol) {
		if (!funcSymbol) {
			return;
		}

		if (const auto* intrinsic = resolveIntrinsic(funcSymbol)) {
			if (
				intrinsic->isFunction()
				&& intrinsic->loweringKind == intrinsics::LoweringKind::CompilerFunction
			) {
				return;
			}
		}
		else if (!funcSymbol->name.empty() && funcSymbol->name.front() == '@') {
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

		std::string llvmName = funcSymbol->getMangledName();
		if (const auto* intrinsic = resolveIntrinsic(funcSymbol)) {
			if (intrinsic->isFunction()
					&& intrinsic->loweringKind == intrinsics::LoweringKind::RuntimeFunction
					&& !intrinsic->runtimeSymbol.empty()) {
				llvmName = intrinsic->runtimeSymbol;
			}
		}

		llvm::Function* function = module.getFunction(llvmName);
		if (function == nullptr) {
			auto* functionType = llvm::FunctionType::get(returnType, params, false);
			function = llvm::Function::Create(
				functionType,
				llvm::Function::ExternalLinkage,
				llvmName,
				module);
		}

		registerFunctionAliases(funcSymbol, function);
	}
};
