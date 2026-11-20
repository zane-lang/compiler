(* The intrinsic namespaces (syntax.md §2.7): what `@primitives$`,
   `@concepts$`, `@operators$`, `@math$`, `@controlflow$`, `@runtime$` and
   `@program$` hold.

   They are not packages, so they are not read from source. Most intrinsic
   operations have exactly one signature. The overloads the spec states are
   the exceptions: methods that share a name on different subjects, the
   machine operations of `@operators$` and the math functions of `@math$`,
   one per operand type, and a scalar's constructors, which take the scalar's
   concept and each scalar that converts into it exactly (syntax.md §2.7,
   types.md §2.7). No intrinsic is an operator:
   a primitive has no home package, so an operator over one is declared
   nowhere (operators.md §2.2).

   The spec names the intrinsics its examples need and leaves the rest of each
   namespace open. The intrinsics here beyond those are this compiler's
   choice, made so that `core` can be written over them: the element access on
   the container primitives and the runtime types' methods. Nothing in the
   checker names any of these intrinsics; they are data. *)

module S = Signature

type type_info = {
  namespace : string;
  name : string;
  params : Ty.kind list;
  reference : bool;
}

let types =
  let t ?(params = []) ?(reference = false) namespace name =
    { namespace; name; params; reference }
  in
  [
    (* EXPERIMENT (LangArena zane-vs-c): an unsigned byte, a storage type
       with no arithmetic of its own: it converts to and from the integers,
       and compares. *)
    t "primitives" "U8";
    t "primitives" "I32";
    t "primitives" "I64";
    t "primitives" "F32";
    t "primitives" "F64";
    t "primitives" "Bool";
    t "primitives" "Unit";
    (* The storage behind `core`'s `String`: a value type whose handle owns
       its bytes, so a copy owns bytes of its own (types.md §2.7). *)
    t "primitives" "String";
    t ~params:[ Ty.Type_kind; Ty.Number_kind ] "primitives" "Array";
    (* Array's layout as a reference type, whose elements are fixed storage
       (generics.md §8.4). *)
    t ~params:[ Ty.Type_kind; Ty.Number_kind ] ~reference:true "primitives" "ArrayRef";
    (* The dynamically sized counterparts (generics.md §8.3, §8.5): `List`
       a value type, which is copied whole, and `ListRef` a reference type,
       whose elements are owners. Both are a handle to one block. *)
    t ~params:[ Ty.Type_kind ] "primitives" "List";
    t ~params:[ Ty.Type_kind ] ~reference:true "primitives" "ListRef";
    t ~reference:true "runtime" "Console";
    t ~reference:true "runtime" "Runtime";
  ]

let find_type namespace name =
  List.find_opt (fun t -> t.namespace = namespace && t.name = name) types

let prim ?(args = []) name = Ty.Intrinsic { namespace = "primitives"; name; args }
let runtime name = Ty.Intrinsic { namespace = "runtime"; name; args = [] }

(* `@program$console` and `@program$runtime` (effects.md §6.6). *)
let values = [ ("program", "console", runtime "Console"); ("program", "runtime", runtime "Runtime") ]

let find_value namespace name =
  List.find_map
    (fun (ns, n, ty) -> if ns = namespace && n = name then Some ty else None)
    values

let param ?binds name ty = { S.name; ty; binds; has_default = false }

let verb ?(generics = []) ?(abort = None) ?(is_mut = false) ~namespace ~kind
    ~name ~spelling params ret =
  {
    S.owner = S.Intrinsic spelling;
    name;
    home = S.Namespace namespace;
    kind;
    generics;
    params;
    ret;
    abort;
    is_mut;
  }

let integers = [ "I32"; "I64" ]
let floats = [ "F32"; "F64" ]
let scalars = integers @ floats

(* The concept each scalar is built from (types.md §2.7): an integer from
   `@concepts$Int`, a float from `@concepts$Float`. *)
