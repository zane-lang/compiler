(* A description of each intrinsic, keyed by its spelling, which the
   language server shows on hover and with a completion item
   (docs/design/language-server.md D17). An intrinsic has no source, so no
   `///` comment can precede its declaration; this table stands in for
   those comments. Each spelling the catalogue of [Intrinsics] lists has an
   entry here, and a unit test (tests/unit/unit.ml) checks that the two lists
   match.

   The text is Markdown. A description states what a program gets from the
   intrinsic and cites the spec section that defines it. A description of a
   name with several overloads covers every overload. *)

let namespaces =
  [
    ( "@primitives$",
      "The storage primitives: the scalars, the byte, strings, arrays, lists and worker pools every other type is \
       built over, with their constructors and methods (types.md §2.7)." );
    ( "@concepts$",
      "The compiler concept types: the types of source literals and of block arguments. A concept is never \
       stored; only a parameter has a concept type (syntax.md §2.8)." );
    ( "@operators$",
      "The machine operations the operators of `core` are written over, one overload per primitive operand \
       type (operators.md §2.6)." );
    ("@math$", "The math functions on the scalar primitives, one overload per scalar each function takes (math.md §2).");
    ( "@controlflow$",
      "The control-flow intrinsics: branching, repetition, leaving an invocation, and running a worker \
       (control-flow.md §4)." );
    ("@runtime$", "The types of the program's console and runtime, and their methods (effects.md §6.6).");
    ( "@program$",
      "The console and the runtime of the running program. Only the root package and exported lambdas reach \
       this namespace; they pass them to other packages as arguments (effects.md §6.6, packages.md §8.4)." );
  ]

let types =
  [
    ( "@primitives$U8",
      "The byte primitive: an unsigned byte from 0 to 255. It converts to and from the integer scalars and \
       compares, and has no arithmetic (syntax.md §2.7, types.md §2.9)." );
    ( "@primitives$I32",
      "A 32-bit signed integer. Its constructors build one from an integer literal, exactly from `@primitives$U8`, \
       and by name from wider values: `wrap` keeps an `I64`'s low bits, `truncate` drops a float's fraction \
       (types.md §2.7, §2.9)." );
    ( "@primitives$I64",
      "A 64-bit signed integer, the storage of `core`'s `Int`. Its constructors build one from an integer literal, \
       exactly from `I32` and `U8`, and from a float with `truncate` (types.md §2.7, §2.9)." );
    ( "@primitives$F32",
      "A 32-bit IEEE 754 float. Its constructors build one from a float literal and, with `round`, from `F64`, \
       `I32` or `I64`, taking the nearest value it holds (types.md §2.7, §2.9)." );
    ( "@primitives$F64",
      "A 64-bit IEEE 754 float, the storage of `core`'s `Float`. Its constructors build one from a float literal, \
       exactly from `F32` and `I32`, and from `I64` with `round` (types.md §2.7, §2.9)." );
    ( "@primitives$Bool",
      "A truth value, the type of a condition `@controlflow$branch` takes. `@operators$conjoin`, `disjoin` and \
       `not` combine truth values (types.md §2.7)." );
    ("@primitives$Unit", "The type with a single value, which a verb that returns nothing returns (types.md §2.7).");
    ( "@primitives$String",
      "The storage behind `core`'s `String`: a value type whose handle owns its bytes, so a copy owns bytes of its \
       own. It is built from a string literal, from a scalar's text, or with `escaped` (types.md §2.7, §2.11)." );
    ( "@primitives$Array",
      "A fixed-length value array of `n` elements of `T`, built from an array literal (generics.md §8.1)." );
    ( "@primitives$ArrayRef",
      "A fixed-length array as a reference type, whose elements are fixed storage. It is built from an array \
       literal, with `refs` or `roaming` for the mode its elements are passed in, or with `fill` (generics.md \
       §8.4)." );
    ( "@primitives$List",
      "A dynamically sized list of `T` as a value type, copied whole. It is a handle to one block of elements \
       (generics.md §8.3)." );
    ( "@primitives$ListRef",
      "A dynamically sized list of `T` as a reference type, whose elements are owners. It is a handle to one \
       block of elements (generics.md §8.5)." );
    ( "@primitives$ByteSet",
      "A set of bytes, made by `byteSet` from 256 flags and searched for with `findAny` and `findPair`. It is a \
       value type, and a copy owns a set of its own (types.md §2.12)." );
    ( "@primitives$WorkerPool",
      "A worker pool over elements of `T`, with shared state `S` and the events `E` its steps publish to the \
       funnel. A reference type, which only a scope's local or an owner's field holds (concurrency.md §6.1)." );
    ( "@primitives$EventSource",
      "A worker's event source: a timer that is ready each time its interval has passed. Build one with \
       `@primitives$EventSource.every` (concurrency.md §6.3)." );
    ( "@runtime$Console",
      "The program's console, reached as `@program$console`. Its method `print` writes text (effects.md §6.6)." );
    ( "@runtime$Runtime",
      "The program's runtime, reached as `@program$runtime`: the size of its thread pool and the program's \
       arguments (effects.md §6.6, concurrency.md §2.2)." );
    ( "@concepts$Int",
      "The type of an integer literal, a single value known at compile time. As a parameter's type it also \
       marks a number parameter, as in `n @concepts$Int` (syntax.md §2.8, generics.md §3)." );
    ("@concepts$Float", "The type of a float literal, a single value known at compile time (syntax.md §2.8).");
    ( "@concepts$String",
      "The type of a string literal: its text fragments and the `@primitives$String` values interpolated into \
       it. The interpolated values may be known only at run time (types.md §2.8)." );
    ( "@concepts$Array",
      "`@concepts$Array<T, n>`, the type of an array literal of `n` elements of type `T` (syntax.md §2.8)." );
    ( "@concepts$Map",
      "`@concepts$Map<K, V>`, the type of a map literal whose keys have type `K` and values type `V` (syntax.md \
       §2.8)." );
    ( "@concepts$Block",
      "The type of a block argument: a braced run of statements the callee executes. A block is never a value, \
       and a verb that takes one is expanded at its call site (control-flow.md §2)." );
  ]

