(* Every node of the desugared tree, with the source text its span covers.

   [Cst.To_span_text] over the SST, and it answers one more question than that
   one does. Each line carries the node's *variant*, not just its kind, so the
   expectation shows the rewrites of docs/desugaring.md having happened:

     verb_call Flip       | a >= b
       verb_call Op Less  | a >= b
         operator Less    | >=

   Three lines that say a `>=` became `~(a < b)`, and that the `<` still points
   at the `>=` the author wrote. A checked-in expectation therefore fails both
   when a span moves and when a desugaring changes shape, which is what a pass
   whose whole job is to change shape needs from a test.

   The second thing it checks is the rule [Lower] holds itself to: every
   synthesized node takes the span of the syntax it came from. A node that
   pointed nowhere would print `<INVALID SPAN>`, and one that pointed at the
   wrong thing would print the wrong text.

   The printer is a module-level reference for the same reason it is one in
   [Cst.To_span_text]: [render] is the only entry point and sets it before
   walking. *)

let printer = ref (Source.Span_text.create "")
let line depth kind span = Source.Span_text.line !printer depth kind span

open Nodes

let name d label (n : Name.t) = line d (label ^ " " ^ n.Name.text) n.Name.span
let opt d f = function None -> () | Some x -> f d x
let each d f xs = List.iter (f d) xs

let concept d (x : Concept.t) =
  line d
    (match x.Concept.node with
    | Concept.Type -> "concept Type"
    | Concept.Number -> "concept Number")
    x.Concept.span

let name_type d (x : Name_type.t) =
  line d "name_type" x.Name_type.span;
  match x.Name_type.node with
  | Name_type.Ident n -> name (d + 1) "ident" n
  | Name_type.Qualified { package; ident } | Name_type.Intrinsic { package; ident }
    ->
      name (d + 1) "package" package;
      name (d + 1) "ident" ident

let name_expr d (x : Name_expr.t) =
  line d "name_expr" x.Name_expr.span;
  match x.Name_expr.node with
  | Name_expr.Ident n -> name (d + 1) "ident" n
  | Name_expr.Qualified { package; ident } | Name_expr.Intrinsic { package; ident }
    ->
      name (d + 1) "package" package;
      name (d + 1) "ident" ident

(* The variant is in the label because that is the whole point here: a `Less`
   spanning a `>=` is the derived-operator rewrite, visible in one line. *)
let operator d (x : Operator.t) =
  let which =
    match x.Operator.node with
    | Operator.Add -> "Add"
    | Operator.Mul -> "Mul"
    | Operator.Div -> "Div"
    | Operator.Eq -> "Eq"
    | Operator.Less -> "Less"
  in
  line d ("operator " ^ which) x.Operator.span

let constructor_name d (x : Constructor_name.t) =
  line d "constructor_name" x.Constructor_name.span;
  name_type (d + 1) x.Constructor_name.type_;
  opt (d + 1) (fun d m -> name d "member" m) x.Constructor_name.member

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

let type_axis d (x : Type_axis.t) =
  line d
    (match x.Type_axis.node with
    | Type_axis.Value -> "type_axis Value"
    | Type_axis.Reference -> "type_axis Reference")
    x.Type_axis.span

let generic_param d (x : Generic_param.t) =
  line d "generic_param" x.Generic_param.span;
  name (d + 1) "name" x.Generic_param.name;
  concept (d + 1) x.Generic_param.type_

let rec type_expr d (x : Type_expr.t) =
  match x.Type_expr.node with
  | Type_expr.Path { name = n; generics } ->
      line d "type_expr Path" x.Type_expr.span;
      name_type (d + 1) n;
      each (d + 1) generic_arg generics
  | Type_expr.Guest inner ->
      line d "type_expr Guest" x.Type_expr.span;
      type_expr (d + 1) inner
  | Type_expr.Verb v ->
      line d "type_expr Verb" x.Type_expr.span;
      verb_type (d + 1) v

and generic_arg d (x : Generic_arg.t) =
  match x.Generic_arg.node with
  | Generic_arg.Type t ->
      line d "generic_arg Type" x.Generic_arg.span;
      type_expr (d + 1) t
  | Generic_arg.Number _ -> line d "generic_arg Number" x.Generic_arg.span
  | Generic_arg.NumberRef n ->
      line d "generic_arg NumberRef" x.Generic_arg.span;
      name (d + 1) "name" n
  | Generic_arg.Inferred p ->
      line d "generic_arg Inferred" x.Generic_arg.span;
      param (d + 1) p

