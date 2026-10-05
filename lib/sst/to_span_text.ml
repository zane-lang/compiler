(* Every node of the desugared tree, with the source text its span covers.

   [Cst.To_span_text] over the SST, and it answers one more question than that
   one does. Each line carries the node's *variant*, not just its kind, so the
   expectation shows the rewrites of docs/design/desugaring.md having happened:

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

   [render] makes the printer, and every function below is handed it with the
   depth of the lines it writes, as in [Cst.To_span_text]. *)

(* Where a line goes: the printer [render] made, and how deep the line is.
   Every function below takes one and hands a [deeper] one to the parts of
   its node. *)
type cursor = { printer : Source.Span_text.t; depth : int }

let deeper d = { d with depth = d.depth + 1 }
let line d kind span = Source.Span_text.line d.printer d.depth kind span

open Nodes

let name d label (n : Name.t) = line d (label ^ " " ^ n.Name.text) n.Name.span
let opt d f = function None -> () | Some x -> f d x
let each d f xs = List.iter (f d) xs

let name_type d (x : Name_type.t) =
  line d "name_type" x.Name_type.span;
  match x.Name_type.node with
  | Name_type.Ident n -> name (deeper d) "ident" n
  | Name_type.Qualified { package; ident } | Name_type.Intrinsic { package; ident }
    ->
      name (deeper d) "package" package;
      name (deeper d) "ident" ident


let concept d (x : Concept.t) =
  match x.Concept.node with
  | Concept.Type -> line d "concept Type" x.Concept.span
  | Concept.Named n ->
      line d "concept Named" x.Concept.span;
      name_type (deeper d) n

let name_expr d (x : Name_expr.t) =
  line d "name_expr" x.Name_expr.span;
  match x.Name_expr.node with
  | Name_expr.Ident n -> name (deeper d) "ident" n
  | Name_expr.Qualified { package; ident } | Name_expr.Intrinsic { package; ident }
    ->
      name (deeper d) "package" package;
      name (deeper d) "ident" ident

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
  name_type (deeper d) x.Constructor_name.type_;
  opt (deeper d) (fun d m -> name d "member" m) x.Constructor_name.member

let import_member d (x : Import_member.t) =
  line d ("import_member " ^ x.Import_member.name) x.Import_member.span

let import d (x : Import.t) =
  line d "import" x.Import.span;
  match x.Import.node with
  | Import.Package { package; alias } ->
      name (deeper d) "package" package;
      opt (deeper d) (fun d a -> name d "alias" a) alias
  | Import.Member { package; member; alias } ->
      name (deeper d) "package" package;
      import_member (deeper d) member;
      opt (deeper d) import_member alias
  | Import.Members { package; members } ->
      name (deeper d) "package" package;
      each (deeper d) import_member members
  | Import.All { package } -> name (deeper d) "package" package

let type_axis d (x : Type_axis.t) =
  line d
    (match x.Type_axis.node with
    | Type_axis.Value -> "type_axis Value"
    | Type_axis.Reference -> "type_axis Reference")
    x.Type_axis.span

let generic_param d (x : Generic_param.t) =
  line d "generic_param" x.Generic_param.span;
  name (deeper d) "name" x.Generic_param.name;
  concept (deeper d) x.Generic_param.type_

let rec type_expr d (x : Type_expr.t) =
  match x.Type_expr.node with
  | Type_expr.Path { name = n; generics } ->
      line d "type_expr Path" x.Type_expr.span;
      name_type (deeper d) n;
      each (deeper d) generic_arg generics
  | Type_expr.Reference inner ->
      line d "type_expr Reference" x.Type_expr.span;
      type_expr (deeper d) inner
  | Type_expr.Roaming inner ->
      line d "type_expr Roaming" x.Type_expr.span;
      type_expr (deeper d) inner
  | Type_expr.Verb v ->
      line d "type_expr Verb" x.Type_expr.span;
      verb_type (deeper d) v

and generic_arg d (x : Generic_arg.t) =
  match x.Generic_arg.node with
  | Generic_arg.Type t ->
      line d "generic_arg Type" x.Generic_arg.span;
      type_expr (deeper d) t
  | Generic_arg.Number _ -> line d "generic_arg Number" x.Generic_arg.span
  | Generic_arg.NumberRef n ->
      line d "generic_arg NumberRef" x.Generic_arg.span;
      name (deeper d) "name" n
  | Generic_arg.Inferred p ->
      line d "generic_arg Inferred" x.Generic_arg.span;
      param (deeper d) p