let values =
  [
    ("@program$console", "The running program's console, a `@runtime$Console` (effects.md §6.6).");
    ("@program$runtime", "The running program's runtime, a `@runtime$Runtime` (effects.md §6.6).");
  ]

let control_flow =
  [
    ( "@controlflow$branch",
      "Executes `body` when `condition` is true, and does nothing otherwise. A program writes the other case as \
       `branch` on the complement (control-flow.md §4.1)." );
    ( "@controlflow$repeat",
      "Executes `body` exactly `count` times; a `count` below 1 executes it zero times (control-flow.md §4.1)." );
    ( "@controlflow$exitFromCall",
      "Ends the invocation that called the verb whose body contains this call. Control does not resume after \
       that call site (control-flow.md §4.2)." );
    ( "@controlflow$work",
      "Runs a worker: calls `step` on the subject, and again each time its result is true, until it is false. \
       A program calls it as `subject!@controlflow$work(step)` (control-flow.md §4.1)." );
    ( "@controlflow$register",
      "Runs a worker as `work` does, but calls `step` again only once `source` is ready, and waits for it in \
       between. A program calls it as `subject!@controlflow$register(source, step)` (control-flow.md §4.1, \
       concurrency.md §6.3)." );
  ]

let operators =
  [
    ("@operators$add", "The sum of two values of one scalar type (operators.md §2.6).");
    ("@operators$multiply", "The product of two values of one scalar type (operators.md §2.6).");
    ( "@operators$divide",
      "The quotient of two values of one scalar type. An integer quotient rounds toward zero, and an integer \
       division by zero gives zero (operators.md §2.6)." );
    ( "@operators$equal",
      "Whether two values of one primitive type are equal. Every scalar, `Bool`, `U8` and `String` has an \
       overload (operators.md §2.6)." );
    ("@operators$lessThan", "Whether the left value is less than the right, both of one scalar type or `U8` (operators.md §2.6).");
    ( "@operators$negate",
      "The value with its sign flipped. There is no subtraction: `a - b` is `a + ~b` (operators.md §4.2)." );
    ("@operators$conjoin", "True when both truth values are true; `core`'s `and` (operators.md §2.6).");
    ("@operators$disjoin", "True when either truth value is true; `core`'s `or` (operators.md §2.6).");
    ("@operators$not", "The opposite truth value (operators.md §2.6).");
    ("@operators$concat", "The text of `left` followed by the text of `right` (operators.md §2.6).");
  ]

