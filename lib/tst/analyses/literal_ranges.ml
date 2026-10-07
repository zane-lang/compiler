(* Literal ranges: an analysis over the finished TST (docs/design/semantics.md
   D1). A storage primitive's constructor embeds its literal (types.md §2.7),
   so the literal must fit the primitive: `@primitives$I64` holds a 64-bit
   integer, `I32` a 32-bit one, `F64` a finite double and `F32` a finite
   single. A literal
   that reaches a constructor through a verb's literal parameter is known only
   where the verb is written out, and lowering checks it there. *)

module T = Nodes
module S = Signature

(* A numeric literal's digits, without the `'` that only separates groups of
   them (docs/spec-divergences.md §8). *)
let digits s = String.concat "" (String.split_on_char '\'' s)

(* Whether [text], written for the primitive [name], fits it. *)
let fits name (literal : T.Expr.node) =
  match (name, literal) with
  | "I64", T.Expr.Integer_lit s -> Option.is_some (Int64.of_string_opt (digits s))
  | "I32", T.Expr.Integer_lit s -> Option.is_some (Int32.of_string_opt (digits s))
  | "I32", T.Expr.Var (T.Name_ref.Number_param { value = Ty.Known n; _ }) ->
      Int64.of_int n >= Int64.of_int32 Int32.min_int && Int64.of_int n <= Int64.of_int32 Int32.max_int
  | "F64", T.Expr.Decimal_lit s -> Float.is_finite (float_of_string (digits s))
  | "F32", T.Expr.Decimal_lit s -> Float.is_finite (Decimal.to_single (digits s))
  | _ -> true

let text = function
  | T.Expr.Integer_lit s | T.Expr.Decimal_lit s -> s
  | T.Expr.Var (T.Name_ref.Number_param { value = Ty.Known n; _ }) -> string_of_int n
  | _ -> ""

let prefix = "@primitives$"

let rec block env (b : T.Block.t) =
  List.iter (fun s -> List.iter (expr env) (Exits.stat_exprs s)) b.T.Block.stats

and expr env (e : T.Expr.t) =
  let check spelling (v : T.Expr.t) =
    if String.starts_with ~prefix spelling then
      let name =
        String.sub spelling (String.length prefix) (String.length spelling - String.length prefix)
      in
      if not (fits name v.T.Expr.node) then
        Env.error env v.T.Expr.span
          (Printf.sprintf "`%s` is out of range for `%s`" (text v.T.Expr.node) spelling)
  in
  (match e.T.Expr.node with
  | T.Expr.Construct { ctor = { T.Verb_ref.owner = S.Intrinsic spelling; _ }; args = [ T.Arg.Value v ]; _ }
  | T.Expr.Coerce { ctor = { T.Verb_ref.owner = S.Intrinsic spelling; _ }; value = v } ->
      check spelling v
  | _ -> ());
  List.iter
    (function
      | Exits.Same x -> expr env x
      | Exits.Arm b | Exits.Handler b | Exits.Block b | Exits.Lambda b -> block env b)
    (Exits.parts e)

let run env (p : T.Program.t) =
  List.iter
    (fun (pkg : T.Package.t) ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Verb { body = T.Decl.Checked { body; _ }; _ } -> block env body
          | T.Decl.Constant { value; _ } -> expr env value
          | T.Decl.Subscript { value = Some v; _ } -> expr env v
          | T.Decl.Enum_map { entries; _ } -> List.iter (fun (_, e) -> expr env e) entries
          | _ -> ())
        pkg.T.Package.decls)
    p.T.Program.packages;
  List.iter
    (fun (i : T.Instance.t) -> Env.in_instance env i (fun () -> block env i.T.Instance.body))
    p.T.Program.instances;
  (* A field constructor's defaults, which a call that leaves an entry out
     builds from. *)
  List.iter
    (fun (d : T.Defaults.t) -> List.iter (fun (_, e) -> expr env e) d.T.Defaults.values)
    p.T.Program.defaults
