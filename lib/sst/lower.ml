(* CST to SST: every shorthand written out, and nothing else changed.

   The rewrites are inventoried in docs/desugaring.md; this file applies them.
   Everything not listed there is a walk that rebuilds the node as it found it,
   which is most of what follows -- the interesting lines are the ones with a
   comment naming the section they implement.

   Two rules hold throughout.

   **Spans.** Every node this pass synthesizes takes the span of the surface
   syntax it was desugared from, so [Span.none] is never needed and every node
   in the result still points at real source. That is what lets the same
   check-a-span-against-its-source test run over this tree as over the CST.

   **No lookups.** Nothing here reads a declaration, a type, or a resolved
   name. A rewrite that would need one is not in docs/desugaring.md §2, and the
   reason it is not is recorded in §4. *)

module C = Cst.Nodes
module S = Nodes
module Span = Source.Span

(* ---------------------------------------------------------------------- *)
(* Leaves reused from the CST pass through by identity. Named rather than  *)
(* inlined so a reader can see which ones they are.                        *)
(* ---------------------------------------------------------------------- *)

let name (x : C.Name.t) : S.Name.t = x
let name_type (x : C.Name_type.t) : S.Name_type.t = x
let name_expr (x : C.Name_expr.t) : S.Name_expr.t = x
let concept (x : C.Concept.t) : S.Concept.t = x
let type_axis (x : C.Type_axis.t) : S.Type_axis.t = x
let import (x : C.Import.t) : S.Import.t = x
let constructor_name (x : C.Constructor_name.t) : S.Constructor_name.t = x
let generic_param (x : C.Generic_param.t) : S.Generic_param.t = x

let option f = function None -> None | Some x -> Some (f x)

(* ---------------------------------------------------------------------- *)
(* Constructors for synthesized nodes. Each takes the span it is to carry  *)
(* explicitly, because choosing that span is the decision worth seeing at  *)
(* the call site.                                                          *)
(* ---------------------------------------------------------------------- *)

let expr span node : S.Expr.t = { S.Expr.node; span }
let stat span node : S.Stat.t = { S.Stat.node; span }
let verb_call span node : S.Verb_call.t = { S.Verb_call.node; span }
let call_expr span node = expr span (S.Expr.VerbCall (verb_call span node))

(* `~value`, as a whole expression. *)
let flip span value =
  call_expr span (S.Verb_call.Flip { value; abort_handle = None })

(* ---------------------------------------------------------------------- *)
(* Types                                                                   *)
(* ---------------------------------------------------------------------- *)

let rec type_expr (x : C.Type_expr.t) : S.Type_expr.t =
  let span = x.C.Type_expr.span in
  match x.C.Type_expr.node with
  (* §2.8: parentheses only group, and the grouping is already the tree. The
     inner node is returned with its own span, which covers what is inside the
     parentheses rather than them too. *)
  | C.Type_expr.Parenthesized inner -> type_expr inner
  | C.Type_expr.Path { name = n; generics } ->
      {
        S.Type_expr.span;
        node =
          S.Type_expr.Path
            { name = name_type n; generics = List.map generic_arg generics };
      }
  | C.Type_expr.Guest inner ->
      { S.Type_expr.span; node = S.Type_expr.Guest (type_expr inner) }
  | C.Type_expr.Verb v ->
      { S.Type_expr.span; node = S.Type_expr.Verb (verb_type v) }

and generic_arg (x : C.Generic_arg.t) : S.Generic_arg.t =
  let span = x.C.Generic_arg.span in
  let node =
    match x.C.Generic_arg.node with
    | C.Generic_arg.Type t -> S.Generic_arg.Type (type_expr t)
    | C.Generic_arg.Number n -> S.Generic_arg.Number n
    | C.Generic_arg.NumberRef n -> S.Generic_arg.NumberRef (name n)
    | C.Generic_arg.Inferred p -> S.Generic_arg.Inferred (param p)
  in
  { S.Generic_arg.node; span }

