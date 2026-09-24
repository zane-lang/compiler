(* The TST as a tree to print. Every expression shows its type, since that is
   what this stage adds; a leaf expression shows it on the same line, as
   `value : type`.

   [~bodies:false] prints declarations only -- what passes 1 to 4 settled,
   the `--decls` view -- and [~bodies:true] the whole tree with every body and
   every generic instance, the `--tst` view. *)

open Tree_graph
open Nodes
module S = Signature

let ty t = Leaf (Ty.to_string t)

let params (ps : Ty.param list) =
  String.concat ", "
    (List.map
       (fun (p : Ty.param) ->
         p.name ^ match p.kind with Ty.Type_kind -> " Type" | Ty.Number_kind -> " Number")
       ps)

let verb_ref (r : Verb_ref.t) =
  let owner =
    match r.owner with
    | S.Declared id -> Printf.sprintf "%s #%d" r.name id
    | S.Intrinsic spelling -> spelling
  in
  match r.instance with
  | [] -> owner
  | args ->
      owner ^ " with "
      ^ String.concat ", "
          (List.map (fun ((p : Ty.param), a) -> p.name ^ " = " ^ Ty.arg_to_string a) args)

let local (l : Local.t) = Printf.sprintf "%s #%d : %s" l.name l.id (Ty.to_string l.ty)

let name_ref = function
  | Name_ref.Local l -> Printf.sprintf "%s #%d" l.name l.id
  | Name_ref.Global { decl; name } -> Printf.sprintf "%s #%d" name decl
  | Name_ref.Number_param { name; value } -> name ^ " = " ^ Ty.number_to_string value
  | Name_ref.Intrinsic s -> s

let operator : Sst.Nodes.Operator.node -> string = Intrinsics.operator_token

let rec expr (e : Expr.t) : node =
  let leaf text = Leaf (text ^ " : " ^ Ty.to_string e.ty) in
  let node title children = group title (fields (("type", ty e.ty) :: children)) in
  match e.node with
  | Expr.Number_lit s -> leaf s
  | Expr.Text_lit s -> leaf (Printf.sprintf "%S" s)
  | Expr.Bool_lit b -> leaf (string_of_bool b)
  | Expr.Var r -> leaf (name_ref r)
  | Expr.Type_arg t -> leaf ("type " ^ Ty.to_string t)
  | Expr.Enum_member m -> leaf ("." ^ m)
  | Expr.Invalid -> leaf "<invalid>"
  | Expr.Array_lit items -> node "array" [ ("items", map_seq expr items) ]
  | Expr.Map_lit entries ->
      node "map"
        [ ("entries", map_seq (fun (k, v) -> fields [ ("key", expr k); ("value", expr v) ]) entries) ]
  | Expr.Case { case; payload } -> node "case" [ ("case", Leaf case); ("payload", expr payload) ]
  | Expr.Construct { ctor; args; handler = h } ->
      node "construct" ([ ("ctor", Leaf (verb_ref ctor)); ("args", map_seq arg args) ] @ handler h)
  | Expr.Construct_fields { ctor; fields = fs; handler = h } ->
      node "construct_fields"
        ([ ("ctor", Leaf (verb_ref ctor)); ("fields", map_seq field_value fs) ] @ handler h)
  | Expr.Field { target; field; slot } ->
      node "field" [ ("target", expr target); ("field", Leaf (Printf.sprintf "%s (slot %d)" field slot)) ]
  | Expr.Case_read { target; case; handler = h } ->
      node "case_read" ([ ("target", expr target); ("case", Leaf case) ] @ handler (Some h))
  | Expr.Map_read { target; map; property } ->
      node "map_read" [ ("target", expr target); ("map", Leaf (Printf.sprintf "%s #%d" property map)) ]
  | Expr.Subscript { target; impl; args } ->
      node "subscript" [ ("impl", Leaf (verb_ref impl)); ("target", expr target); ("args", map_seq expr args) ]
  | Expr.Ref inner -> node "guest" [ ("of", expr inner) ]
  | Expr.Init fs -> node "init" [ ("fields", map_seq field_value fs) ]
  | Expr.Spawn inner -> node "spawn" [ ("call", expr inner) ]
  | Expr.Match m ->
      node "match"
        ([
           ("scrutinees", map_seq expr m.scrutinees);
           ("arms", map_seq arm m.arms);
         ]
        @ handler m.handler)
  | Expr.Call { callee; args; handler = h } ->
      node "call" ([ ("callee", Leaf (verb_ref callee)); ("args", map_seq arg args) ] @ handler h)
  | Expr.Call_value { callee; args; handler = h } ->
      node "call_value" ([ ("callee", expr callee); ("args", map_seq arg args) ] @ handler h)
  | Expr.Op { op; impl; left; right; swapped; handler = h } ->
      node "op"
        ([
           ("op", Leaf (operator op ^ if swapped then " (swapped)" else ""));
           ("impl", Leaf (verb_ref impl));
           ("left", expr left);
           ("right", expr right);
         ]
        @ handler h)
  | Expr.Flip { impl; value; handler = h } ->
      node "flip" ([ ("impl", Leaf (verb_ref impl)); ("value", expr value) ] @ handler h)
  | Expr.Coerce { ctor; value } -> node "coerce" [ ("ctor", Leaf (verb_ref ctor)); ("value", expr value) ]
  | Expr.Lambda l ->
      node "lambda" [ ("params", map_seq (fun p -> Leaf (local p)) l.params); ("body", block l.body) ]