let concept s = if List.mem s floats then Ty.Decimal_lit else Ty.Integer_lit

(* An operator's token, which diagnostics and declaration names use. *)
let operator_token : Sst.Nodes.Operator.node -> string = function
  | Add -> "+"
  | Mul -> "*"
  | Div -> "/"
  | Eq -> "=="
  | Less -> "<"
  | And -> "and"
  | Or -> "or"

(* A flipped numeric literal is the literal of the opposite sign
   (operators.md §2.7), and no operator is called. [negated_digits] flips a
   literal's text; a literal parameter's text is known only where its verb is
   written out, so `~n` is a call to [negate_literal], which no program can
   name and lowering folds once it has the literal. *)
let negate_literal = "@concepts$negate"

let negated_digits s =
  if String.length s > 0 && s.[0] = '-' then String.sub s 1 (String.length s - 1) else "-" ^ s

(* `@operators$` (syntax.md §2.7): the machine operations the primitive
   operators of operators.md §2.1 are written over, one overload per operand
   type, both operands of that one type. There is no subtraction, since
   `a - b` is `a + ~b` (operators.md §4.2). `Bool` has its own three
   operations, named for what they do rather than for the operators `core`
   spells them with, and `String` has its join; equality is one operation on
   every type. *)
let operator_functions =
  let f name params ret =
    ( ("operators", name),
      verb ~namespace:"operators" ~kind:S.Function ~name:("@operators$" ^ name)
        ~spelling:("@operators$" ^ name) params ret )
  in
  let binary name operand ret = f name [ param "left" (prim operand); param "right" (prim operand) ] ret in
  List.concat_map
    (fun s ->
      [
        binary "add" s (prim s);
        binary "multiply" s (prim s);
        binary "divide" s (prim s);
        binary "equal" s (prim "Bool");
        binary "lessThan" s (prim "Bool");
        f "negate" [ param "value" (prim s) ] (prim s);
      ])
    scalars
  @ [
      binary "conjoin" "Bool" (prim "Bool");
      binary "disjoin" "Bool" (prim "Bool");
      f "not" [ param "value" (prim "Bool") ] (prim "Bool");
      binary "equal" "Bool" (prim "Bool");
      binary "equal" "U8" (prim "Bool");
      binary "lessThan" "U8" (prim "Bool");
      binary "concat" "String" (prim "String");
      binary "equal" "String" (prim "Bool");
    ]

(* The conversions between scalars (types.md §2.9), as the target, the name
   of the constructor that converts, and the source. A conversion that is
   exact for every value is a plain constructor; a conversion that can lose a
   value is named for how it loses it: `wrap` keeps an integer's low bits,
   `truncate` drops a float's fraction and stops the program when the
   remaining integer does not fit, and `round` takes the nearest value the
   target holds. *)
let conversions =
  [
    ("I64", None, "I32");
    ("I64", None, "U8");
    ("I32", None, "U8");
    ("U8", Some "wrap", "I64");
    ("U8", Some "wrap", "I32");
    ("F64", None, "F32");
    ("F64", None, "I32");
    ("I32", Some "wrap", "I64");
    ("I32", Some "truncate", "F32");
    ("I32", Some "truncate", "F64");
    ("I64", Some "truncate", "F32");
    ("I64", Some "truncate", "F64");
    ("F32", Some "round", "F64");
    ("F32", Some "round", "I32");
    ("F32", Some "round", "I64");
    ("F64", Some "round", "I64");
  ]

(* Constructors, keyed by the type they build. A storage primitive has a
   constructor from its concept, and a scalar has a constructor from each
   scalar it converts from (types.md §2.9). No intrinsic constructor is
   implicit: a concept becomes a primitive only where the constructor is
   written, or inside a type's own implicit conversion. *)
let constructors =
  let ctor ?(implicit = false) ?(generics = []) ?member name params ret =
    let spelling =
      "@primitives$" ^ name ^ match member with Some m -> "." ^ m | None -> ""
    in
    ( ("primitives", name),
      verb ~generics ~namespace:"primitives"
        ~kind:(S.Constructor { implicit; member; fields = false })
        ~name:spelling ~spelling params ret )
  in
  let element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  let length = Ty.fresh_param ~name:"n" ~kind:Ty.Number_kind in
  let list_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  let list_ref_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  let fixed name e n = prim name ~args:[ Ty.Type (Ty.Param e); Ty.Number (Ty.Number_param n) ] in
  let elements e n = Ty.Concept (Ty.Array_lit (Ty.Param e, Ty.Number_param n)) in
  let ref_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  let ref_length = Ty.fresh_param ~name:"n" ~kind:Ty.Number_kind in
  let refs_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  let refs_length = Ty.fresh_param ~name:"n" ~kind:Ty.Number_kind in
  let roaming_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  let roaming_length = Ty.fresh_param ~name:"n" ~kind:Ty.Number_kind in
  let moded mode e n = Ty.Concept (Ty.Array_lit (mode (Ty.Param e), Ty.Number_param n)) in
  let fill_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  let fill_length = Ty.fresh_param ~name:"n" ~kind:Ty.Number_kind in
  let fill_index = Ty.fresh_param ~name:"I" ~kind:Ty.Type_kind in
  List.map (fun s -> ctor s [ param "value" (Ty.Concept (concept s)) ] (prim s)) ("U8" :: scalars)
  @ List.map
      (fun (target, member, source) -> ctor ?member target [ param "value" (prim source) ] (prim target))
      conversions
  @ List.map
      (fun scalar -> ctor "String" [ param "value" (prim scalar) ] (prim "String"))
      scalars
  @ [
      ctor "String" [ param "value" (Ty.Concept Ty.Text_lit) ] (prim "String");
      (* The literal with its text escapes read (types.md §2.7): escapes are
         read only in its literal text, never in a value interpolated into
         it. *)
      ctor ~member:"escaped" "String" [ param "text" (Ty.Concept Ty.Text_lit) ] (prim "String");
      ctor "Unit" [] (prim "Unit");
      ctor ~generics:[ element; length ] "Array"
        [ param "values" (elements element length) ]
        (fixed "Array" element length);
      (* An `ArrayRef` is built from an array literal or by `fill`, which
         calls `make` once per position, in order, with the position counted
         from 1 (generics.md §8.4). A literal's elements are passed in the
         mode its constructor writes: `ArrayRef` borrows them, so each is a
         value or an `&` value, copied into its place; `ArrayRef.roaming`
         takes them, so an owner moves in; and `ArrayRef.refs` takes them as
         references, so a settled owner mints a reference and an `&` value
         is copied. *)
      ctor ~generics:[ ref_element; ref_length ] "ArrayRef"
        [ param "values" (elements ref_element ref_length) ]
        (fixed "ArrayRef" ref_element ref_length);
      ctor ~generics:[ refs_element; refs_length ] ~member:"refs" "ArrayRef"
        [ param "values" (moded (fun t -> Ty.Reference t) refs_element refs_length) ]
        (prim "ArrayRef"
           ~args:[ Ty.Type (Ty.Reference (Ty.Param refs_element)); Ty.Number (Ty.Number_param refs_length) ]);
      ctor ~generics:[ roaming_element; roaming_length ] ~member:"roaming" "ArrayRef"
        [ param "values" (moded (fun t -> Ty.Roaming t) roaming_element roaming_length) ]
        (fixed "ArrayRef" roaming_element roaming_length);
      (* `make` takes the position as an `I`: `@primitives$I64`, or a type
         with an implicit constructor from it, as a worker's step result
         reaches `@primitives$Bool` (generics.md §8.4). The last parameter,
         `index`, is the checker's: a lambda converting each position to an
         `I` (Check.fill_index). *)
      ctor ~generics:[ fill_element; fill_length; fill_index ] ~member:"fill" "ArrayRef"
        [
          param ~binds:fill_length "n" (Ty.Concept Ty.Integer_lit);
          param "make"
            (Ty.Verb
               {
                 Ty.this_ = None;
                 params = [ Ty.Param fill_index ];
                 ret = Ty.Roaming (Ty.Param fill_element);
                 abort = None;
                 is_mut = false;
               });
          param "index"
            (Ty.Verb
               { Ty.this_ = None; params = [ prim "I64" ]; ret = Ty.Param fill_index; abort = None; is_mut = false });
        ]
        (fixed "ArrayRef" fill_element fill_length);
      ctor ~generics:[ list_element ] "List"
        [ param ~binds:list_element "T" (Ty.Concept Ty.Type_value) ]
        (prim "List" ~args:[ Ty.Type (Ty.Param list_element) ]);
      ctor ~generics:[ list_ref_element ] "ListRef"
        [ param ~binds:list_ref_element "T" (Ty.Concept Ty.Type_value) ]
        (prim "ListRef" ~args:[ Ty.Type (Ty.Param list_ref_element) ]);
    ]

let subscripts =
  let element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  let length = Ty.fresh_param ~name:"n" ~kind:Ty.Number_kind in
  let ref_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  let ref_length = Ty.fresh_param ~name:"n" ~kind:Ty.Number_kind in
  let list_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  let list_ref_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  let subscript generics subject element =
    verb ~generics ~namespace:"primitives" ~kind:S.Subscript ~name:"[]"
      ~spelling:"@primitives$[]"
      [ param "this" subject; param "index" (prim "I64") ]
      element
  in
  [
    subscript [ element; length ]
      (prim "Array" ~args:[ Ty.Type (Ty.Param element); Ty.Number (Ty.Number_param length) ])
      (Ty.Param element);
    subscript [ ref_element; ref_length ]
      (prim "ArrayRef"
         ~args:[ Ty.Type (Ty.Param ref_element); Ty.Number (Ty.Number_param ref_length) ])
      (Ty.Param ref_element);
    subscript [ list_element ]
      (prim "List" ~args:[ Ty.Type (Ty.Param list_element) ])
      (Ty.Param list_element);
    subscript [ list_ref_element ]
      (prim "ListRef" ~args:[ Ty.Type (Ty.Param list_ref_element) ])
      (Ty.Param list_ref_element);
  ]

(* Methods, keyed by name. A runtime type's methods are stated over storage
   primitives (effects.md §6.6). *)
let methods =
  let meth ?(generics = []) ?abort ?(is_mut = false) namespace name params ret =
    ( name,
      verb ~generics ?abort ~is_mut ~namespace ~kind:S.Method ~name
        ~spelling:("@" ^ namespace ^ "$" ^ name) params ret )
  in
  [
    meth ~is_mut:true "runtime" "print"
      [ param "this" (runtime "Console"); param "text" (prim "String") ]
      (prim "Unit");
    meth ~abort:(Some (prim "Unit")) ~is_mut:true "runtime" "setThreads"
      [ param "this" (runtime "Runtime"); param "count" (prim "I64") ]
      (prim "Unit");
    meth ~is_mut:true "runtime" "setThreadsAuto" [ param "this" (runtime "Runtime") ] (prim "Unit");
    (* The program's arguments, a read of the runtime (effects.md §6.6). *)
    meth "runtime" "arguments"
      [ param "this" (runtime "Runtime") ]
      (prim "List" ~args:[ Ty.Type (prim "String") ]);
    (* A number read from a string's text (types.md §2.10). *)
    meth ~abort:(Some (prim "Unit")) "primitives" "parseI64"
      [ param "this" (prim "String") ]
      (prim "I64");
    meth ~abort:(Some (prim "Unit")) "primitives" "parseF64"
      [ param "this" (prim "String") ]
      (prim "F64");
    (* `parseF64` on the [count]
       bytes from byte [start], counted from 1 as `byteAt` counts. *)
    meth ~abort:(Some (prim "Unit")) "primitives" "parseF64At"
      [ param "this" (prim "String"); param "start" (prim "I64"); param "count" (prim "I64") ]
      (prim "F64");
    (* EXPERIMENT (LangArena zane-vs-c): a string's length in bytes, the
       byte at an index counted from 1, and a string made from bytes. *)
    meth "primitives" "byteCount" [ param "this" (prim "String") ] (prim "I64");
    meth "primitives" "byteAt" [ param "this" (prim "String"); param "index" (prim "I64") ] (prim "U8");
    (* A hash of a string's bytes, the same for equal strings within one
       run of the program and not specified beyond that. *)
    meth "primitives" "hashBytes" [ param "this" (prim "String") ] (prim "I64");
  ]
  @ (let bytes_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
     (* Generic so that `core`'s `List<U8>`, a list of `core`'s own `U8`,
        is accepted; `core` names this intrinsic only for that list, whose
        elements are one byte. *)
     [
       meth ~generics:[ bytes_element ] "primitives" "text"
         [ param "this" (prim "List" ~args:[ Ty.Type (Ty.Param bytes_element) ]) ]
         (prim "String");
     ]
     @ (let set_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind
        and flag = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
        [
    (* A byte set made from 256 flags, byte b's at b + 1, prepared for
       [findAny] and [findPair] to test 16 bytes at a time. Generic, as
       [text] is, so that `core`'s own `List<Bool>` is accepted; lowering
       checks that each flag is one byte. *)
    meth ~generics:[ flag ] "primitives" "byteSet"
      [ param "this" (prim "List" ~args:[ Ty.Type (Ty.Param flag) ]) ]
      (prim "List" ~args:[ Ty.Type (prim "U8") ]);
    (* The first of the [count] positions from [from], counted from 1,
       whose byte is in the set [first] and the byte [gap] after it in
       [second], or 0 when there is no such position; each set is one that
       [byteSet] made. *)
    meth ~generics:[ set_element ] "primitives" "findPair"
      [
        param "this" (prim "String");
        param "from" (prim "I64");
        param "count" (prim "I64");
        param "first" (prim "List" ~args:[ Ty.Type (Ty.Param set_element) ]);
        param "gap" (prim "I64");
        param "second" (prim "List" ~args:[ Ty.Type (Ty.Param set_element) ]);
      ]
      (prim "I64");
    (* The same search for one set: the first of the [count] positions from
       [from] whose byte is in [set], or 0. *)
    meth ~generics:[ set_element ] "primitives" "findAny"
      [
        param "this" (prim "String");
        param "from" (prim "I64");
        param "count" (prim "I64");
        param "set" (prim "List" ~args:[ Ty.Type (Ty.Param set_element) ]);
      ]
      (prim "I64");
        ]))
  (* `count` elements of a list, from
     its element `start`, copied onto the end of a list, as one copy: of
     another list, or of the list itself. Only for elements that own no
     blocks, which lowering checks. *)
  @ (let list () =
       let element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
       (element, prim "List" ~args:[ Ty.Type (Ty.Param element) ])
     in
     let range, ranged = list () and own, owned = list () and sorts, sorted = list () in
     let copied, copies = list () in
     let ordered, orders = list () and keyed, keys = list () in
     let compared, compares = list () and hashed, hashes = list () in
     [
       meth ~generics:[ range ] ~is_mut:true "primitives" "appendRange"
         [ param "this" ranged; param "from" ranged; param "start" (prim "I64"); param "count" (prim "I64") ]
         (prim "Unit");
       meth ~generics:[ own ] ~is_mut:true "primitives" "appendOwn"
         [ param "this" owned; param "start" (prim "I64"); param "count" (prim "I64") ]
         (prim "Unit");
       (* `count` elements of a list from its element `start` copied over
          the list's own from its element `at`, as one copy. *)
       meth ~generics:[ copied ] ~is_mut:true "primitives" "copyRange"
         [ param "this" copies; param "at" (prim "I64"); param "from" copies; param "start" (prim "I64"); param "count" (prim "I64") ]
         (prim "Unit");
       (* A list of `I32` indices into a list of `I64` keys, sorted
          stably by the key each names. *)
       meth ~generics:[ ordered; keyed ] ~is_mut:true "primitives" "sortBy"
         [ param "this" orders; param "keys" keys ]
         (prim "Unit");
       (* A list of integers sorted in place, ascending. *)
       meth ~generics:[ sorts ] ~is_mut:true "primitives" "sort" [ param "this" sorted ] (prim "Unit");
       (* 1 when a range of the list holds the same elements as a range
          of another, else 0; and a hash of a range, the same for equal
          ranges within one run. *)
       meth ~generics:[ compared ] "primitives" "sameRange"
         [
           param "this" compares;
           param "start" (prim "I64");
           param "other" compares;
           param "otherStart" (prim "I64");
           param "count" (prim "I64");
         ]
         (prim "I64");
       meth ~generics:[ hashed ] "primitives" "hashRange"
         [ param "this" hashes; param "start" (prim "I64"); param "count" (prim "I64") ]
         (prim "I64");
     ])
  (* A list's own methods, the same on `List` and `ListRef`, one overload
     per subject. *)
  @ List.concat_map
      (fun name ->
        let list_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
        let list = prim name ~args:[ Ty.Type (Ty.Param list_element) ] in
        [
          meth ~generics:[ list_element ] ~is_mut:true "primitives" "push"
            [ param "this" list; param "value" (Ty.Roaming (Ty.Param list_element)) ]
            (prim "Unit");
          meth ~generics:[ list_element ] "primitives" "size" [ param "this" list ] (prim "I64");
          (* The element at an index moves out and the list closes over its place
             (lifetimes.md §2.1): `remove` shifts the later elements down, keeping
             their order, and `swapRemove` moves the last element into the
             freed place. *)
          meth ~generics:[ list_element ] ~is_mut:true "primitives" "remove"
            [ param "this" list; param "index" (prim "I64") ]
            (Ty.Roaming (Ty.Param list_element));
          meth ~generics:[ list_element ] ~is_mut:true "primitives" "swapRemove"
            [ param "this" list; param "index" (prim "I64") ]
            (Ty.Roaming (Ty.Param list_element));
        ])
      [ "List"; "ListRef" ]

(* `@math$` (math.md §2): the math functions on scalar primitives, one
   overload per scalar each function takes, with every operand of that one
   type. The integer functions take `I32` and `I64`, and the float functions
   `F32` and `F64`. The CGT records which functions are exact and which
   approximate (Cgt.Nodes.Math). *)
let math_functions =
  let f name params ret =
    ( ("math", name),
      verb ~namespace:"math" ~kind:S.Function ~name:("@math$" ^ name) ~spelling:("@math$" ^ name)
        params ret )
  in
  let over names s =
    List.map (fun (name, params) -> f name (List.map (fun p -> param p (prim s)) params) (prim s)) names
  in
  let unary = [ "value" ] and binary = [ "left"; "right" ] in
  let integer =
    [
      ("bitAnd", binary); ("bitOr", binary); ("bitXor", binary); ("bitNot", unary);
      ("shiftLeft", [ "value"; "count" ]); ("shiftRight", [ "value"; "count" ]);
      ("shiftRightLogical", [ "value"; "count" ]); ("rotateLeft", [ "value"; "count" ]);
      ("rotateRight", [ "value"; "count" ]); ("popCount", unary); ("leadingZeros", unary);
      ("trailingZeros", unary); ("abs", unary); ("min", binary); ("max", binary);
    ]
  in
  let float =
    [
      ("sqrt", unary); ("abs", unary); ("floor", unary); ("ceil", unary); ("trunc", unary);
      ("roundEven", unary); ("fma", [ "left"; "right"; "addend" ]);
      ("copySign", [ "magnitude"; "sign" ]); ("min", binary); ("max", binary);
      ("cbrt", unary); ("sin", unary); ("cos", unary); ("tan", unary); ("asin", unary);
      ("acos", unary); ("atan", unary); ("atan2", [ "y"; "x" ]); ("exp", unary);
      ("log", unary); ("pow", [ "base"; "exponent" ]); ("hypot", [ "x"; "y" ]);
    ]
  in
  List.concat_map (over integer) integers @ List.concat_map (over float) floats

(* The two intrinsics that run a worker (control-flow.md §4.1): `step` is
   called with `subject` as its `this` until its result, converted to
   `@primitives$Bool`, is false; `workEvery` sleeps `interval` nanoseconds
   between one call and the next. Each is called like a function, and writes
   `subject` as a `mut` method writes its own subject, so each is declared as
   a `mut` method here, with its subject first: every check and analysis that
   follows a `!` call's write then follows the worker's write too. The step's result `R` reaches
   `@primitives$Bool` through the implicit constructor its package
   declares, as a condition reaches `branch`; a call cannot write a
   conversion of a function value's result, so the checker supplies it as
   a last argument, `test`, a lambda that converts (Check.worker_test). *)
let worker (name, leading) =
  let s = Ty.fresh_param ~name:"S" ~kind:Ty.Type_kind in
  let r = Ty.fresh_param ~name:"R" ~kind:Ty.Type_kind in
  let step = Ty.Verb { this_ = Some (Ty.Param s); params = []; ret = Ty.Param r; abort = None; is_mut = true } in
  let test = Ty.Verb { this_ = None; params = [ Ty.Param r ]; ret = prim "Bool"; abort = None; is_mut = false } in
  ( ("controlflow", name),
    verb ~generics:[ s; r ] ~is_mut:true ~namespace:"controlflow" ~kind:S.Method
      ~name:("@controlflow$" ^ name) ~spelling:("@controlflow$" ^ name)
      ((param "subject" (Ty.Param s) :: leading) @ [ param "step" step; param "test" test ])
      (prim "Unit") )

(* The control-flow intrinsics (syntax.md §5.1). *)
let control_functions =
  let f name params =
    ( ("controlflow", name),
      verb ~namespace:"controlflow" ~kind:S.Function ~name:("@controlflow$" ^ name)
        ~spelling:("@controlflow$" ^ name) params (prim "Unit") )
  in
  [
    f "branch" [ param "condition" (prim "Bool"); param "body" (Ty.Concept Ty.Block) ];
    f "repeat" [ param "count" (prim "I64"); param "body" (Ty.Concept Ty.Block) ];
    f "exitFromCall" [];
  ]
  @ List.map worker [ ("work", []); ("workEvery", [ param "interval" (prim "I64") ]) ]

(* Whether [s] is `@primitives$ArrayRef.fill`, whose call takes the
   checker's [index]. *)
let is_fill (s : S.t) =
  s.S.home = S.Namespace "primitives" && s.S.name = "@primitives$ArrayRef.fill"

(* Whether [spelling] runs a worker, so its call takes the checker's [test]. *)
let is_worker spelling = spelling = "@controlflow$work" || spelling = "@controlflow$workEvery"

(* Every intrinsic function, keyed by namespace and name. A key that several
   operator overloads share holds one entry per overload. *)
let functions = control_functions @ operator_functions @ math_functions

let find_functions namespace name =
  List.filter_map (fun (key, s) -> if key = (namespace, name) then Some s else None) functions

let namespaces = [ "primitives"; "concepts"; "operators"; "math"; "controlflow"; "runtime"; "program" ]
