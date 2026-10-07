(* The intrinsic namespaces (syntax.md §2.7): what `@primitives$`,
   `@concepts$`, `@operators$`, `@controlflow$`, `@runtime$` and `@program$`
   hold.

   They are not packages, so they are not read from source. Most intrinsic
   operations have exactly one signature. The overloads the spec states are
   the exceptions: methods that share a name on different subjects, the
   machine operations of `@operators$`, one per operand type, and a scalar's
   constructors, which take its concept and each scalar that converts into
   it exactly (syntax.md §2.7, types.md §2.7). No intrinsic is an operator:
   a primitive has no home package, so an operator over one is declared
   nowhere (operators.md §2.2).

   The spec names the intrinsics its examples need and leaves the rest of each
   namespace open. What is here beyond those is this compiler's choice, made
   so that `core` can be written over it: the element access on the
   container primitives and the runtime types' methods. Nothing in the
   checker names any of it; it is data. *)

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
    t ~params:[ Ty.Type_kind ] ~reference:true "primitives" "List";
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

(* An operator's token, which a diagnostic and a declaration's name use. *)
let operator_token : Sst.Nodes.Operator.node -> string = function
  | Add -> "+"
  | Mul -> "*"
  | Div -> "/"
  | Eq -> "=="
  | Less -> "<"

(* `@operators$` (syntax.md §2.7): the machine operations the primitive
   operators of operators.md §2.1 are written over, one overload per operand
   type, both operands of that one type. There is no subtraction, since
   `a - b` is `a + ~b` (operators.md §4.2). `Bool` has its own three, named
   for what they are rather than for the operators `core` spells them with,
   and `String` its join; equality is one operation on every type. *)
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
      binary "and" "Bool" (prim "Bool");
      binary "or" "Bool" (prim "Bool");
      f "not" [ param "value" (prim "Bool") ] (prim "Bool");
      binary "equal" "Bool" (prim "Bool");
      binary "concat" "String" (prim "String");
      binary "equal" "String" (prim "Bool");
    ]

(* The conversions between scalars (types.md §2.9), as the target, the name
   of the constructor that converts, and the source. One that is exact for
   every value is a plain constructor; one that can lose a value is named
   for how it does: `wrap` keeps an integer's low bits, `truncate` drops a
   float's fraction and stops the program when what is left does not fit,
   and `round` takes the nearest value the target holds. *)
let conversions =
  [
    ("I64", None, "I32");
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
   constructor from its concept, and a scalar one from each scalar it
   converts from (types.md §2.9). None is implicit: a concept becomes a
   primitive only where it is written, or inside a type's own implicit
   conversion. *)
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
  let fixed name e n = prim name ~args:[ Ty.Type (Ty.Param e); Ty.Number (Ty.Number_param n) ] in
  let elements e n = Ty.Concept (Ty.Array_lit (Ty.Param e, Ty.Number_param n)) in
  let ref_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  let ref_length = Ty.fresh_param ~name:"n" ~kind:Ty.Number_kind in
  let fill_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  let fill_length = Ty.fresh_param ~name:"n" ~kind:Ty.Number_kind in
  List.map (fun s -> ctor s [ param "value" (Ty.Concept (concept s)) ] (prim s)) scalars
  @ List.map
      (fun (target, member, source) -> ctor ?member target [ param "value" (prim source) ] (prim target))
      conversions
  @ [
      ctor "String" [ param "value" (Ty.Concept Ty.Text_lit) ] (prim "String");
      ctor "Unit" [] (prim "Unit");
      ctor ~generics:[ element; length ] "Array"
        [ param "values" (elements element length) ]
        (fixed "Array" element length);
      (* An `ArrayRef` is built from an array literal, each element moved into
         its place, or by `fill`, which calls `make` once per position, in
         order, with the position counted from 1 (generics.md §8.4). *)
      ctor ~generics:[ ref_element; ref_length ] "ArrayRef"
        [ param "values" (elements ref_element ref_length) ]
        (fixed "ArrayRef" ref_element ref_length);
      ctor ~generics:[ fill_element; fill_length ] ~member:"fill" "ArrayRef"
        [
          param ~binds:fill_length "n" (Ty.Concept Ty.Integer_lit);
          param "make"
            (Ty.Verb
               {
                 Ty.this_ = None;
                 params = [ prim "I64" ];
                 ret = Ty.Roaming (Ty.Param fill_element);
                 abort = None;
                 is_mut = false;
               });
        ]
        (fixed "ArrayRef" fill_element fill_length);
      ctor ~generics:[ list_element ] "List"
        [ param ~binds:list_element "T" (Ty.Concept Ty.Type_value) ]
        (prim "List" ~args:[ Ty.Type (Ty.Param list_element) ]);
    ]

let subscripts =
  let element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  let length = Ty.fresh_param ~name:"n" ~kind:Ty.Number_kind in
  let ref_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  let ref_length = Ty.fresh_param ~name:"n" ~kind:Ty.Number_kind in
  let list_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
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
  ]

(* Methods, keyed by name. A runtime type's methods are stated over storage
   primitives (effects.md §6.6). *)
let methods =
  let list_element = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  let list = prim "List" ~args:[ Ty.Type (Ty.Param list_element) ] in
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
    meth ~generics:[ list_element ] ~is_mut:true "primitives" "push"
      [ param "this" list; param "value" (Ty.Roaming (Ty.Param list_element)) ]
      (prim "Unit");
    meth ~generics:[ list_element ] "primitives" "size" [ param "this" list ] (prim "I64");
  ]

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

(* Every intrinsic function, keyed by namespace and name. A key the
   operators share holds one entry per overload. *)
let functions = control_functions @ operator_functions

let find_functions namespace name =
  List.filter_map (fun (key, s) -> if key = (namespace, name) then Some s else None) functions

let namespaces = [ "primitives"; "concepts"; "operators"; "controlflow"; "runtime"; "program" ]