and arg = function Arg.Value e -> expr e | Arg.Block b -> group "block" (block b)

and field_value (f : Field_value.t) =
  group "field" (fields [ ("name", Leaf (Printf.sprintf "%s (slot %d)" f.name f.slot)); ("value", expr f.value) ])

and handler = function
  | None -> []
  | Some (h : Handler.t) ->
      [
        ( "handler",
          fields
            [
              ("binder", Leaf (match h.binder with Some l -> local l | None -> "none"));
              ("body", block h.body);
            ] );
      ]

and arm (a : Arm.t) =
  group "arm"
    (fields
       [
         ( "patterns",
           map_seq
             (fun (p : Pattern.t) ->
               Leaf (match p.binder with Some l -> local l ^ " <- " ^ p.case | None -> p.case))
             a.patterns );
         ("body", block a.body);
       ])

and block (b : Block.t) = map_seq stat b.stats

and stat (s : Stat.t) =
  match s.node with
  | Stat.Expr e -> group "do" (expr e)
  | Stat.Spawn e -> group "spawn" (expr e)
  | Stat.Let { local = l; value } -> group "let" (fields [ ("local", Leaf (local l)); ("value", expr value) ])
  | Stat.Assign { target; value } -> group "assign" (fields [ ("target", expr target); ("value", expr value) ])
  | Stat.Abort e -> group "abort" (expr e)
  | Stat.Return e -> group "return" (expr e)
  | Stat.Resolve e -> group "resolve" (expr e)

let definition = function
  | Decl.Struct fs -> ("struct", map_seq (fun (n, t) -> Leaf (n ^ " : " ^ Ty.to_string t)) fs)
  | Decl.Variant cs -> ("variant", map_seq (fun (n, t) -> Leaf (n ^ " : " ^ Ty.to_string t)) cs)
  | Decl.Enum ms -> ("enum", map_seq (fun m -> Leaf m) ms)
  | Decl.Distinct t -> ("distinct", ty t)

let decl ~bodies (d : Decl.t) =
  let with_body xs = if bodies then xs else [] in
  match d.node with
  | Decl.Type { name; params = ps; reference; definition = def } ->
      let kind, members = definition def in
      group "type"
        (fields
           ([ ("name", Leaf (Printf.sprintf "%s #%d" name d.id)) ]
           @ (if ps = [] then [] else [ ("params", Leaf (params ps)) ])
           @ [ ("kind", Leaf (if reference then "reference" else "value")); (kind, members) ]))
  | Decl.Alias { name; params = ps; target } ->
      group "alias"
        (fields
           ([ ("name", Leaf (Printf.sprintf "%s #%d" name d.id)) ]
           @ (if ps = [] then [] else [ ("params", Leaf (params ps)) ])
           @ [ ("target", ty target) ]))
  | Decl.Constant { name; ty = t; value } ->
      group "constant"
        (fields ([ ("name", Leaf (Printf.sprintf "%s #%d" name d.id)); ("type", ty t) ] @ with_body [ ("value", expr value) ]))
  | Decl.Enum_map { enum; property; ty = t; entries } ->
      group "enum_map"
        (fields
           ([ ("map", Leaf (Printf.sprintf "%s.%s #%d" (Ty.to_string enum) property d.id)); ("type", ty t) ]
           @ with_body [ ("entries", map_seq (fun (m, v) -> fields [ ("member", Leaf m); ("value", expr v) ]) entries) ]))
  | Decl.Verb { signature; body } ->
      group "verb"
        (fields
           ([ ("signature", Leaf (Printf.sprintf "%s #%d" (S.to_string signature) d.id)) ]
           @ with_body
               (match body with
               | Decl.Per_instance -> [ ("body", Leaf "checked per instance") ]
               | Decl.Checked { params = ps; body } ->
                   [ ("params", map_seq (fun p -> Leaf (local p)) ps); ("body", block body) ])))
  | Decl.Subscript { signature; params = ps; value } ->
      group "subscript"
        (fields
           ([ ("signature", Leaf (Printf.sprintf "%s #%d" (S.to_string signature) d.id)) ]
           @ with_body
               (match value with
               | None -> [ ("body", Leaf "checked per instance") ]
               | Some v -> [ ("params", map_seq (fun p -> Leaf (local p)) ps); ("value", expr v) ])))

let instance (i : Instance.t) =
  group "instance"
    (fields
       [
         ( "of",
           Leaf
             (Printf.sprintf "%s #%d with %s" i.signature.name i.decl
                (String.concat ", "
                   (List.map (fun ((p : Ty.param), a) -> p.name ^ " = " ^ Ty.arg_to_string a) i.args))) );
         ("params", map_seq (fun p -> Leaf (local p)) i.params);
         ("body", block i.body);
       ])

let to_node ~bodies (p : Program.t) =
  group "program"
    (fields
       ([
          ( "packages",
            map_seq
              (fun (pkg : Package.t) ->
                group "package" (fields [ ("name", Leaf pkg.name); ("decls", map_seq (decl ~bodies) pkg.decls) ]))
              p.packages );
        ]
       @ if bodies then [ ("instances", map_seq instance p.instances) ] else []))
