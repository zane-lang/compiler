(* Every node of the parsed tree, with the source text its span covers.

   The span-side counterpart of [To_tree_graph]: that one renders the tree's
   structure, this one renders where each node was written. Both are stage
   adapters -- they pattern-match on this stage's nodes and hand the result to
   a shared renderer, [Tree_graph] there and [Source.Span_text] here.

   One line per node: its kind, indented by depth, and the text between its
   span's two positions. A span that covers the wrong tokens says so in plain
   text, which is the whole point -- the five span bugs found in review on #86,
   and the two after them, were all invisible to a suite that only asks whether
   a file parses. `test/parser/golden/` checks the output on every run, so a
   grammar change that moves a span shows the move as a diff.

   The printer is a module-level reference rather than an argument threaded
   through every function below, because every one of them would carry it and
   none of them would do anything with it but pass it on. [render] is the only
   entry point and it sets the reference before walking, so the state does not
   outlive a call. *)

let printer = ref (Source.Span_text.create "")
let line depth kind span = Source.Span_text.line !printer depth kind span

open Nodes

let name d label (n : Name.t) = line d (label ^ " " ^ n.Name.text) n.Name.span
let opt d f = function None -> () | Some x -> f d x
let each d f xs = List.iter (f d) xs

let concept d (x : Concept.t) =
  line d
    (match x.Concept.node with Concept.Type -> "concept Type" | Concept.Number -> "concept Number")
    x.Concept.span

let name_type d (x : Name_type.t) =
  line d "name_type" x.Name_type.span;
  match x.Name_type.node with
  | Name_type.Ident n -> name (d + 1) "ident" n
  | Name_type.Qualified { package; ident } | Name_type.Intrinsic { package; ident } ->
      name (d + 1) "package" package;
      name (d + 1) "ident" ident

let name_expr d (x : Name_expr.t) =
  line d "name_expr" x.Name_expr.span;
  match x.Name_expr.node with
  | Name_expr.Ident n -> name (d + 1) "ident" n
  | Name_expr.Qualified { package; ident } | Name_expr.Intrinsic { package; ident } ->
      name (d + 1) "package" package;
      name (d + 1) "ident" ident

let operator d (x : Operator.t) = line d "operator" x.Operator.span

let import_member d (x : Import_member.t) =
  line d ("import_member " ^ x.Import_member.name) x.Import_member.span

let import d (x : Import.t) =
  line d "import" x.Import.span;
  match x.Import.node with
  | Import.Package { package; alias } ->
      name (d + 1) "package" package;
      opt (d + 1) (fun d a -> name d "alias" a) alias
  | Import.Member { package; member; alias } ->
      name (d + 1) "package" package;
      import_member (d + 1) member;
      opt (d + 1) import_member alias
  | Import.Members { package; members } ->
      name (d + 1) "package" package;
      each (d + 1) import_member members
  | Import.All { package } -> name (d + 1) "package" package

let generic_param d (x : Generic_param.t) =
  line d "generic_param" x.Generic_param.span;
  name (d + 1) "name" x.Generic_param.name;
  concept (d + 1) x.Generic_param.type_

let rec type_expr d (x : Type_expr.t) =
  line d "type_expr" x.Type_expr.span;
  let d = d + 1 in
  match x.Type_expr.node with
  | Type_expr.Path { name = n; generics } ->
      name_type d n;
      each d generic_arg generics
  | Type_expr.Guest t | Type_expr.Parenthesized t -> type_expr d t
  | Type_expr.Verb v -> verb_type d v

and verb_type d (x : Verb_type.t) =
  line d "verb_type" x.Verb_type.span;
  let d = d + 1 in
  match x.Verb_type.node with
  | Verb_type.Func { params; ret_type } ->
      each d param_type params;
      ret_type_ d ret_type
  | Verb_type.Meth { this_type; params; ret_type; _ } ->
      type_expr d this_type;
      each d param_type params;
      ret_type_ d ret_type

and ret_type_ d (x : Ret_type.t) =
  line d "ret_type" x.Ret_type.span;
  let d = d + 1 in
  match x.Ret_type.node with
  | Ret_type.Safe t -> type_expr d t
  | Ret_type.Abort { ok; abort } ->
      type_expr d ok;
      type_expr d abort
  | Ret_type.Parenthesized r -> ret_type_ d r

and generic_arg d (x : Generic_arg.t) =
  line d "generic_arg" x.Generic_arg.span;
  let d = d + 1 in
  match x.Generic_arg.node with
  | Generic_arg.Type t -> type_expr d t
  | Generic_arg.Number _ -> ()
  | Generic_arg.NumberRef n -> name d "number_ref" n
  | Generic_arg.Inferred p -> param d p

and param_type d (x : Param_type.t) =
  line d "param_type" x.Param_type.span;
  let d = d + 1 in
  match x.Param_type.node with
  | Param_type.Concrete t -> type_expr d t
  | Param_type.Concept c -> concept d c
  | Param_type.InferredType { name = n; concept = c } ->
      name d "name" n;
      concept d c