and verb_type (x : C.Verb_type.t) : S.Verb_type.t =
  let span = x.C.Verb_type.span in
  let node =
    match x.C.Verb_type.node with
    | C.Verb_type.Func { params; ret_type = r } ->
        S.Verb_type.Func
          { params = List.map param_type params; ret_type = ret_type r }
    | C.Verb_type.Meth { this_type; params; ret_type = r; is_mut } ->
        S.Verb_type.Meth
          {
            this_type = type_expr this_type;
            params = List.map param_type params;
            ret_type = ret_type r;
            is_mut;
          }
  in
  { S.Verb_type.node; span }

and ret_type (x : C.Ret_type.t) : S.Ret_type.t =
  let span = x.C.Ret_type.span in
  match x.C.Ret_type.node with
  (* §2.8, as for [Type_expr]. *)
  | C.Ret_type.Parenthesized inner -> ret_type inner
  | C.Ret_type.Safe t -> { S.Ret_type.span; node = S.Ret_type.Safe (type_expr t) }
  | C.Ret_type.Abort { ok; abort } ->
      {
        S.Ret_type.span;
        node = S.Ret_type.Abort { ok = type_expr ok; abort = type_expr abort };
      }

and param_type (x : C.Param_type.t) : S.Param_type.t =
  let span = x.C.Param_type.span in
  let node =
    match x.C.Param_type.node with
    | C.Param_type.Concrete t -> S.Param_type.Concrete (type_expr t)
    | C.Param_type.Concept c -> S.Param_type.Concept (concept c)
    | C.Param_type.InferredType { name = n; concept = c } ->
        S.Param_type.InferredType { name = name n; concept = concept c }
  in
  { S.Param_type.node; span }

and param (x : C.Param.t) : S.Param.t =
  {
    S.Param.name = name x.C.Param.name;
    type_ = param_type x.C.Param.type_;
    span = x.C.Param.span;
  }

(* ---------------------------------------------------------------------- *)
(* Expressions                                                             *)
(* ---------------------------------------------------------------------- *)

and expression (x : C.Expr.t) : S.Expr.t =
  let span = x.C.Expr.span in
  match x.C.Expr.node with
  (* §2.8. *)
  | C.Expr.Parenthized inner -> expression inner
  | node ->
      let node =
        match node with
        | C.Expr.Parenthized _ -> assert false
        | C.Expr.IntLit s -> S.Expr.IntLit s
        | C.Expr.FloatLit s -> S.Expr.FloatLit s
        | C.Expr.StrLit s -> S.Expr.StrLit s
        | C.Expr.BoolLit b -> S.Expr.BoolLit b
        | C.Expr.CollectionLit items ->
            S.Expr.CollectionLit (List.map expression items)
        | C.Expr.NameExpr n -> S.Expr.NameExpr (name_expr n)
        | C.Expr.TypeMember { type_; member } ->
            S.Expr.TypeMember
              { type_ = name_type type_; member = name member }
        | C.Expr.TypeValue t -> S.Expr.TypeValue (name_type t)
        | C.Expr.DotAccess { target; field } ->
            S.Expr.DotAccess { target = expression target; field = name field }
        | C.Expr.Subscript { target; args } ->
            S.Expr.Subscript
              { target = expression target; args = List.map expression args }
        | C.Expr.Ref inner -> S.Expr.Ref (expression inner)
        | C.Expr.Init fields -> S.Expr.Init (List.map field_arg fields)
        | C.Expr.MapLit entries ->
            S.Expr.MapLit
              (List.map (fun (k, v) -> (expression k, expression v)) entries)
        | C.Expr.Spawn call -> S.Expr.Spawn (verb_call_of call)
        | C.Expr.Match m -> S.Expr.Match (match_expr m)
        | C.Expr.VerbCall call -> S.Expr.VerbCall (verb_call_of call)
        | C.Expr.FuncLambda l -> S.Expr.FuncLambda (func_lambda l)
        | C.Expr.MethLambda l -> S.Expr.MethLambda (meth_lambda l)
      in
      { S.Expr.node; span }

