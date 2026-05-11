# Concepts vs Primitives Architecture

## Core Philosophy

The Zane compiler maintains a strict separation between **Concepts** (source-level abstractions) and **Primitives** (codegen-level implementations). This split enables high-level generic programming while ensuring zero-cost code generation.

## The Split

### Concepts (`@Concepts$...`)
- **Role**: Read-only structural representations in the AST and type system
- **Lifetime**: Exist only during parsing, type checking, and semantic analysis
- **Purpose**:
  - Provide user-friendly generic abstractions
  - Enable type safety checks (e.g., preventing invalid operations)
  - Generate clear, high-level error messages
  - Represent intent rather than implementation

### Primitives (`@Primitives$...`)
- **Role**: Concrete LLVM IR types and functions
- **Lifetime**: Exist during lowering and code generation
- **Purpose**:
  - Map directly to machine representations
  - Serve as the sole input to the Helios template engine
  - Enable optimized, monomorphized code generation

## Resolution Strategy

Unlike traditional generic systems that require complex monomorphization passes, Zane uses a **direct 1:1 mapping**:

1. **Definition**: Each Concept maps to exactly one concrete Primitive type
   - `@Concepts$Int` → `@Primitives$I64` (or target-specific integer)
   - `@Concepts$Float` → `@Primitives$F64`
   - `@Concepts$List<T>` → `@Primitives$List<ResolvedPrimitive>`

2. **Resolution Timing**: Types are resolved immediately when symbols are encountered
   - No deferred resolution or complex constraint solving
   - The concrete type is known as soon as type checking completes

3. **Lowering Flow**:
   ```
   Source Code: var x = input  // input: @Concepts$Int
       ↓ (Type Checking)
   AST: VarDecl(x, ConceptType("Int"))
       ↓ (Resolution)
   Lowered: VarDecl(x, PrimitiveType("I64"))
       ↓ (Helios Bridge)
   LLVM: %x = alloca i64
   ```

## Benefits

### For Users
- Write clean, generic code: `fn process<T where T: Int>(val: T)`
- Receive understandable error messages referencing concepts, not internal primitives
- Enjoy type safety without performance penalties

### For Compiler Implementation
- **Simplicity**: No need for complex template instantiation logic in Helios
- **Performance**: Direct mapping eliminates runtime dispatch overhead
- **Maintainability**: Clear separation between frontend (concepts) and backend (primitives)
- **Extensibility**: Easy to add new concepts without modifying Helios, as long as they map to existing primitives

## Example Usage

```zane
// User writes generic code with concepts
fn add<T where T: Int>(a: T, b: T) -> T {
    return a + b
}

// Compiler resolves during type checking
// add(@Concepts$Int, @Concepts$Int) -> @Concepts$Int
// becomes
// add(@Primitives$I64, @Primitives$I64) -> @Primitives$I64

// Helios receives only primitives and generates optimized LLVM IR
```

## Implementation Notes

- **No Runtime Overhead**: Concepts are fully erased before code generation
- **No String Intermediates**: Resolution happens via direct type pointer mapping in C++
- **LSP Support**: IDEs see concept types for better autocomplete and documentation
- **Future Proofing**: If a concept needs multiple primitive implementations later, the architecture supports extending the resolution logic without breaking existing code

## Key Takeaway

> **Concepts represent *what* the programmer means; Primitives represent *how* the machine executes it.**
>
> By resolving concepts to primitives early and deterministically, we achieve the simplicity of a non-generic language at the codegen level while retaining the expressiveness of generics at the source level.
