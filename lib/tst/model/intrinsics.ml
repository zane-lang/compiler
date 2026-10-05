(* The intrinsic namespaces (syntax.md §2.7): what `@primitives$`,
   `@concepts$`, `@controlflow$`, `@runtime$` and `@program$` hold.

   They are not packages, so they are not read from source. Each intrinsic
   operation has exactly one signature, which makes this a plain table: no
   intrinsic function shares its name with another. Operators and methods are
   the exception the spec states -- a method's subject is one of its
   parameters, so methods that share a name on different types are overloads
   told apart by the subject -- and an operator is found the same way, by its
   operands' home, which for an intrinsic type is the namespace that holds it
   (functions.md §6.1, operators.md §2.2).

   The spec names the intrinsics its examples need and leaves the rest of each
   namespace open. What is here beyond those is this compiler's choice, made
   so that `core` can be written over it: the machine arithmetic and
   comparisons on the scalar primitives, the conversions that carry a literal
   into one, and the element access on the container primitives. Nothing in
   the checker names any of it; it is data. *)

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
    t "primitives" "Int";
    t "primitives" "I32";
    t "primitives" "I64";
    t "primitives" "Float";
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

let scalars = [ "Int"; "I32"; "I64"; "Float" ]

(* The literal each scalar converts from, the way `core`'s own `Int` and
   `Float` do (types.md §2.6): an integer literal into an integer, a decimal
   literal into a `Float`. *)
let literal = function "Float" -> Ty.Decimal_lit | _ -> Ty.Integer_lit

let operator_token : Sst.Nodes.Operator.node -> string = function
  | Add -> "+"
  | Mul -> "*"
  | Div -> "/"
  | Eq -> "=="
  | Less -> "<"

(* The operators each scalar implements over itself, and `Bool`'s. *)
let operators =
  let binary scalar (op : Sst.Nodes.Operator.node) ret =
    let token = operator_token op in
    ( op,
      verb ~namespace:"primitives" ~kind:S.Operator ~name:token
        ~spelling:("@primitives$" ^ token)
        [ param "left" (prim scalar); param "right" (prim scalar) ]
        ret )
  in
  List.concat_map
    (fun s ->
      [
        binary s Add (prim s);
        binary s Mul (prim s);
        binary s Div (prim s);
        binary s Eq (prim "Bool");
        binary s Less (prim "Bool");
      ])
    scalars
  @ [
      binary "Bool" Add (prim "Bool");
      binary "Bool" Mul (prim "Bool");
      binary "Bool" Eq (prim "Bool");
      binary "String" Add (prim "String");
      binary "String" Eq (prim "Bool");
    ]

let flips =
  List.map
    (fun s ->
      verb ~namespace:"primitives" ~kind:S.Flip ~name:"~" ~spelling:"@primitives$~"
        [ param "value" (prim s) ]
        (prim s))
    (scalars @ [ "Bool" ])

(* Constructors, keyed by the type they build. A storage primitive has one
   constructor from its literal's concept, and it is not implicit (types.md
   §2.7): a literal becomes a primitive only where it is written, or inside a
   type's own implicit conversion. *)
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
  List.map
    (fun s -> ctor s [ param "value" (Ty.Concept (literal s)) ] (prim s))
    scalars
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
                 params = [ prim "Int" ];
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
      [ param "this" subject; param "index" (prim "Int") ]
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
      [ param "this" (runtime "Runtime"); param "count" (prim "Int") ]
      (prim "Unit");
    meth ~is_mut:true "runtime" "setThreadsAuto" [ param "this" (runtime "Runtime") ] (prim "Unit");
    meth ~generics:[ list_element ] ~is_mut:true "primitives" "push"
      [ param "this" list; param "value" (Ty.Roaming (Ty.Param list_element)) ]
      (prim "Unit");
    meth ~generics:[ list_element ] "primitives" "size" [ param "this" list ] (prim "Int");
  ]

(* The control-flow intrinsics (syntax.md §5.1), the only intrinsic functions
   called by plain name. *)
let functions =
  let f name params =
    ( ("controlflow", name),
      verb ~namespace:"controlflow" ~kind:S.Function ~name:("@controlflow$" ^ name)
        ~spelling:("@controlflow$" ^ name) params (prim "Unit") )
  in
  [
    f "branch" [ param "condition" (prim "Bool"); param "body" (Ty.Concept Ty.Block) ];
    f "repeat" [ param "count" (prim "Int"); param "body" (Ty.Concept Ty.Block) ];
    f "exitFromCall" [];
  ]

let namespaces = [ "primitives"; "concepts"; "controlflow"; "runtime"; "program" ]