let math =
  let m name text = ("@math$" ^ name, text ^ " (math.md §2).") in
  [
    m "bitAnd" "Each bit set where it is set in both operands";
    m "bitOr" "Each bit set where it is set in either operand";
    m "bitXor" "Each bit set where it is set in exactly one operand";
    m "bitNot" "Every bit of the operand flipped";
    m "shiftLeft" "The bits moved `count` places toward the most significant end, zeros filling in";
    m "shiftRight"
      "The bits moved `count` places toward the least significant end, copies of the sign bit filling in. It \
       divides by a power of two, rounding toward negative infinity";
    m "shiftRightLogical"
      "The bits moved `count` places toward the least significant end, zeros filling in, as for an unsigned value";
    m "rotateLeft" "The bits moved `count` places toward the most significant end, those moved out filling in at the other end";
    m "rotateRight" "The bits moved `count` places toward the least significant end, those moved out filling in at the other end";
    m "popCount" "The number of set bits";
    m "leadingZeros" "The number of zero bits above the most significant set bit";
    m "trailingZeros" "The number of zero bits below the least significant set bit";
    m "abs" "The operand's magnitude. On a float, the operand with its sign bit cleared";
    m "min" "The lesser operand. On floats, IEEE 754's *minimum*";
    m "max" "The greater operand. On floats, IEEE 754's *maximum*";
    m "sqrt" "The square root";
    m "floor" "The greatest integer not above the operand";
    m "ceil" "The least integer not below the operand";
    m "trunc" "The operand rounded toward zero to an integer";
    m "roundEven" "The nearest integer, a tie going to the even one";
    m "fma" "`left * right + addend`, rounded once";
    m "copySign" "`magnitude` with the sign of `sign`";
    m "cbrt" "The cube root";
    m "sin" "The sine of an angle in radians";
    m "cos" "The cosine of an angle in radians";
    m "tan" "The tangent of an angle in radians";
    m "asin" "The arcsine, in radians";
    m "acos" "The arccosine, in radians";
    m "atan" "The arctangent, in radians";
    m "atan2" "The angle in radians, from `-π` to `π`, of the point `(x, y)`";
    m "exp" "`e` raised to the operand";
    m "log" "The natural logarithm";
    m "pow" "`base` raised to `exponent`";
    m "hypot" "`sqrt(x * x + y * y)`, without overflow or underflow in between";
  ]

let methods =
  [
    ("@runtime$print", "Writes `text` to the console (effects.md §6.6).");
    ( "@runtime$setThreads",
      "Sizes the runtime's thread pool to `count` threads. A `count` below 1 aborts the call and leaves the pool \
       as it was (concurrency.md §2.2)." );
    ("@runtime$setThreadsAuto", "Sizes the runtime's thread pool to the hardware's concurrency again (concurrency.md §2.2).");
    ("@runtime$arguments", "The arguments the program was started with (effects.md §6.6).");
    ( "@primitives$parseI64",
      "The integer the string's text spells. The call aborts when the text is not an integer (types.md §2.10)." );
    ( "@primitives$parseF64",
      "The number the string's text spells. The call aborts when the text is not a number (types.md §2.10)." );
    ( "@primitives$parseF64At",
      "`parseF64` on the `count` bytes from byte `start`, counted from 1 as `byteAt` counts. The call aborts \
       when those bytes are not a number (types.md §2.10)." );
    ("@primitives$byteCount", "The string's length in bytes (types.md §2.12).");
    ("@primitives$byteAt", "The byte at `index`, counted from 1 (types.md §2.12).");
    ( "@primitives$hashBytes",
      "A hash of the string's bytes, the same for equal strings within one run of the program (types.md §2.12)." );
    ("@primitives$text", "A string whose bytes are the list's elements, in order (generics.md §8.6).");
    ( "@primitives$byteSet",
      "The set of the bytes whose flags are true: byte `b`'s flag is at position `b + 1` of the 256 (types.md \
       §2.12)." );
    ( "@primitives$findPair",
      "The first of the `count` positions from `from`, counted from 1, whose byte is in the set `first` and the \
       byte `gap` after it in `second`, or 0 when no position matches (types.md §2.12)." );
    ( "@primitives$findAny",
      "The first of the `count` positions from `from`, counted from 1, whose byte is in `set`, or 0 when no \
       position matches (types.md §2.12)." );
    ( "@primitives$appendRange",
      "Copies `count` elements of the list `from`, starting at its element `start`, onto the end of this list, \
       as one copy. Only for elements that own no blocks (generics.md §8.6)." );
    ( "@primitives$appendOwn",
      "Copies `count` of this list's own elements, starting at element `start`, onto its end, as one copy. Only \
       for elements that own no blocks (generics.md §8.6)." );
    ( "@primitives$copyRange",
      "Copies `count` elements of the list `from`, starting at its element `start`, over this list's elements \
       from `at`, as one copy. Only for elements that own no blocks (generics.md §8.6)." );
    ( "@primitives$sortBy",
      "Sorts a list of `I32` indices into the list `keys` stably, by the `I64` key each index names \
       (generics.md §8.6)." );
    ("@primitives$sort", "Sorts a list of integers in place, ascending (generics.md §8.6).");
    ( "@primitives$sameRange",
      "Whether `count` elements of this list from `start` equal `count` elements of `other` from `otherStart` \
       (generics.md §8.6)." );
    ( "@primitives$hashRange",
      "A hash of `count` elements from `start`, the same for equal ranges within one run of the program \
       (generics.md §8.6)." );
    ( "@primitives$push",
      "Adds `value` at the end of the list, taken through a `^T` parameter: an owner moves in, and a value \
       is copied in (generics.md §8.6)." );
    ("@primitives$size", "The number of elements in the list (generics.md §8.6).");
    ( "@primitives$remove",
      "Moves the element at `index` out of the list. The later elements shift down and keep their order \
       (generics.md §8.6, lifetimes.md §2.1)." );
    ( "@primitives$swapRemove",
      "Moves the element at `index` out of the list, and moves the last element into its place (generics.md \
       §8.6, lifetimes.md §2.1)." );
    ( "@primitives$start",
      "Adds `element` to the pool as a worker and returns at once; the element moves in. The worker calls `step` \
       on the element concurrently with the caller, with a snapshot of the pool's state and a function that \
       publishes an event to the funnel, until `step` returns false. An overload takes `sources`, and calls \
       `step` again only once a source is ready (concurrency.md §6.2)." );
    ( "@primitives$startOn",
      "`start` with event sources: the worker calls `step` again only once one of `sources` is ready \
       (concurrency.md §6.2, §6.3)." );
    ( "@primitives$startAlone",
      "`start` on a pool without state: `step` receives only its element (concurrency.md §6.2)." );
    ( "@primitives$startAloneOn",
      "`start` on a pool without state, with event sources: `step` receives only its element, and runs again only \
       once one of `sources` is ready (concurrency.md §6.2, §6.3)." );
    ("@primitives$state", "A snapshot of the pool's shared state (concurrency.md §6.6).");
    ( "@primitives$elements",
      "A list holding a snapshot of each element of the pool. Each element is coherent on its own; the list as a \
       whole is not one snapshot (concurrency.md §6.6)." );
  ]