and param d (x : Param.t) =
  line d "param" x.Param.span;
  name (d + 1) "name" x.Param.name;
  param_type (d + 1) x.Param.type_

and constructor_field d (x : Constructor_field.t) =
  line d "constructor_field" x.Constructor_field.span;
  let d = d + 1 in
  name d "name" x.Constructor_field.name;
  param_type d x.Constructor_field.type_;
  opt d expr x.Constructor_field.default

and constructor_params d (x : Constructor_params.t) =
  line d "constructor_params" x.Constructor_params.span;
  let d = d + 1 in
  match x.Constructor_params.node with
  | Constructor_params.Positional ps -> each d param ps
  | Constructor_params.Fields fs -> each d constructor_field fs

and constructor_name d (x : Constructor_name.t) =
  line d "constructor_name" x.Constructor_name.span;
  name_type (d + 1) x.Constructor_name.type_;
  opt (d + 1) (fun d m -> name d "member" m) x.Constructor_name.member

and field_arg d (x : Field_arg.t) =
  line d "field_arg" x.Field_arg.span;
  name (d + 1) "name" x.Field_arg.name;
  opt (d + 1) expr x.Field_arg.value

and call_arg d (x : Call_arg.t) =
  line d "call_arg" x.Call_arg.span;
  let d = d + 1 in
  match x.Call_arg.node with
  | Call_arg.Value v -> expr d v
  | Call_arg.Block stats -> each d statement stats

and constructor_args d (x : Constructor_args.t) =
  line d "constructor_args" x.Constructor_args.span;
  let d = d + 1 in
  match x.Constructor_args.node with
  | Constructor_args.Positional args -> each d call_arg args
  | Constructor_args.Fields fs -> each d field_arg fs

and abort_handle d (x : Abort_handle.t) =
  line d "abort_handle" x.Abort_handle.span;
  let d = d + 1 in
  match x.Abort_handle.node with
  | Abort_handle.Shorthand e -> expr d e
  | Abort_handle.Longhand { binder; body = b } ->
      opt d (fun d n -> name d "binder" n) binder;
      body d b

and verb_call d (x : Verb_call.t) =
  line d "verb_call" x.Verb_call.span;
  let d = d + 1 in
  match x.Verb_call.node with
  | Verb_call.Func { callee; args; abort_handle = h; _ } ->
      expr d callee;
      each d call_arg args;
      opt d abort_handle h
  | Verb_call.Meth { callee; this; args; abort_handle = h; _ } ->
      expr d callee;
      expr d this;
      each d call_arg args;
      opt d abort_handle h
  | Verb_call.Constructor { name = n; args; abort_handle = h; _ } ->
      constructor_name d n;
      constructor_args d args;
      opt d abort_handle h
  | Verb_call.Op { op; left; right; abort_handle = h } ->
      operator d op;
      expr d left;
      expr d right;
      opt d abort_handle h
  | Verb_call.Flip { value; abort_handle = h } ->
      expr d value;
      opt d abort_handle h

and match_pattern d (x : Match_pattern.t) =
  line d "match_pattern" x.Match_pattern.span;
  opt (d + 1) (fun d n -> name d "binder" n) x.Match_pattern.binder;
  List.iter (name (d + 1) "case") x.Match_pattern.cases

and match_arm d (x : Match_arm.t) =
  line d "match_arm" x.Match_arm.span;
  each (d + 1) match_pattern x.Match_arm.patterns;
  body (d + 1) x.Match_arm.body

and match_expr d (x : Match_expr.t) =
  line d "match_expr" x.Match_expr.span;
  let d = d + 1 in
  each d expr x.Match_expr.scrutinees;
  each d match_arm x.Match_expr.arms;
  opt d abort_handle x.Match_expr.abort_handle

and func_lambda d (x : Func_lambda.t) =
  line d "func_lambda" x.Func_lambda.span;
  let d = d + 1 in
  each d param x.Func_lambda.params;
  ret_type_ d x.Func_lambda.ret_type;
  body d x.Func_lambda.body

and meth_lambda d (x : Meth_lambda.t) =
  line d "meth_lambda" x.Meth_lambda.span;
  let d = d + 1 in
  type_expr d x.Meth_lambda.this_type;
  each d param x.Meth_lambda.params;
  ret_type_ d x.Meth_lambda.ret_type;
  body d x.Meth_lambda.body