and verb_type d (x : Verb_type.t) =
  match x.Verb_type.node with
  | Verb_type.Func { params; ret_type = r } ->
      line d "verb_type Func" x.Verb_type.span;
      each (deeper d) param_type params;
      ret_type (deeper d) r
  | Verb_type.Meth { this_type; params; ret_type = r; is_mut } ->
      line d
        (if is_mut then "verb_type Meth mut" else "verb_type Meth")
        x.Verb_type.span;
      type_expr (deeper d) this_type;
      each (deeper d) param_type params;
      ret_type (deeper d) r

and ret_type d (x : Ret_type.t) =
  match x.Ret_type.node with
  | Ret_type.Safe t ->
      line d "ret_type Safe" x.Ret_type.span;
      type_expr (deeper d) t
  | Ret_type.Abort { ok; abort } ->
      line d "ret_type Abort" x.Ret_type.span;
      type_expr (deeper d) ok;
      type_expr (deeper d) abort

and param_type d (x : Param_type.t) =
  match x.Param_type.node with
  | Param_type.Concrete t ->
      line d "param_type Concrete" x.Param_type.span;
      type_expr (deeper d) t
  | Param_type.Concept c ->
      line d "param_type Concept" x.Param_type.span;
      concept (deeper d) c
  | Param_type.InferredType { name = n; concept = c; _ } ->
      line d "param_type InferredType" x.Param_type.span;
      name (deeper d) "name" n;
      concept (deeper d) c

and param d (x : Param.t) =
  line d "param" x.Param.span;
  name (deeper d) "name" x.Param.name;
  param_type (deeper d) x.Param.type_

(* Never [None] any more: a bare `x` was written out into `x = x`, and the
   synthesized value prints under it spanning just the name. *)
and field_arg d (x : Field_arg.t) =
  line d "field_arg" x.Field_arg.span;
  name (deeper d) "name" x.Field_arg.name;
  expr (deeper d) x.Field_arg.value

and expr d (x : Expr.t) =
  let at = x.Expr.span in
  match x.Expr.node with
  | Expr.IntLit _ -> line d "expr IntLit" at
  | Expr.DecimalLit _ -> line d "expr DecimalLit" at
  | Expr.StrLit _ -> line d "expr StrLit" at
  | Expr.BoolLit _ -> line d "expr BoolLit" at
  | Expr.CollectionLit items ->
      line d "expr CollectionLit" at;
      each (deeper d) expr items
  | Expr.NameExpr n ->
      line d "expr NameExpr" at;
      name_expr (deeper d) n
  | Expr.TypeMember { type_; member } ->
      line d "expr TypeMember" at;
      name_type (deeper d) type_;
      name (deeper d) "member" member
  | Expr.TypeValue t ->
      line d "expr TypeValue" at;
      name_type (deeper d) t
  | Expr.DotAccess { target; field; abort_handle } ->
      line d "expr DotAccess" at;
      expr (deeper d) target;
      name (deeper d) "field" field;
      opt (deeper d) abort_handle_ abort_handle
  | Expr.Subscript { target; args } ->
      line d "expr Subscript" at;
      expr (deeper d) target;
      each (deeper d) expr args
  | Expr.Ref inner ->
      line d "expr Ref" at;
      expr (deeper d) inner
  | Expr.Init fields ->
      line d "expr Init" at;
      each (deeper d) field_arg fields
  | Expr.MapLit entries ->
      line d "expr MapLit" at;
      List.iter
        (fun (k, v) ->
          expr (deeper d) k;
          expr (deeper d) v)
        entries
  | Expr.Spawn call ->
      line d "expr Spawn" at;
      verb_call (deeper d) call
  | Expr.Match m ->
      line d "expr Match" at;
      match_expr (deeper d) m
  | Expr.VerbCall call ->
      line d "expr VerbCall" at;
      verb_call (deeper d) call
  | Expr.FuncLambda l ->
      line d "expr FuncLambda" at;
      func_lambda (deeper d) l
  | Expr.MethLambda l ->
      line d "expr MethLambda" at;
      meth_lambda (deeper d) l

and call_arg d (x : Call_arg.t) =
  match x.Call_arg.node with
  | Call_arg.Value v ->
      line d "call_arg Value" x.Call_arg.span;
      expr (deeper d) v
  | Call_arg.Block b ->
      line d "call_arg Block" x.Call_arg.span;
      block (deeper d) b

