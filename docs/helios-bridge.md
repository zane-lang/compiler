# Helios Bridge Architecture

## Overview
This document describes the fundamental architectural shift in how Zane concepts and generics are lowered to LLVM IR. The system replaces traditional runtime library linking and string-based IR generation with a direct, in-memory LLVM object generation model. Helios transitions from a standalone C library to an integrated set of C++ template generators that construct LLVM types, functions, and values on-demand during compilation.

## Problem Statement
The previous approach of lowering concepts to C representations or external processes introduced several systemic limitations:
- **Generic Instantiation Limits:** C-based runtimes struggle to generate specialized versions of generic types without complex macros or runtime reflection.
- **Type Fragmentation:** Disconnected compilation units risk type identity mismatches and hinder compiler optimizations.

## Core Design Principles
1. **Direct In-Memory Generation:** Template functions return live LLVM objects (`llvm::Type*`, `llvm::Function*`, `llvm::Value*`) directly, eliminating text serialization and parsing.
2. **Unified `LLVMContext`:** All generated types and functions share a single LLVM context per compilation unit, guaranteeing type identity and enabling seamless cross-reference.
3. **On-Demand Monomorphization:** Generics are specialized only when concretely used in source code, with results aggressively cached to avoid redundant generation.
4. **Zero-Cost Abstractions:** Generic resolution and specialization occur entirely at compile time, introducing no runtime overhead or dynamic dispatch.
5. **Native C++ Integration:** Helios logic is reimplemented as a library of compile-time generators tightly coupled with the compiler's backend, enabling direct debugging and compile-time type safety.

## Abstract Component Architecture
The system is organized around four conceptual components:

| Component | Architectural Role |
|-----------|-------------------|
| **Template Registry** | Maps generic type signatures to their instantiation logic. Acts as the dispatch center that routes type requests to the appropriate generator. |
| **Monomorphization Cache** | Stores previously instantiated types and functions keyed by their concrete signatures. Prevents duplicate generation and ensures consistent IR reuse. |
| **Type & Concept Mapper** | Resolves high-level language concepts to concrete primitives. Orchestrates the flow between compiler inference and the registry/cache system. |
| **Helios Generator Library** | A collection of C++ functions that implement the structural and functional logic of Helios primitives (e.g., `List<T>`, `Option<T>`) directly via the LLVM C++ API. |

## Logical Workflow (Example: `[1, 2]`)
1. **Type Inference:** The compiler infers `List<IntLiteral>` from the source literal.
2. **Concept Resolution:** `IntLiteral` resolves to a concrete primitive (e.g., `I64`), yielding the target type `List<I64>`.
3. **Cache Lookup:** The system checks if `List<I64>` has already been generated in the monomorphization cache.
4. **Template Instantiation:** If uncached, the registry dispatches to the corresponding C++ generator, which constructs the LLVM struct and associated methods (e.g., `push`, `get`) in memory.
5. **Caching & Reuse:** Generated objects are stored in the cache for future references across the same compilation unit.
6. **Direct IR Integration:** The compiler immediately consumes the returned LLVM objects in ongoing code generation, with no intermediate parsing, linking, or context switching.

## Design Benefits & Trade-offs
- **Performance:** Eliminates string parsing, external process spawning, and linker symbol resolution. Initial compilation cost is amortized through caching, making subsequent instantiations near-instant.
- **Type Safety & Debugging:** Compile-time checking of generator logic, direct debugging via standard C++ tooling, and predictable naming conventions for instantiated types (e.g., `List$I64$push`).
- **Maintainability:** Single language codebase for the entire compiler stack. Generators scale naturally: adding new generics requires only registering a new template, without modifying core codegen paths.
- **Trade-off:** Slightly increased memory usage during compilation due to cached IR objects. This is intentionally bounded by the scope of a single compilation unit and offset by faster overall codegen throughput.

## Migration & Integration Strategy
- **Deprecate External Linking:** Remove standalone Helios C library targets and string-based IR generation paths.
- **Embed Generators:** Integrate template logic directly into the compiler's source tree under a dedicated namespace/module.
- **Environment Alignment:** Ensure LLVM version parity between the main compiler and any standalone generator development workflows to prevent ABI mismatches.
- **Phased Rollout:** Incrementally migrate core primitives, validate through integration and performance benchmarks, and gradually remove legacy compilation steps.

## Conclusion
The Helios Bridge architecture provides a robust, performant, and maintainable foundation for handling generics and concepts in Zane. By leveraging direct in-memory LLVM object generation, unified compilation contexts, and on-demand monomorphization, the system eliminates legacy overhead while enabling zero-cost abstractions and tighter compiler integration.