and expr d (x : Expr.t) =
  line d "expr" x.Expr.span;
  let d = d + 1 in
  match x.Expr.node with
  | Expr.IntLit _ | Expr.FloatLit _ | Expr.StrLit _ | Expr.BoolLit _ -> ()
  | Expr.CollectionLit items -> each d expr items
  | Expr.NameExpr n -> name_expr d n
  | Expr.TypeMember { type_; member } ->
      name_type d type_;
      name d "member" member
  | Expr.TypeValue t -> name_type d t
  | Expr.DotAccess { target; field } ->
      expr d target;
      name d "field" field
  | Expr.Subscript { target; args } ->
      expr d target;
      each d expr args
  | Expr.Ref v | Expr.Parenthized v -> expr d v
  | Expr.Init fs -> each d field_arg fs
  | Expr.MapLit entries ->
      List.iter
        (fun (k, v) ->
          expr d k;
          expr d v)
        entries
  | Expr.Spawn c | Expr.VerbCall c -> verb_call d c
  | Expr.Match m -> match_expr d m
  | Expr.FuncLambda l -> func_lambda d l
  | Expr.MethLambda l -> meth_lambda d l

and body d (x : Body.t) =
  line d "body" x.Body.span;
  let d = d + 1 in
  match x.Body.node with
  | Body.Shorthand e -> expr d e
  | Body.Longhand stats -> each d statement stats

and statement d (x : Statement.t) =
  line d "statement" x.Statement.span;
  stat (d + 1) x.Statement.stat

and stat d (x : Stat.t) =
  line d "stat" x.Stat.span;
  let d = d + 1 in
  match x.Stat.node with
  | Stat.VerbCall c | Stat.Spawn c -> verb_call d c
  | Stat.Decl dl -> decl d dl
  | Stat.Assign { target; value } ->
      expr d target;
      expr d value
  | Stat.Abort e | Stat.Ret e | Stat.Resolve e -> expr d e

and mould d (x : Mould.t) =
  line d "mould" x.Mould.span;
  let d = d + 1 in
  match x.Mould.node with
  | Mould.Struct fs | Mould.Variant fs -> each d body_field fs
  | Mould.Enum members -> List.iter (name d "member") members

and body_field d (x : Body_field.t) =
  line d "body_field" x.Body_field.span;
  name (d + 1) "name" x.Body_field.name;
  type_expr (d + 1) x.Body_field.type_

and moulded d (x : Moulded.t) =
  line d "moulded" x.Moulded.span;
  mould (d + 1) x.Moulded.mould;
  line (d + 1) "type_axis" x.Moulded.axis.Type_axis.span

and type_or_moulded d (x : Type_or_moulded.t) =
  line d "type_or_moulded" x.Type_or_moulded.span;
  let d = d + 1 in
  match x.Type_or_moulded.node with
  | Type_or_moulded.Raw t -> type_expr d t
  | Type_or_moulded.Moulded m -> moulded d m

and verb_decl d (x : Verb_decl.t) =
  line d "verb_decl" x.Verb_decl.span;
  let d = d + 1 in
  match x.Verb_decl.node with
  | Verb_decl.Func { name = n; params; ret_type; body = b } ->
      name d "name" n;
      each d param params;
      ret_type_ d ret_type;
      body d b
  | Verb_decl.Meth { name = n; this_type; params; ret_type; body = b; _ } ->
      name d "name" n;
      type_expr d this_type;
      each d param params;
      ret_type_ d ret_type;
      body d b
  | Verb_decl.Op { op; params; ret_type; body = b } ->
      operator d op;
      each d param params;
      ret_type_ d ret_type;
      body d b
  | Verb_decl.Constructor { type_; member; params; body = b; _ } ->
      type_expr d type_;
      opt d (fun d m -> name d "member" m) member;
      constructor_params d params;
      body d b
  | Verb_decl.Subscript { this_type; params; value } ->
      type_expr d this_type;
      each d param params;
      expr d value
  | Verb_decl.Flip { params; ret_type; body = b } ->
      each d param params;
      ret_type_ d ret_type;
      body d b

and decl d (x : Decl.t) =
  line d "decl" x.Decl.span;
  let d = d + 1 in
  match x.Decl.node with
  | Decl.Package n -> name d "name" n
  | Decl.Import i -> import d i
  | Decl.Var { name = n; type_; value } ->
      name d "name" n;
      type_expr d type_;
      expr d value
  | Decl.VarShorthand { name = n; constructor; args; _ } ->
      name d "name" n;
      constructor_name d constructor;
      constructor_args d args
  | Decl.Type { name = n; params; value } | Decl.Alias { name = n; params; value } ->
      name d "name" n;
      each d generic_param params;
      type_or_moulded d value
  | Decl.EnumMap { enum; property; type_; entries } ->
      type_expr d enum;
      name d "property" property;
      type_expr d type_;
      List.iter
        (fun (member, value) ->
          name d "entry" member;
          expr d value)
        entries
  | Decl.Verb v -> verb_decl d v

(* [source] is the text the spans index into, which is the text that was
   parsed. Handing it in rather than re-reading the file keeps this honest for
   a caller that parsed standard input. *)
let render ~source (package : Package.t) =
  printer := Source.Span_text.create source;
  line 0 "package" package.Package.span;
  each 1 decl package.Package.decls;
  Source.Span_text.contents !printer
