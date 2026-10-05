(* Overload resolution (functions.md §5): an argument as the call site wrote
   it, the candidates it may reach through implicit constructors, and the
   three phases that pick one. *)

open Env
module T = Nodes
module S = Signature

open Context
open Instances

(* An argument as the call site wrote it, already typed. *)
type actual = {
  arg : T.Arg.t;
  aty : Ty.t;
  aspan : Span.t;
  (* A method's subject is never converted (types.md §4.6). *)
  subject : bool;
}

type phase = Direct | Generic | Implicit

type outcome = {
  sig_ : S.t;
  subst : Ty.subst;
  (* Aligned with the signature's parameters; [None] where a field
     constructor's entry was omitted and its default applies. *)
  converted : T.Arg.t option list;
  (* Problems at one argument of a candidate that is otherwise the one: an
     ambiguous implicit constructor (types.md §4.2, step 4). *)
  site_errors : (Span.t * string) list;
}

let arg_expr = function T.Arg.Value e -> Some e | T.Arg.Block _ -> None

(* The implicit constructors that take a [src] to a [dst]: declared in the
   home package of either, which is the only place one may be (types.md
   §4.5), so no import is involved. *)
let implicit_constructors ~src ~dst =
  let dst = Ty.strip_guest dst in
  match Verb_signatures.type_key dst with
  | None -> []
  | Some key ->
      let homes = List.filter_map Verb_signatures.home [ src; dst ] in
      Hashtbl.find_all constructors key
      |> List.filter (fun (s : S.t) -> S.is_implicit s && List.mem s.home homes)
      |> List.filter_map (fun (s : S.t) ->
             match s.params with
             | [ p ] -> (
                 let open_ = s.generics in
                 match Ty.unify ~open_ [] p.ty (Ty.strip_guest src) with
                 | None -> None
                 | Some subst -> (
                     match Ty.unify ~open_ subst s.ret dst with
                     | None -> None
                     | Some subst ->
                         if List.for_all (fun (q : Ty.param) -> List.mem_assoc q.id subst) open_
                         then Some (s, subst)
                         else None))
             | _ -> None)

(* Building the node requests nothing: a candidate being tried may still be
   dropped, and only the one resolution picks asks for instances
   ([request_coercions]). *)
let coerce_value (e : T.Expr.t) (s, subst) =
  mk (T.Expr.Coerce { ctor = verb_ref s subst; value = e }) (Ty.subst subst s.S.ret) e.T.Expr.span

(* Bind an explicit `T Type` or `n @concepts$Int` parameter from its
   argument. Another argument may already have fixed it -- `n` in
   `measured(values Array<Int, n>, n @concepts$Int)` -- and then the two
   must agree. *)
let bind_explicit (p : Ty.param) (a : actual) subst =
  let bind arg =
    match List.assoc_opt p.id subst with
    | None -> Some ((p.id, arg) :: subst)
    | Some bound -> if Ty.arg_equal bound arg then Some subst else None
  in
  match (p.kind, a.arg) with
  | Ty.Type_kind, T.Arg.Value { T.Expr.node = T.Expr.Type_arg t; _ } -> bind (Ty.Type t)
  | Ty.Number_kind, T.Arg.Value { T.Expr.node = T.Expr.Integer_lit text; _ } -> (
      match Type_decls.integer_value text with
      | Some n -> bind (Ty.Number (Ty.Known n))
      | None -> None)
  | Ty.Number_kind, T.Arg.Value { T.Expr.node = T.Expr.Var (T.Name_ref.Number_param { value; _ }); _ } ->
      bind (Ty.Number value)
  | _, T.Arg.Value { T.Expr.ty = Ty.Error; _ } -> Some subst
  | _ -> None

(* Every element, when none is missing. *)
let all_some xs =
  List.fold_right
    (fun x acc -> match (x, acc) with Some x, Some acc -> Some (x :: acc) | _ -> None)
    xs (Some [])

let try_candidate ~phase (s : S.t) (slots : actual option list) : outcome option =
  if List.length slots <> List.length s.params then None
  else if phase = Direct && s.generics <> [] then None
  else if phase = Generic && s.generics = [] then None
  else
    let open_ = s.generics in
    let pairs = List.combine s.params slots in
    (* First every argument that matches without conversion, binding the
       parameters it fixes; then, in the implicit phase only, the rest, each
       against its parameter with every binding applied. An implicit
       constructor never discovers a destination (functions.md §5). *)
    let exact subst ((p : S.param), slot) =
      match (slot, subst) with
      | _, None -> (None, None)
      | None, Some subst -> if p.has_default then (Some subst, Some `Default) else (None, None)
      | Some a, Some subst -> (
          match p.binds with
          | Some q -> (
              match bind_explicit q a subst with
              | Some subst -> (Some subst, Some `Exact)
              | None -> (None, None))
          | None -> (
              match
                Ty.unify ~open_ subst (Ty.strip_guest p.ty) (Ty.held_as ~dst:p.ty ~src:a.aty)
              with
              | Some subst -> (Some subst, Some `Exact)
              | None -> (Some subst, Some `Convert)))
    in
    let subst, marks =
      List.fold_left
        (fun (subst, marks) pair ->
          match subst with
          | None -> (None, marks)
          | Some _ ->
              let subst', mark = exact subst pair in
              (subst', marks @ [ mark ]))
        (Some [], []) pairs
    in
    match subst with
    | None -> None
    | Some subst ->
        if List.exists (fun m -> m = None) marks then None
        else if phase <> Implicit && List.exists (fun m -> m = Some `Convert) marks then None
        else if not (List.for_all (fun (q : Ty.param) -> List.mem_assoc q.id subst) open_) then None
        else begin
          let site_errors = ref [] in
          let converted =
            List.map2
              (fun ((p : S.param), slot) mark ->
                match (slot, mark) with
                | None, _ -> Some None
                | Some a, Some `Exact -> Some (Some a.arg)
                | Some a, Some `Convert -> (
                    if a.subject then None
                    else
                      match arg_expr a.arg with
                      | None -> None
                      | Some e -> (
                          let dst = Ty.subst subst p.ty in
                          if Ty.free_params dst <> [] then None
                          else
                            match implicit_constructors ~src:a.aty ~dst with
                            | [ found ] -> Some (Some (T.Arg.Value (coerce_value e found)))
                            | [] -> None
                            | several ->
                                site_errors :=
                                  ( a.aspan,
                                    Printf.sprintf
                                      "more than one implicit constructor converts %s to %s: %s"
                                      (quote (Ty.to_string a.aty))
                                      (quote (Ty.to_string dst))
                                      (String.concat ", "
                                         (List.map (fun ((s : S.t), _) -> quote (S.to_string s)) several)) )
                                  :: !site_errors;
                                Some (Some a.arg)))
                | _ -> None)
              pairs marks
          in
          match all_some converted with
          | None -> None
          | Some converted ->
              Some { sig_ = s; subst; converted; site_errors = List.rev !site_errors }
        end

type resolution = Resolved of outcome | No_match | Ambiguous of S.t list

let resolve candidates (slots_for : S.t -> actual option list option) =
  let attempt phase =
    List.filter_map
      (fun s -> Option.bind (slots_for s) (fun slots -> try_candidate ~phase s slots))
      candidates
  in
  let rec phases = function
    | [] -> No_match
    | phase :: rest -> (
        match attempt phase with
        | [] -> phases rest
        | [ one ] -> Resolved one
        | several -> Ambiguous (List.map (fun o -> o.sig_) several))
  in
  phases [ Direct; Generic; Implicit ]

let positional actuals (s : S.t) =
  match s.kind with
  | S.Constructor { fields = true; _ } -> None
  | _ -> Some (List.map Option.some actuals)

let has_literal actuals =
  List.exists
    (fun a ->
      Ty.is_bare_literal a.aty
      || match a.aty with Ty.Concept (Ty.Array_lit (t, _)) -> Ty.is_bare_literal t | _ -> false)
    actuals

(* Whether a bare literal sits where some generic candidate would have to
   infer a parameter from it -- the one mistake generics.md §5.4's hint is
   for. A literal that fills an explicit `n @concepts$Int` is not one, and
   a call with the wrong number of arguments has a nearer problem to name. *)
let literal_drives_inference (cands : S.t list) actuals =
  List.exists
    (fun (s : S.t) ->
      s.generics <> []
      &&
      if List.length s.params = List.length actuals then
        List.exists2
          (fun (p : S.param) a -> p.binds = None && Ty.free_params p.ty <> [] && has_literal [ a ])
          s.params actuals
      else false)
    cands

let describe_args actuals =
  "(" ^ String.concat ", " (List.map (fun a -> Ty.to_string a.aty) actuals) ^ ")"

let list_candidates cands =
  let shown = List.filteri (fun i _ -> i < 4) cands in
  String.concat "; " (List.map (fun s -> quote (S.to_string s)) shown)
  ^ if List.length cands > 4 then "; ..." else ""

(* The implicit constructors the chosen candidate inserted, instantiated
   now that it is chosen. *)
let request_coercions (o : outcome) =
  List.iter
    (function
      | Some
          (T.Arg.Value
             { T.Expr.node = T.Expr.Coerce { ctor = { T.Verb_ref.owner = S.Declared id; instance; _ }; _ }; span; _ })
        when instance <> [] -> (
          match Hashtbl.find_opt signatures id with
          | Some s -> request s (List.map (fun ((p : Ty.param), a) -> (p.id, a)) instance) span
          | None -> ())
      | _ -> ())
    o.converted

let report_resolution ?(literal = false) ~span ~what ~args result cands =
  match result with
  | Resolved o ->
      List.iter (fun (at, message) -> error at message) o.site_errors;
      request_coercions o;
      Some o
  | Ambiguous several ->
      error span
        (Printf.sprintf "the call to %s is ambiguous: %s %s accept %s" what
           (list_candidates several)
           (if List.length several = 2 then "both" else "all")
           args);
      None
  | No_match ->
      (* The one no-match with a fix worth naming: a literal offered where
         only inference could have placed it (generics.md §5.4). *)
      let hint =
        if literal then
          "; a bare literal fixes no type, so it cannot drive inference: wrap it in \
           the type it is meant to be, as `Int(4)`"
        else ""
      in
      error span
        (Printf.sprintf "no %s accepts %s; the %s %s%s" what args
           (if List.length cands = 1 then "candidate is" else "candidates are")
           (list_candidates cands) hint);
      None
