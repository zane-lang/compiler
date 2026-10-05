(* Expansions: an analysis over the finished TST (docs/design/semantics.md
   D1). A verb that takes a block or a literal -- any parameter of a concept
   type -- has no function of its own: each call to it is replaced by its
   body (docs/design/lowering.md L11). So such a verb cannot reach a call to
   itself through the bodies it is written out into, or writing it out would
   never end. A declared subscript's body is written out where it is used
   too, so a call reached through one counts as well. A call written in a
   lambda is not written out with the body around it: the lambda is a
   function of its own. *)

module T = Nodes
module S = Signature

let expands (s : S.t) =
  List.exists (fun (p : S.param) -> match p.S.ty with Ty.Concept _ -> true | _ -> false) s.S.params

(* Each call to a declared verb in a block, outside its lambdas, with the
   verb it names. *)
let rec calls (b : T.Block.t) =
  List.concat_map (fun s -> List.concat_map expr_calls (Exits.stat_exprs s)) b.T.Block.stats

and expr_calls (e : T.Expr.t) =
  (match Exits.callee e with Some (id, _) -> [ (id, e) ] | None -> [])
  @ List.concat_map
      (function
        | Exits.Same x -> expr_calls x
        | Exits.Arm b | Exits.Handler b | Exits.Block b -> calls b
        | Exits.Lambda _ -> [])
      (Exits.parts e)

let run (p : T.Program.t) =
  let names = Hashtbl.create 16 in
  List.iter
    (fun (pkg : T.Package.t) ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Verb { signature; _ } when expands signature ->
              Hashtbl.replace names d.T.Decl.id signature.S.name
          | _ -> ())
        pkg.T.Package.decls)
    p.T.Program.packages;
  (* The declared subscripts, which are written out where they are used and
     so pass a call on. *)
  let through = Hashtbl.create 16 in
  List.iter
    (fun (pkg : T.Package.t) ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Subscript _ -> Hashtbl.replace through d.T.Decl.id ()
          | _ -> ())
        pkg.T.Package.decls)
    p.T.Program.packages;
  let written_out id = Hashtbl.mem names id || Hashtbl.mem through id in
  (* What each expanding verb's and subscript's bodies call: its
     declaration's, or its instances' when it is generic. Only calls to those
     count. *)
  let edges = Hashtbl.create 16 in
  let add id body =
    if written_out id then
      List.iter
        (fun (callee, e) -> if written_out callee then Hashtbl.add edges id (callee, e))
        (calls body)
  in
  List.iter
    (fun (pkg : T.Package.t) ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Verb { body = T.Decl.Checked { body; _ }; _ } -> add d.T.Decl.id body
          | T.Decl.Subscript { value = Some v; _ } ->
              let stat = { T.Stat.node = T.Stat.Expr v; span = v.T.Expr.span } in
              add d.T.Decl.id { T.Block.stats = [ stat ]; span = v.T.Expr.span }
          | _ -> ())
        pkg.T.Package.decls)
    p.T.Program.packages;
  List.iter (fun (i : T.Instance.t) -> add i.T.Instance.decl i.T.Instance.body) p.T.Program.instances;
  (* Whether writing out [from] reaches a call to [target]. *)
  let reaches from target =
    let seen = Hashtbl.create 16 in
    let rec go id =
      id = target
      || (not (Hashtbl.mem seen id))
         && begin
              Hashtbl.replace seen id ();
              List.exists (fun (callee, _) -> go callee) (Hashtbl.find_all edges id)
            end
    in
    go from
  in
  let reported = Hashtbl.create 8 in
  Hashtbl.iter
    (fun id name ->
      List.iter
        (fun (callee, (e : T.Expr.t)) ->
          if reaches callee id && not (Hashtbl.mem reported e.T.Expr.span) then begin
            Hashtbl.replace reported e.T.Expr.span ();
            Env.error e.T.Expr.span
              (Printf.sprintf
                 "`%s` expands into itself: it takes a block or a literal, so each call to it is \
                  written out in place of the call, and this call is reached again"
                 name)
          end)
        (Hashtbl.find_all edges id))
    names
