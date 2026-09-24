(* Semantic actions that build or rewrite a larger node than their production
   reduced.

   These are the grammar's actions in every sense except where they are
   written: each is called from a production, and each may reject the input it
   was handed. They are out of [parser.mly] because they are several lines of
   tree surgery apiece, and the productions read better without them in
   between.

   Raising is safe in exactly these two places. An action runs on every branch
   the GLR parser has live, not only the accepted one, so a raise ends the
   parse rather than the branch -- and no valid program reaches either of
   these. A check a valid program can reach belongs in [Statement_check],
   over the tree that survived. *)

open Parser_nodes

let attach_abort_handle abort_handle span value =
  let attach (call : Nodes.Verb_call.t) =
    match call.Nodes.Verb_call.node with
    (* A trailing argument ends its statement, so nothing may continue the call
       past that `}` -- a handler included. The same call written with the
       argument inside the parentheses takes one. *)
    | Nodes.Verb_call.Func { trailing = true; _ }
    | Nodes.Verb_call.Meth { trailing = true; _ }
    | Nodes.Verb_call.Constructor { trailing = true; _ } ->
        raise
          (Parse_error.Rejected
             "a trailing argument ends the statement, so an abort handler \
              cannot follow it; write the argument inside the argument list")
    | Nodes.Verb_call.Func { callee; args; abort_handle = None; trailing } ->
        { call with
          Nodes.Verb_call.node =
            Nodes.Verb_call.Func {
              callee;
              args;
              abort_handle = Some abort_handle;
              trailing;
            } }
    | Nodes.Verb_call.Meth { callee; this; args; abort_handle = None; is_mut; trailing } ->
        { call with
          Nodes.Verb_call.node =
            Nodes.Verb_call.Meth {
              callee;
              this;
              args;
              abort_handle = Some abort_handle;
              is_mut;
              trailing;
            } }
    | Nodes.Verb_call.Constructor { name; args; abort_handle = None; trailing } ->
        { call with
          Nodes.Verb_call.node =
            Nodes.Verb_call.Constructor {
              name;
              args;
              abort_handle = Some abort_handle;
              trailing;
            } }
    | Nodes.Verb_call.Op { op; left; right; abort_handle = None } ->
        { call with
          Nodes.Verb_call.node =
            Nodes.Verb_call.Op {
              op;
              left;
              right;
              abort_handle = Some abort_handle;
            } }
    | Nodes.Verb_call.Flip { value; abort_handle = None } ->
        { call with
          Nodes.Verb_call.node =
            Nodes.Verb_call.Flip { value; abort_handle = Some abort_handle } }
    | _ ->
        raise
          (Parse_error.Rejected "an operation can only have one abort handler")
  in
  (* The handler is written to the right of the operation it handles, so the
     node it attaches to now ends later than it did when it was built. Each
     rebuilt node therefore takes the span the caller passes, which is the
     `expr abort_handle` production's own -- the operation through the handler.
     What is not rebuilt keeps the span it had. *)
  let rec loop span (value : Nodes.Expr.t) =
    match value.Nodes.Expr.node with
    | Nodes.Expr.VerbCall call ->
        { Nodes.Expr.node = Nodes.Expr.VerbCall (attach call); span }
    | Nodes.Expr.Spawn call ->
        { Nodes.Expr.node = Nodes.Expr.Spawn (attach call); span }
    | Nodes.Expr.Match ({ abort_handle = None; _ } as match_) ->
        {
          Nodes.Expr.node =
            Nodes.Expr.Match
              { match_ with Nodes.Match_expr.abort_handle = Some abort_handle; span };
          span;
        }
    | Nodes.Expr.Parenthized inner ->
        { Nodes.Expr.node = Nodes.Expr.Parenthized (loop span inner); span }
    | _ ->
        raise
          (Parse_error.Rejected
             "an abort handler must follow an abortable operation")
  in
  loop span value

let constructor_expr loc name args =
  expr loc
    (Nodes.Expr.VerbCall
       (verb_call loc
          (Nodes.Verb_call.Constructor
             { name; args; abort_handle = None; trailing = false })))

(* An `as` alias renames one member, and casing is what says whether a name is
   a type or a value, so a rename across the two classes would change what the
   name means rather than what it is spelled. The grammar admits either
   spelling on each side because both are ordinary names; only the pair is
   wrong. *)
let import_alias (member : Nodes.Import_member.t)
    (alias : Nodes.Import_member.t) =
  if member.Nodes.Import_member.is_type <> alias.Nodes.Import_member.is_type
  then
    raise
      (Parse_error.Rejected
         "an `as` alias has to keep the casing of the name it renames, since \
          an uppercase-initial name is a type and a lowercase one a value");
  alias