let constructors =
  [
    ("@primitives$U8.wrap", "The low 8 bits of an integer, as a byte (types.md §2.9).");
    ("@primitives$I32.wrap", "The low 32 bits of an `I64` (types.md §2.9).");
    ( "@primitives$I32.truncate",
      "A float with its fraction dropped. The program stops when the remaining integer does not fit in an `I32` \
       (types.md §2.9)." );
    ( "@primitives$I64.truncate",
      "A float with its fraction dropped. The program stops when the remaining integer does not fit in an `I64` \
       (types.md §2.9)." );
    ("@primitives$F32.round", "The `F32` nearest to the value (types.md §2.9).");
    ("@primitives$F64.round", "The `F64` nearest to an `I64` (types.md §2.9).");
    ( "@primitives$String.escaped",
      "The literal with its text escapes read. Only the literal's own text is read for escapes, never a value \
       interpolated into it (types.md §2.7)." );
    ( "@primitives$ArrayRef.refs",
      "An `ArrayRef` of references, built from an array literal: a settled owner mints a reference, and an `&` \
       value is copied (generics.md §8.4)." );
    ( "@primitives$ArrayRef.roaming",
      "An `ArrayRef` built from an array literal of roaming owners, each of which moves in (generics.md §8.4)." );
    ( "@primitives$ArrayRef.fill",
      "An `ArrayRef` of `n` elements, each built by calling `make` once per position, in order, with the position \
       counted from 1 (generics.md §8.4)." );
    ( "@primitives$EventSource.every",
      "A timer, ready each time `interval` nanoseconds have passed since it was last ready, and always when the \
       interval is below 1 (concurrency.md §6.3)." );
  ]

let hidden =
  [
    ("@primitives$[]", "The element at `index` of an array or list, counted from 1; an index outside it stops the program (generics.md §8.6).");
    ( "@primitives$publish",
      "Sends an event to the funnel of the pool whose worker is running. A step reaches it through the publish \
       function it receives (concurrency.md §6.5)." );
  ]

let all = namespaces @ types @ values @ control_flow @ operators @ math @ methods @ constructors @ hidden

let find spelling = List.assoc_opt spelling all