and constructor_args d (x : Constructor_args.t) =
  match x.Constructor_args.node with
  | Constructor_args.Positional args ->
      line d "constructor_args Positional" x.Constructor_args.span;
      each (deeper d) call_arg args
  | Constructor_args.Fields fields ->
      line d "constructor_args Fields" x.Constructor_args.span;
      each (deeper d) field_arg fields

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
      expr (deeper d) callee;
      each (deeper d) call_arg args;
      opt (deeper d) abort_handle_ abort_handle
  | Verb_call.Constructor { name = n; args; abort_handle } ->
      line d "verb_call Constructor" at;
      constructor_name (deeper d) n;
      constructor_args (deeper d) args;
      opt (deeper d) abort_handle_ abort_handle
  | Verb_call.Op { op; left; right; swapped; abort_handle } ->
      line d (if swapped then "verb_call Op swapped" else "verb_call Op") at;
      operator (deeper d) op;
      expr (deeper d) left;
      expr (deeper d) right;
      opt (deeper d) abort_handle_ abort_handle
  | Verb_call.Flip { value; abort_handle } ->
      line d "verb_call Flip" at;
      expr (deeper d) value;
      opt (deeper d) abort_handle_ abort_handle

(* Named with a trailing underscore because [Abort_handle] is a module in
   scope and the walker below wants the shorter name for its own use. *)
and abort_handle_ d (x : Abort_handle.t) =
  line d "abort_handle" x.Abort_handle.span;
  opt (deeper d) (fun d b -> name d "binder" b) x.Abort_handle.binder;
  block (deeper d) x.Abort_handle.body

and match_pattern d (x : Match_pattern.t) =
  line d "match_pattern" x.Match_pattern.span;
  opt (deeper d) (fun d b -> name d "binder" b) x.Match_pattern.binder;
  name (deeper d) "case" x.Match_pattern.case

and match_arm d (x : Match_arm.t) =
  line d "match_arm" x.Match_arm.span;
  each (deeper d) match_pattern x.Match_arm.patterns;
  block (deeper d) x.Match_arm.body

and match_expr d (x : Match_expr.t) =
  line d "match_expr" x.Match_expr.span;
  each (deeper d) expr x.Match_expr.scrutinees;
  each (deeper d) match_arm x.Match_expr.arms;
  opt (deeper d) abort_handle_ x.Match_expr.abort_handle

and block d (x : Block.t) =
  line d "block" x.Block.span;
  each (deeper d) stat x.Block.stats

and stat d (x : Stat.t) =
  let at = x.Stat.span in
  match x.Stat.node with
  | Stat.VerbCall call ->
      line d "stat VerbCall" at;
      verb_call (deeper d) call
  | Stat.Spawn call ->
      line d "stat Spawn" at;
      verb_call (deeper d) call
  | Stat.Decl value ->
      line d "stat Decl" at;
      decl (deeper d) value
  | Stat.Assign { target; value } ->
      line d "stat Assign" at;
      expr (deeper d) target;
      expr (deeper d) value
  | Stat.Abort value ->
      line d "stat Abort" at;
      expr (deeper d) value
  | Stat.Ret value ->
      line d "stat Ret" at;
      expr (deeper d) value
  | Stat.Resolve value ->
      line d "stat Resolve" at;
      expr (deeper d) value

and func_lambda d (x : Func_lambda.t) =
  line d "func_lambda" x.Func_lambda.span;
  each (deeper d) param x.Func_lambda.params;
  ret_type (deeper d) x.Func_lambda.ret_type;
  block (deeper d) x.Func_lambda.body

and meth_lambda d (x : Meth_lambda.t) =
  line d
    (if x.Meth_lambda.is_mut then "meth_lambda mut" else "meth_lambda")
    x.Meth_lambda.span;
  type_expr (deeper d) x.Meth_lambda.this_type;
  each (deeper d) param x.Meth_lambda.params;
  ret_type (deeper d) x.Meth_lambda.ret_type;
  block (deeper d) x.Meth_lambda.body

and body_field d (x : Body_field.t) =
  line d "body_field" x.Body_field.span;
  name (deeper d) "name" x.Body_field.name;
  type_expr (deeper d) x.Body_field.type_

and mould d (x : Mould.t) =
  match x.Mould.node with
  | Mould.Struct fields ->
      line d "mould Struct" x.Mould.span;
      each (deeper d) body_field fields
  | Mould.Variant fields ->
      line d "mould Variant" x.Mould.span;
      each (deeper d) body_field fields
  | Mould.Enum members ->
      line d "mould Enum" x.Mould.span;
      each (deeper d) (fun d m -> name d "member" m) members