(* §2.6: a bare `x` in an `init{ }` or at a field-constructor call site is
   shorthand for `x = x`. The synthesized right-hand side takes the field
   name's span, which is the whole of what was written for it. *)
and field_arg (x : C.Field_arg.t) : S.Field_arg.t =
  let field = name x.C.Field_arg.name in
  let value =
    match x.C.Field_arg.value with
    | Some written -> expression written
    | None ->
        let at = field.C.Name.span in
        expr at
          (S.Expr.NameExpr { C.Name_expr.node = C.Name_expr.Ident field; span = at })
  in
  { S.Field_arg.name = field; value; span = x.C.Field_arg.span }

and call_arg (x : C.Call_arg.t) : S.Call_arg.t =
  let span = x.C.Call_arg.span in
  let node =
    match x.C.Call_arg.node with
    | C.Call_arg.Value v -> S.Call_arg.Value (expression v)
    | C.Call_arg.Block stats ->
        S.Call_arg.Block { S.Block.stats = List.map statement stats; span }
  in
  { S.Call_arg.node; span }

and constructor_args (x : C.Constructor_args.t) : S.Constructor_args.t =
  let span = x.C.Constructor_args.span in
  let node =
    match x.C.Constructor_args.node with
    | C.Constructor_args.Positional args ->
        S.Constructor_args.Positional (List.map call_arg args)
    | C.Constructor_args.Fields fields ->
        S.Constructor_args.Fields (List.map field_arg fields)
  in
  { S.Constructor_args.node; span }

(* §2.4: `expr ?? fallback` is a handler whose only path resolves the fallback.

   The binder stays [None]: `??` writes one nowhere, and the body this
   synthesizes does not mention one. Both the block and its single statement
   take the handler's span, which covers the `?? fallback` that produced
   them. *)
and handler (x : C.Abort_handle.t) : S.Abort_handle.t =
  let span = x.C.Abort_handle.span in
  match x.C.Abort_handle.node with
  | C.Abort_handle.Longhand { binder; body } ->
      { S.Abort_handle.binder = option name binder; body = block body; span }
  | C.Abort_handle.Shorthand fallback ->
      let resolved = stat span (S.Stat.Resolve (expression fallback)) in
      {
        S.Abort_handle.binder = None;
        body = { S.Block.stats = [ resolved ]; span };
        span;
      }

(* ---------------------------------------------------------------------- *)
(* Calls                                                                   *)
(* ---------------------------------------------------------------------- *)

and verb_call_of (x : C.Verb_call.t) : S.Verb_call.t =
  let span = x.C.Verb_call.span in
  match x.C.Verb_call.node with
  (* §2.9: [trailing] is dropped. The two spellings are the same call; the
     flag recorded that they do not end the same way, which is a question
     [Cst.Statement_check] has already answered. *)
  | C.Verb_call.Func { callee; args; abort_handle; trailing = _ } ->
      verb_call span
        (S.Verb_call.Call
           {
             callee = expression callee;
             args = List.map call_arg args;
             form = S.Call_form.Function;
             abort_handle = option handler abort_handle;
           })
  (* §5.3: the subject becomes the first argument, which is what
     functions.md §2.6 desugars it to and what §2.1 means by a method being a
     verb whose first parameter is `this`. The marker stays on the call: it
     decides how the name resolves, and `:` against `!` is a check a later
     pass makes against the declaration. *)
  | C.Verb_call.Meth { callee; this; args; abort_handle; is_mut; trailing = _ }
    ->
      let subject = expression this in
      let subject_arg =
        { S.Call_arg.node = S.Call_arg.Value subject; span = subject.S.Expr.span }
      in
      verb_call span
        (S.Verb_call.Call
           {
             callee = expression callee;
             args = subject_arg :: List.map call_arg args;
             form = S.Call_form.Method { is_mut };
             abort_handle = option handler abort_handle;
           })
  | C.Verb_call.Constructor { name = n; args; abort_handle; trailing = _ } ->
      verb_call span
        (S.Verb_call.Constructor
           {
             name = constructor_name n;
             args = constructor_args args;
             abort_handle = option handler abort_handle;
           })
  | C.Verb_call.Flip { value; abort_handle } ->
      verb_call span
        (S.Verb_call.Flip
           {
             value = expression value;
             abort_handle = option handler abort_handle;
           })
  | C.Verb_call.Op { op; left; right; abort_handle } ->
      derived_op span op (expression left) (expression right)
        ~written_right:right.C.Expr.span
        (option handler abort_handle)

(* §2.3: the five derived operators of operators.md §2.3, written out into the
   primitives they are defined as.

   The operator node keeps the span of the operator the author typed, so the
   `<` of a lowered `a >= b` spans the `>=`. Every synthesized node around it
   takes the whole expression's span, since the whole expression is what became
   them.

   The handler goes on the outermost node. A handler is written against the
   expression as a whole, and after the rewrite the outermost node is what that
   expression became.

   Two of the five -- `>` and `<=` -- evaluate the written right operand first,
   because `b < a` is what the spec defines them as. The spec fixes no operand
   evaluation order for operators, so nothing here is contradicted; see
   docs/desugaring.md §5.1, which is the open question this implements one
   answer to. *)
and derived_op span (op : C.Operator.t) left right ~written_right abort_handle
    : S.Verb_call.t =
  let at = op.C.Operator.span in
  let primitive node : S.Operator.t = { S.Operator.node; span = at } in
  let binop ?(handle = abort_handle) node l r =
    S.Verb_call.Op { op = primitive node; left = l; right = r;
                     abort_handle = handle }
  in
  match op.C.Operator.node with
  | C.Operator.Add -> verb_call span (binop S.Operator.Add left right)
  | C.Operator.Mul -> verb_call span (binop S.Operator.Mul left right)
  | C.Operator.Div -> verb_call span (binop S.Operator.Div left right)
  | C.Operator.Eq -> verb_call span (binop S.Operator.Eq left right)
  | C.Operator.Less -> verb_call span (binop S.Operator.Less left right)
  (* `a - b` is `a + ~b`. The flip spans `- b`, which is the text it was made
     from; `a` and `b` keep their own spans either side of it.

     The join reaches for the operand's span *as written*, not the lowered
     one. They differ exactly when the operand is parenthesized: lowering has
     already dropped the parentheses by this point, so the lowered `(b)` spans
     only `b`, and joining with that would end the flip inside the brackets --
     `- (b`, which is not text anyone wrote. *)
  | C.Operator.Sub ->
      let negated = flip (Span.join at written_right) right in
      verb_call span (binop S.Operator.Add left negated)
  (* `a ~= b` is `~(a == b)`. *)
  | C.Operator.NotEq ->
      let equal = call_expr span (binop ~handle:None S.Operator.Eq left right) in
      verb_call span
        (S.Verb_call.Flip { value = equal; abort_handle })
  (* `a > b` is `b < a`. *)
  | C.Operator.More -> verb_call span (binop S.Operator.Less right left)
  (* `a <= b` is `~(b < a)`. *)
  | C.Operator.LessEq ->
      let less = call_expr span (binop ~handle:None S.Operator.Less right left) in
      verb_call span (S.Verb_call.Flip { value = less; abort_handle })
  (* `a >= b` is `~(a < b)`. *)
  | C.Operator.MoreEq ->
      let less = call_expr span (binop ~handle:None S.Operator.Less left right) in
      verb_call span (S.Verb_call.Flip { value = less; abort_handle })

(* ---------------------------------------------------------------------- *)
(* Match                                                                   *)
(* ---------------------------------------------------------------------- *)

and match_expr (x : C.Match_expr.t) : S.Match_expr.t =
  {
    S.Match_expr.scrutinees = List.map expression x.C.Match_expr.scrutinees;
    arms = List.concat_map match_arm x.C.Match_expr.arms;
    abort_handle = option handler x.C.Match_expr.abort_handle;
    span = x.C.Match_expr.span;
  }

(* §2.5: a `[ ]` group is one arm per listed case, and with several scrutinees
   that is the cross product of their groups.

   The bodies are not copied. OCaml shares them, so the expansion costs one
   arm record per combination and no more; what multiplies is the number of
   arms, which is what the spec asks for -- each expanded arm binds the binder
   "at *its own* case's payload" (adt.md §5.1), so each has to be checked
   separately whatever the tree does.

   Every expanded pattern takes the written pattern's whole span, `x [a, b]`,
   because that is the syntax it came from; the one case it selects keeps its
   own span, which is what a "case not covered" diagnostic points at. *)
and match_arm (x : C.Match_arm.t) : S.Match_arm.t list =
  let body = block x.C.Match_arm.body in
  let span = x.C.Match_arm.span in
  let rec combinations (patterns : C.Match_pattern.t list) =
    match patterns with
    | [] -> [ [] ]
    | pattern :: rest ->
        let binder = option name pattern.C.Match_pattern.binder in
        let at = pattern.C.Match_pattern.span in
        let tails = combinations rest in
        (* [match_selector] is a non-empty list in the grammar, so a pattern
           always selects at least one case. Were it ever empty the product
           below would silently drop the arm, which is the one outcome worth
           refusing outright. *)
        (match pattern.C.Match_pattern.cases with
        | [] -> invalid_arg "Sst.Lower: a match pattern selects no case"
        | cases ->
            List.concat_map
              (fun case ->
                let head = { S.Match_pattern.binder; case = name case; span = at } in
                List.map (fun tail -> head :: tail) tails)
              cases)
  in
  List.map
    (fun patterns -> { S.Match_arm.patterns; body; span })
    (combinations x.C.Match_arm.patterns)

(* ---------------------------------------------------------------------- *)
(* Statements and bodies                                                   *)
(* ---------------------------------------------------------------------- *)

(* §2.1: `=> expr` "means exactly `{ return expr }`".

   The synthesized block and its `return` both take the body's span, which
   covers the `=> expr` they were made from. *)
and block (x : C.Body.t) : S.Block.t =
  let span = x.C.Body.span in
  match x.C.Body.node with
  | C.Body.Longhand stats ->
      { S.Block.stats = List.map statement stats; span }
  | C.Body.Shorthand value ->
      { S.Block.stats = [ stat span (S.Stat.Ret (expression value)) ]; span }

(* §2.10: the [Statement.t] wrapper is dropped. It paired a statement with how
   its terminator disagreed with the rules, and [Cst.parse] refuses a package
   carrying any such disagreement, so every one is [None] here. The `;` goes
   with it: a [Stat.t]'s span covers the statement, not the mark that ended
   it. *)
and statement (x : C.Statement.t) : S.Stat.t =
  let inner = x.C.Statement.stat in
  let span = inner.C.Stat.span in
  let node =
    match inner.C.Stat.node with
    | C.Stat.VerbCall call -> S.Stat.VerbCall (verb_call_of call)
    | C.Stat.Spawn call -> S.Stat.Spawn (verb_call_of call)
    | C.Stat.Decl d -> S.Stat.Decl (declaration d)
    | C.Stat.Assign { target; value } ->
        S.Stat.Assign { target = expression target; value = expression value }
    | C.Stat.Abort value -> S.Stat.Abort (expression value)
    | C.Stat.Ret value -> S.Stat.Ret (expression value)
    | C.Stat.Resolve value -> S.Stat.Resolve (expression value)
  in
  { S.Stat.node; span }

(* ---------------------------------------------------------------------- *)
(* Lambdas                                                                 *)
(* ---------------------------------------------------------------------- *)

and func_lambda (x : C.Func_lambda.t) : S.Func_lambda.t =
  {
    S.Func_lambda.params = List.map param x.C.Func_lambda.params;
    ret_type = ret_type x.C.Func_lambda.ret_type;
    body = block x.C.Func_lambda.body;
    span = x.C.Func_lambda.span;
  }

and meth_lambda (x : C.Meth_lambda.t) : S.Meth_lambda.t =
  {
    S.Meth_lambda.this_type = type_expr x.C.Meth_lambda.this_type;
    params = List.map param x.C.Meth_lambda.params;
    ret_type = ret_type x.C.Meth_lambda.ret_type;
    is_mut = x.C.Meth_lambda.is_mut;
    body = block x.C.Meth_lambda.body;
    span = x.C.Meth_lambda.span;
  }

(* ---------------------------------------------------------------------- *)
(* Type bodies                                                             *)
(* ---------------------------------------------------------------------- *)

and body_field (x : C.Body_field.t) : S.Body_field.t =
  {
    S.Body_field.name = name x.C.Body_field.name;
    type_ = type_expr x.C.Body_field.type_;
    span = x.C.Body_field.span;
  }

and mould (x : C.Mould.t) : S.Mould.t =
  let span = x.C.Mould.span in
  let node =
    match x.C.Mould.node with
    | C.Mould.Struct fields -> S.Mould.Struct (List.map body_field fields)
    | C.Mould.Variant fields -> S.Mould.Variant (List.map body_field fields)
    | C.Mould.Enum members -> S.Mould.Enum (List.map name members)
  in
  { S.Mould.node; span }

and moulded (x : C.Moulded.t) : S.Moulded.t =
  {
    S.Moulded.mould = mould x.C.Moulded.mould;
    axis = type_axis x.C.Moulded.axis;
    span = x.C.Moulded.span;
  }

and type_or_moulded (x : C.Type_or_moulded.t) : S.Type_or_moulded.t =
  let span = x.C.Type_or_moulded.span in
  let node =
    match x.C.Type_or_moulded.node with
    | C.Type_or_moulded.Raw t -> S.Type_or_moulded.Raw (type_expr t)
    | C.Type_or_moulded.Moulded m -> S.Type_or_moulded.Moulded (moulded m)
  in
  { S.Type_or_moulded.node; span }

(* ---------------------------------------------------------------------- *)
(* Declarations                                                            *)
(* ---------------------------------------------------------------------- *)

and constructor_field (x : C.Constructor_field.t) : S.Constructor_field.t =
  {
    S.Constructor_field.name = name x.C.Constructor_field.name;
    type_ = param_type x.C.Constructor_field.type_;
    default = option expression x.C.Constructor_field.default;
    span = x.C.Constructor_field.span;
  }

and constructor_params (x : C.Constructor_params.t) : S.Constructor_params.t =
  let span = x.C.Constructor_params.span in
  let node =
    match x.C.Constructor_params.node with
    | C.Constructor_params.Positional params ->
        S.Constructor_params.Positional (List.map param params)
    | C.Constructor_params.Fields fields ->
        S.Constructor_params.Fields (List.map constructor_field fields)
  in
  { S.Constructor_params.node; span }

and verb_decl (x : C.Verb_decl.t) : S.Verb_decl.t =
  let span = x.C.Verb_decl.span in
  let node =
    match x.C.Verb_decl.node with
    | C.Verb_decl.Func { name = n; params; ret_type = r; body = b } ->
        S.Verb_decl.Func
          {
            name = name n;
            params = List.map param params;
            ret_type = ret_type r;
            body = block b;
          }
    | C.Verb_decl.Meth { name = n; this_type; params; ret_type = r; is_mut;
                         body = b } ->
        S.Verb_decl.Meth
          {
            name = name n;
            this_type = type_expr this_type;
            params = List.map param params;
            ret_type = ret_type r;
            is_mut;
            body = block b;
          }
    (* The grammar admits only the primitive operators here, so the derived
       rewrite above has no declaration to contradict. See
       docs/desugaring.md §3. *)
    | C.Verb_decl.Op { op; params; ret_type = r; body = b } ->
        S.Verb_decl.Op
          {
            op = declared_operator op;
            params = List.map param params;
            ret_type = ret_type r;
            body = block b;
          }
    | C.Verb_decl.Constructor { type_; member; params; body = b; is_implicit }
      ->
        S.Verb_decl.Constructor
          {
            type_ = type_expr type_;
            member = option name member;
            params = constructor_params params;
            body = block b;
            is_implicit;
          }
    | C.Verb_decl.Subscript { this_type; params; value } ->
        S.Verb_decl.Subscript
          {
            this_type = type_expr this_type;
            params = List.map param params;
            value = expression value;
          }
    | C.Verb_decl.Flip { params; ret_type = r; body = b } ->
        S.Verb_decl.Flip
          {
            params = List.map param params;
            ret_type = ret_type r;
            body = block b;
          }
  in
  { S.Verb_decl.node; span }

(* An operator in declaration position. The grammar accepts only the five
   binary primitives there (docs/desugaring.md §3), so the derived cases cannot
   arise -- and are refused rather than mapped to something, because silently
   turning a declared `>` into a declared `<` would put back exactly the
   unreachable declaration that guard exists to prevent. *)
and declared_operator (x : C.Operator.t) : S.Operator.t =
  let span = x.C.Operator.span in
  let node =
    match x.C.Operator.node with
    | C.Operator.Add -> S.Operator.Add
    | C.Operator.Mul -> S.Operator.Mul
    | C.Operator.Div -> S.Operator.Div
    | C.Operator.Eq -> S.Operator.Eq
    | C.Operator.Less -> S.Operator.Less
    | C.Operator.Sub | C.Operator.NotEq | C.Operator.More | C.Operator.LessEq
    | C.Operator.MoreEq ->
        invalid_arg
          "Sst.Lower: a derived operator reached a declaration; the grammar \
           admits only the primitives there"
  in
  { S.Operator.node; span }

and declaration (x : C.Decl.t) : S.Decl.t =
  let span = x.C.Decl.span in
  let node =
    match x.C.Decl.node with
    | C.Decl.Package n -> S.Decl.Package (name n)
    | C.Decl.Import i -> S.Decl.Import (import i)
    | C.Decl.Var { name = n; type_; value } ->
        S.Decl.Var
          {
            name = name n;
            type_ = type_expr type_;
            value = expression value;
          }
    (* §2.7: `e Expr.intLit("5")` is `e Expr = Expr.intLit("5")`.

       The declared type is the constructor's *base* type -- syntax.md §1.1:
       "the declared symbol holds `Vector2` / `Expr`, never
       `Vector2.diagonal` or a per-case type" -- so it takes the type name's
       own span and no generic arguments, a call never carrying a `<>` list
       (generics.md §5.1).

       The value spans from the constructor name to the end of its arguments,
       which is the text that would have been written after the `=`. *)
    | C.Decl.VarShorthand { name = n; constructor; args; trailing = _ } ->
        let declared = constructor_name constructor in
        let type_name = declared.C.Constructor_name.type_ in
        let type_ =
          {
            S.Type_expr.span = type_name.C.Name_type.span;
            node = S.Type_expr.Path { name = type_name; generics = [] };
          }
        in
        let built =
          Span.join declared.C.Constructor_name.span
            args.C.Constructor_args.span
        in
        let value =
          call_expr built
            (S.Verb_call.Constructor
               {
                 name = declared;
                 args = constructor_args args;
                 abort_handle = None;
               })
        in
        S.Decl.Var { name = name n; type_; value }
    | C.Decl.Type { name = n; params; value } ->
        S.Decl.Type
          {
            name = name n;
            params = List.map generic_param params;
            value = type_or_moulded value;
          }
    | C.Decl.Alias { name = n; params; value } ->
        S.Decl.Alias
          {
            name = name n;
            params = List.map generic_param params;
            value = type_or_moulded value;
          }
    | C.Decl.EnumMap { enum; property; type_; entries } ->
        S.Decl.EnumMap
          {
            enum = type_expr enum;
            property = name property;
            type_ = type_expr type_;
            entries =
              List.map (fun (m, v) -> (name m, expression v)) entries;
          }
    | C.Decl.Verb v -> S.Decl.Verb (verb_decl v)
  in
  { S.Decl.node; span }

let package (x : C.Package.t) : S.Package.t =
  {
    S.Package.decls = List.map declaration x.C.Package.decls;
    span = x.C.Package.span;
  }