and verb_type d (x : Verb_type.t) =
  match x.Verb_type.node with
  | Verb_type.Func { params; ret_type = r } ->
      line d "verb_type Func" x.Verb_type.span;
      each (d + 1) param_type params;
      ret_type (d + 1) r
  | Verb_type.Meth { this_type; params; ret_type = r; is_mut } ->
      line d
        (if is_mut then "verb_type Meth mut" else "verb_type Meth")
        x.Verb_type.span;
      type_expr (d + 1) this_type;
      each (d + 1) param_type params;
      ret_type (d + 1) r

and ret_type d (x : Ret_type.t) =
  match x.Ret_type.node with
  | Ret_type.Safe t ->
      line d "ret_type Safe" x.Ret_type.span;
      type_expr (d + 1) t
  | Ret_type.Abort { ok; abort } ->
      line d "ret_type Abort" x.Ret_type.span;
      type_expr (d + 1) ok;
      type_expr (d + 1) abort

and param_type d (x : Param_type.t) =
  match x.Param_type.node with
  | Param_type.Concrete t ->
      line d "param_type Concrete" x.Param_type.span;
      type_expr (d + 1) t
  | Param_type.Concept c ->
      line d "param_type Concept" x.Param_type.span;
      concept (d + 1) c
  | Param_type.InferredType { name = n; concept = c } ->
      line d "param_type InferredType" x.Param_type.span;
      name (d + 1) "name" n;
      concept (d + 1) c

and param d (x : Param.t) =
  line d "param" x.Param.span;
  name (d + 1) "name" x.Param.name;
  param_type (d + 1) x.Param.type_

(* Never [None] any more: a bare `x` was written out into `x = x`, and the
   synthesized value prints under it spanning just the name. *)
and field_arg d (x : Field_arg.t) =
  line d "field_arg" x.Field_arg.span;
  name (d + 1) "name" x.Field_arg.name;
  expr (d + 1) x.Field_arg.value

and expr d (x : Expr.t) =
  let at = x.Expr.span in
  match x.Expr.node with
  | Expr.IntLit _ -> line d "expr IntLit" at
  | Expr.FloatLit _ -> line d "expr FloatLit" at
  | Expr.StrLit _ -> line d "expr StrLit" at
  | Expr.BoolLit _ -> line d "expr BoolLit" at
  | Expr.CollectionLit items ->
      line d "expr CollectionLit" at;
      each (d + 1) expr items
  | Expr.NameExpr n ->
      line d "expr NameExpr" at;
      name_expr (d + 1) n
  | Expr.TypeMember { type_; member } ->
      line d "expr TypeMember" at;
      name_type (d + 1) type_;
      name (d + 1) "member" member
  | Expr.TypeValue t ->
      line d "expr TypeValue" at;
      name_type (d + 1) t
  | Expr.DotAccess { target; field } ->
      line d "expr DotAccess" at;
      expr (d + 1) target;
      name (d + 1) "field" field
  | Expr.Subscript { target; args } ->
      line d "expr Subscript" at;
      expr (d + 1) target;
      each (d + 1) expr args
  | Expr.Ref inner ->
      line d "expr Ref" at;
      expr (d + 1) inner
  | Expr.Init fields ->
      line d "expr Init" at;
      each (d + 1) field_arg fields
  | Expr.MapLit entries ->
      line d "expr MapLit" at;
      List.iter
        (fun (k, v) ->
          expr (d + 1) k;
          expr (d + 1) v)
        entries
  | Expr.MethodTarget { callee; this; is_mut } ->
      line d
        (if is_mut then "expr MethodTarget mut" else "expr MethodTarget")
        at;
      expr (d + 1) callee;
      expr (d + 1) this
  | Expr.Pipe { callee; value; abort_handle } ->
      line d "expr Pipe" at;
      expr (d + 1) callee;
      expr (d + 1) value;
      opt (d + 1) abort_handle_ abort_handle
  | Expr.Spawn call ->
      line d "expr Spawn" at;
      verb_call (d + 1) call
  | Expr.Match m ->
      line d "expr Match" at;
      match_expr (d + 1) m
  | Expr.VerbCall call ->
      line d "expr VerbCall" at;
      verb_call (d + 1) call
  | Expr.FuncLambda l ->
      line d "expr FuncLambda" at;
      func_lambda (d + 1) l
  | Expr.MethLambda l ->
      line d "expr MethLambda" at;
      meth_lambda (d + 1) l

and call_arg d (x : Call_arg.t) =
  match x.Call_arg.node with
  | Call_arg.Value v ->
      line d "call_arg Value" x.Call_arg.span;
      expr (d + 1) v
  | Call_arg.Block b ->
      line d "call_arg Block" x.Call_arg.span;
      block (d + 1) b

and constructor_args d (x : Constructor_args.t) =
  match x.Constructor_args.node with
  | Constructor_args.Positional args ->
      line d "constructor_args Positional" x.Constructor_args.span;
      each (d + 1) call_arg args
  | Constructor_args.Fields fields ->
      line d "constructor_args Fields" x.Constructor_args.span;
      each (d + 1) field_arg fields