and moulded d (x : Moulded.t) =
  line d "moulded" x.Moulded.span;
  mould (deeper d) x.Moulded.mould;
  type_axis (deeper d) x.Moulded.axis

and type_or_moulded d (x : Type_or_moulded.t) =
  match x.Type_or_moulded.node with
  | Type_or_moulded.Raw t ->
      line d "type_or_moulded Raw" x.Type_or_moulded.span;
      type_expr (deeper d) t
  | Type_or_moulded.Moulded m ->
      line d "type_or_moulded Moulded" x.Type_or_moulded.span;
      moulded (deeper d) m

and constructor_field d (x : Constructor_field.t) =
  line d "constructor_field" x.Constructor_field.span;
  name (deeper d) "name" x.Constructor_field.name;
  param_type (deeper d) x.Constructor_field.type_;
  opt (deeper d) expr x.Constructor_field.default

and constructor_params d (x : Constructor_params.t) =
  match x.Constructor_params.node with
  | Constructor_params.Positional params ->
      line d "constructor_params Positional" x.Constructor_params.span;
      each (deeper d) param params
  | Constructor_params.Fields fields ->
      line d "constructor_params Fields" x.Constructor_params.span;
      each (deeper d) constructor_field fields

and verb_decl d (x : Verb_decl.t) =
  let at = x.Verb_decl.span in
  match x.Verb_decl.node with
  | Verb_decl.Func { name = n; params; ret_type = r; body } ->
      line d "verb_decl Func" at;
      name (deeper d) "name" n;
      each (deeper d) param params;
      ret_type (deeper d) r;
      block (deeper d) body
  | Verb_decl.Meth { name = n; this_type; params; ret_type = r; is_mut; body }
    ->
      line d (if is_mut then "verb_decl Meth mut" else "verb_decl Meth") at;
      name (deeper d) "name" n;
      type_expr (deeper d) this_type;
      each (deeper d) param params;
      ret_type (deeper d) r;
      block (deeper d) body
  | Verb_decl.Op { op; params; ret_type = r; body } ->
      line d "verb_decl Op" at;
      operator (deeper d) op;
      each (deeper d) param params;
      ret_type (deeper d) r;
      block (deeper d) body
  | Verb_decl.Constructor { type_; member; params; body; is_implicit } ->
      line d
        (if is_implicit then "verb_decl Constructor implicit"
         else "verb_decl Constructor")
        at;
      type_expr (deeper d) type_;
      opt (deeper d) (fun d m -> name d "member" m) member;
      constructor_params (deeper d) params;
      block (deeper d) body
  | Verb_decl.Subscript { this_type; params; value } ->
      line d "verb_decl Subscript" at;
      type_expr (deeper d) this_type;
      each (deeper d) param params;
      expr (deeper d) value
  | Verb_decl.Flip { params; ret_type = r; body } ->
      line d "verb_decl Flip" at;
      each (deeper d) param params;
      ret_type (deeper d) r;
      block (deeper d) body

and decl d (x : Decl.t) =
  let at = x.Decl.span in
  match x.Decl.node with
  | Decl.Package n ->
      line d "decl Package" at;
      name (deeper d) "name" n
  | Decl.Import i ->
      line d "decl Import" at;
      import (deeper d) i
  | Decl.Var { name = n; type_; value } ->
      line d "decl Var" at;
      name (deeper d) "name" n;
      type_expr (deeper d) type_;
      expr (deeper d) value
  | Decl.Type { name = n; params; value } ->
      line d "decl Type" at;
      name (deeper d) "name" n;
      each (deeper d) generic_param params;
      type_or_moulded (deeper d) value
  | Decl.Alias { name = n; params; value } ->
      line d "decl Alias" at;
      name (deeper d) "name" n;
      each (deeper d) generic_param params;
      type_or_moulded (deeper d) value
  | Decl.EnumMap { enum; property; type_; entries } ->
      line d "decl EnumMap" at;
      type_expr (deeper d) enum;
      name (deeper d) "property" property;
      type_expr (deeper d) type_;
      List.iter
        (fun (m, v) ->
          name (deeper d) "member" m;
          expr (deeper d) v)
        entries
  | Decl.Verb v ->
      line d "decl Verb" at;
      verb_decl (deeper d) v

(* [source] is the text the spans index into -- the text the CST this tree was
   lowered from was parsed out of, since a desugared node keeps the span of the
   syntax it came from. *)
let render ~source (package : Package.t) =
  let d = { printer = Source.Span_text.create source; depth = 0 } in
  line d "package" package.Package.span;
  each (deeper d) decl package.Package.decls;
  Source.Span_text.contents d.printer