(* One node for all three call spellings; the label says which was written and,
   for a method, with which marker. A method's subject is [args]'s first
   element, so it prints as the first `call_arg` under the call. *)
and verb_call d (x : Verb_call.t) =
  let at = x.Verb_call.span in
  match x.Verb_call.node with
  | Verb_call.Call { callee; args; form; abort_handle } ->
      let which =
        match form with
        | Call_form.Function -> "verb_call Call function"
        | Call_form.Method { is_mut = true } -> "verb_call Call method!"
        | Call_form.Method { is_mut = false } -> "verb_call Call method:"
      in
      line d which at;
      expr (d + 1) callee;
      each (d + 1) call_arg args;
      opt (d + 1) abort_handle_ abort_handle
  | Verb_call.Constructor { name = n; args; abort_handle } ->
      line d "verb_call Constructor" at;
      constructor_name (d + 1) n;
      constructor_args (d + 1) args;
      opt (d + 1) abort_handle_ abort_handle
  | Verb_call.Op { op; left; right; abort_handle } ->
      line d "verb_call Op" at;
      operator (d + 1) op;
      expr (d + 1) left;
      expr (d + 1) right;
      opt (d + 1) abort_handle_ abort_handle
  | Verb_call.Flip { value; abort_handle } ->
      line d "verb_call Flip" at;
      expr (d + 1) value;
      opt (d + 1) abort_handle_ abort_handle

(* Named with a trailing underscore because [Abort_handle] is a module in
   scope and the walker below wants the shorter name for its own use. *)
and abort_handle_ d (x : Abort_handle.t) =
  line d "abort_handle" x.Abort_handle.span;
  opt (d + 1) (fun d b -> name d "binder" b) x.Abort_handle.binder;
  block (d + 1) x.Abort_handle.body

and match_pattern d (x : Match_pattern.t) =
  line d "match_pattern" x.Match_pattern.span;
  opt (d + 1) (fun d b -> name d "binder" b) x.Match_pattern.binder;
  name (d + 1) "case" x.Match_pattern.case

and match_arm d (x : Match_arm.t) =
  line d "match_arm" x.Match_arm.span;
  each (d + 1) match_pattern x.Match_arm.patterns;
  block (d + 1) x.Match_arm.body

and match_expr d (x : Match_expr.t) =
  line d "match_expr" x.Match_expr.span;
  each (d + 1) expr x.Match_expr.scrutinees;
  each (d + 1) match_arm x.Match_expr.arms;
  opt (d + 1) abort_handle_ x.Match_expr.abort_handle

and block d (x : Block.t) =
  line d "block" x.Block.span;
  each (d + 1) stat x.Block.stats

and stat d (x : Stat.t) =
  let at = x.Stat.span in
  match x.Stat.node with
  | Stat.VerbCall call ->
      line d "stat VerbCall" at;
      verb_call (d + 1) call
  | Stat.Spawn call ->
      line d "stat Spawn" at;
      verb_call (d + 1) call
  | Stat.Decl value ->
      line d "stat Decl" at;
      decl (d + 1) value
  | Stat.Assign { target; value } ->
      line d "stat Assign" at;
      expr (d + 1) target;
      expr (d + 1) value
  | Stat.Abort value ->
      line d "stat Abort" at;
      expr (d + 1) value
  | Stat.Ret value ->
      line d "stat Ret" at;
      expr (d + 1) value
  | Stat.Resolve value ->
      line d "stat Resolve" at;
      expr (d + 1) value

and func_lambda d (x : Func_lambda.t) =
  line d "func_lambda" x.Func_lambda.span;
  each (d + 1) param x.Func_lambda.params;
  ret_type (d + 1) x.Func_lambda.ret_type;
  block (d + 1) x.Func_lambda.body

and meth_lambda d (x : Meth_lambda.t) =
  line d
    (if x.Meth_lambda.is_mut then "meth_lambda mut" else "meth_lambda")
    x.Meth_lambda.span;
  type_expr (d + 1) x.Meth_lambda.this_type;
  each (d + 1) param x.Meth_lambda.params;
  ret_type (d + 1) x.Meth_lambda.ret_type;
  block (d + 1) x.Meth_lambda.body

and body_field d (x : Body_field.t) =
  line d "body_field" x.Body_field.span;
  name (d + 1) "name" x.Body_field.name;
  type_expr (d + 1) x.Body_field.type_

and mould d (x : Mould.t) =
  match x.Mould.node with
  | Mould.Struct fields ->
      line d "mould Struct" x.Mould.span;
      each (d + 1) body_field fields
  | Mould.Variant fields ->
      line d "mould Variant" x.Mould.span;
      each (d + 1) body_field fields
  | Mould.Enum members ->
      line d "mould Enum" x.Mould.span;
      each (d + 1) (fun d m -> name d "member" m) members

and moulded d (x : Moulded.t) =
  line d "moulded" x.Moulded.span;
  mould (d + 1) x.Moulded.mould;
  type_axis (d + 1) x.Moulded.axis

and type_or_moulded d (x : Type_or_moulded.t) =
  match x.Type_or_moulded.node with
  | Type_or_moulded.Raw t ->
      line d "type_or_moulded Raw" x.Type_or_moulded.span;
      type_expr (d + 1) t
  | Type_or_moulded.Moulded m ->
      line d "type_or_moulded Moulded" x.Type_or_moulded.span;
      moulded (d + 1) m

and constructor_field d (x : Constructor_field.t) =
  line d "constructor_field" x.Constructor_field.span;
  name (d + 1) "name" x.Constructor_field.name;
  param_type (d + 1) x.Constructor_field.type_;
  opt (d + 1) expr x.Constructor_field.default

and constructor_params d (x : Constructor_params.t) =
  match x.Constructor_params.node with
  | Constructor_params.Positional params ->
      line d "constructor_params Positional" x.Constructor_params.span;
      each (d + 1) param params
  | Constructor_params.Fields fields ->
      line d "constructor_params Fields" x.Constructor_params.span;
      each (d + 1) constructor_field fields

and verb_decl d (x : Verb_decl.t) =
  let at = x.Verb_decl.span in
  match x.Verb_decl.node with
  | Verb_decl.Func { name = n; params; ret_type = r; body } ->
      line d "verb_decl Func" at;
      name (d + 1) "name" n;
      each (d + 1) param params;
      ret_type (d + 1) r;
      block (d + 1) body
  | Verb_decl.Meth { name = n; this_type; params; ret_type = r; is_mut; body }
    ->
      line d (if is_mut then "verb_decl Meth mut" else "verb_decl Meth") at;
      name (d + 1) "name" n;
      type_expr (d + 1) this_type;
      each (d + 1) param params;
      ret_type (d + 1) r;
      block (d + 1) body
  | Verb_decl.Op { op; params; ret_type = r; body } ->
      line d "verb_decl Op" at;
      operator (d + 1) op;
      each (d + 1) param params;
      ret_type (d + 1) r;
      block (d + 1) body
  | Verb_decl.Constructor { type_; member; params; body; is_implicit } ->
      line d
        (if is_implicit then "verb_decl Constructor implicit"
         else "verb_decl Constructor")
        at;
      type_expr (d + 1) type_;
      opt (d + 1) (fun d m -> name d "member" m) member;
      constructor_params (d + 1) params;
      block (d + 1) body
  | Verb_decl.Subscript { this_type; params; value } ->
      line d "verb_decl Subscript" at;
      type_expr (d + 1) this_type;
      each (d + 1) param params;
      expr (d + 1) value
  | Verb_decl.Flip { params; ret_type = r; body } ->
      line d "verb_decl Flip" at;
      each (d + 1) param params;
      ret_type (d + 1) r;
      block (d + 1) body

and decl d (x : Decl.t) =
  let at = x.Decl.span in
  match x.Decl.node with
  | Decl.Package n ->
      line d "decl Package" at;
      name (d + 1) "name" n
  | Decl.Import i ->
      line d "decl Import" at;
      import (d + 1) i
  | Decl.Var { name = n; type_; value } ->
      line d "decl Var" at;
      name (d + 1) "name" n;
      type_expr (d + 1) type_;
      expr (d + 1) value
  | Decl.Type { name = n; params; value } ->
      line d "decl Type" at;
      name (d + 1) "name" n;
      each (d + 1) generic_param params;
      type_or_moulded (d + 1) value
  | Decl.Alias { name = n; params; value } ->
      line d "decl Alias" at;
      name (d + 1) "name" n;
      each (d + 1) generic_param params;
      type_or_moulded (d + 1) value
  | Decl.EnumMap { enum; property; type_; entries } ->
      line d "decl EnumMap" at;
      type_expr (d + 1) enum;
      name (d + 1) "property" property;
      type_expr (d + 1) type_;
      List.iter
        (fun (m, v) ->
          name (d + 1) "member" m;
          expr (d + 1) v)
        entries
  | Decl.Verb v ->
      line d "decl Verb" at;
      verb_decl (d + 1) v

(* [source] is the text the spans index into -- the text the CST this tree was
   lowered from was parsed out of, since a desugared node keeps the span of the
   syntax it came from. *)
let render ~source (package : Package.t) =
  printer := Source.Span_text.create source;
  line 0 "package" package.Package.span;
  each 1 decl package.Package.decls;
  Source.Span_text.contents !printer
