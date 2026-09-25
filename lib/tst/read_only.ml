(* Read-only guests (effects.md §4.4): the first analysis over the finished
   TST (docs/semantics.md D1).

   A guest derived from a read-only binding is read-only wherever it goes:
   bound to a local, stored in a field, passed as an argument, or returned.
   §4.1 is checked while the tree is built, because it needs nothing but the
   place a write names: a parameter, or something reached through one. This
   rule needs to know where a guest went, which the tree only shows once every
   call in it has a callee. So it runs after, over the whole program.

   What it tracks is a [taint]: for a value, the places in it that hold a guest
   taken from a parameter. Each [elem] says that at [at] inside the value sits
   something reached from parameter [origin] at [src]. A value type carries
   nothing, because a value is copied deep and holds no guest (memory.md
   §2.10), so storing one drops its taint.

   A verb's [summary] is what a call needs without the body: which parameters
   reach its result, and which come to rest in its `this`. The same record as
   lifetimes.md §1.11's resting places, without the owners, and like them
   transitive: a call substitutes its arguments' taints for the parameters.
   Summaries are computed to a fixed point, since verbs may call each other in
   a cycle; only then is each body walked once more to report. *)

module T = Nodes
module S = Signature

type step = Field of string | Elem | Case of string
type path = step list

(* In a body, [origin] is a local's id; in a summary, a parameter's index. *)
type elem = { origin : int; src : path; at : path }

module Taint = Set.Make (struct
  type t = elem

  let compare = compare
end)

(* Recursive types would let a path grow without end, so it is cut. A cut
   path names a bigger place than the real one, which can only make the
   analysis stricter, never let a write through. *)
let depth = 4

let rec cut n = function [] -> [] | _ when n = 0 -> [] | x :: r -> x :: cut (n - 1) r
let elem origin src at = { origin; src = cut depth src; at = cut depth at }

let rec is_prefix p q =
  match (p, q) with
  | [], _ -> true
  | x :: p, y :: q -> x = y && is_prefix p q
  | _ -> false

let rec drop p q = match (p, q) with _ :: p, _ :: q -> drop p q | _, q -> q

(* The taint of the part of a value at [p]. A guest at [p] or below stays,
   re-rooted; a guest above [p] covers it, since [p] is then reached through
   that guest. *)
let navigate s p =
  Taint.fold
    (fun e acc ->
      if is_prefix p e.at then Taint.add (elem e.origin e.src (drop p e.at)) acc
      else if is_prefix e.at p then Taint.add (elem e.origin (e.src @ drop e.at p) []) acc
      else acc)
    s Taint.empty

let under p s = Taint.map (fun e -> elem e.origin e.src (p @ e.at)) s

(* Where a value's parts cannot be told apart: all of it. *)
let whole s = Taint.map (fun e -> elem e.origin e.src []) s

(* ---------------------------------------------------------------------- *)
(* Types                                                                  *)
(* ---------------------------------------------------------------------- *)

(* Whether storage of type [t] can hold a guest. *)
let rec carries ?(seen = []) (t : Ty.t) =
  match t with
  | Ty.Guest _ | Ty.Param _ -> true
  | Ty.Error | Ty.Verb _ | Ty.Concept _ -> false
  | Ty.Intrinsic { args; _ } -> List.exists (carries_arg ~seen) args
  | Ty.Named (tid, args) -> (
      List.exists (carries_arg ~seen) args
      || (not (List.mem tid seen))
         &&
         match Hashtbl.find_opt Env.type_infos_by_id tid with
         | None -> false
         | Some info -> (
             let s =
               try List.combine (List.map (fun (p : Ty.param) -> p.Ty.id) info.Env.params) args
               with Invalid_argument _ -> []
             in
             let seen = tid :: seen in
             match info.Env.definition with
             | Some (Env.Struct fs) | Some (Env.Variant fs) ->
                 List.exists (fun (_, t) -> carries ~seen (Ty.subst s t)) fs
             | Some (Env.Distinct t) -> carries ~seen (Ty.subst s t)
             | _ -> false))

and carries_arg ~seen = function Ty.Type t -> carries ~seen t | Ty.Number _ -> false

(* What storing a value of type [t] keeps of its taint. *)
let store t s = if carries t then s else Taint.empty

(* The declared type of a struct's field, which is what decides whether the
   field can hold a guest: the value written into it may be a place a guest
   is minted from, whose own type says nothing about that. *)
let field_type (t : Ty.t) name =
  match t with
  | Ty.Named (tid, args) -> (
      match Hashtbl.find_opt Env.type_infos_by_id tid with
      | Some { Env.definition = Some (Env.Struct fs); params; _ } -> (
          match List.assoc_opt name fs with
          | Some ft -> (
              let ids = List.map (fun (p : Ty.param) -> p.Ty.id) params in
              try Some (Ty.subst (List.combine ids args) ft) with Invalid_argument _ -> Some ft)
          | None -> None)
      | _ -> None)
  | _ -> None

let store_field t name s = match field_type t name with Some ft -> store ft s | None -> s

(* ---------------------------------------------------------------------- *)
(* Summaries                                                              *)
(* ---------------------------------------------------------------------- *)

type summary = {
  (* Origins are parameter indices, the subject first. *)
  result : Taint.t;
  (* What comes to rest in `this`, for a `mut` method. *)
  into_this : Taint.t;
}

let empty = { result = Taint.empty; into_this = Taint.empty }
let summaries : (int, summary) Hashtbl.t = Hashtbl.create 64
let changed = ref false

let merge id s =
  let old = Option.value ~default:empty (Hashtbl.find_opt summaries id) in
  let s =
    { result = Taint.union old.result s.result; into_this = Taint.union old.into_this s.into_this }
  in
  if not (Taint.equal s.result old.result && Taint.equal s.into_this old.into_this) then begin
    Hashtbl.replace summaries id s;
    changed := true
  end

(* A summary's taint with each parameter replaced by its argument's. *)
let substitute (args : Taint.t array) s =
  Taint.fold
    (fun e acc ->
      if e.origin < 0 || e.origin >= Array.length args then acc
      else
        Taint.fold
          (fun a acc -> Taint.add (elem a.origin a.src (e.at @ a.at)) acc)
          (navigate args.(e.origin) e.src)
          acc)
    s Taint.empty

(* ---------------------------------------------------------------------- *)
(* Walking a body                                                         *)
(* ---------------------------------------------------------------------- *)

type binding = { name : string; read_only : bool }

type walk = {
  (* Report, or only gather summaries. *)
  report : bool;
  taints : (int, Taint.t) Hashtbl.t;
  (* Every parameter an origin can name, in this body and its lambdas. *)
  origins : (int, binding) Hashtbl.t;
  (* Where a `return` and a `resolve` send their value. *)
  mutable returned : Taint.t;
  mutable resolved : Taint.t list;
}

let quote s = "`" ^ s ^ "`"

let read_only w s =
  Taint.exists
    (fun e -> match Hashtbl.find_opt w.origins e.origin with Some b -> b.read_only | None -> false)
    s

let blame w s =
  let names =
    Taint.fold
      (fun e acc ->
        match Hashtbl.find_opt w.origins e.origin with
        | Some b when b.read_only && not (List.mem b.name acc) -> b.name :: acc
        | _ -> acc)
      s []
  in
  match List.sort compare names with
  | [ "this" ] -> "`this`, which is read-only in a method that is not `mut`"
  | [ n ] -> quote n ^ ", a read-only parameter"
  | ns -> String.concat " and " (List.map quote ns) ^ ", read-only parameters"

let error w span message = if w.report then Env.error span message

(* A place: the local it is reached through, and the path from there. *)
let rec place (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> Some (l, [])
  | T.Expr.Field { target; field; _ } -> step target (Field field)
  | T.Expr.Case_read { target; case; _ } -> step target (Case case)
  | T.Expr.Subscript { target; _ } -> step target Elem
  | _ -> None

and step target s = Option.map (fun (l, p) -> (l, p @ [ s ])) (place target)

let taint_by_id w id = Option.value ~default:Taint.empty (Hashtbl.find_opt w.taints id)
let taint_of w (l : T.Local.t) = taint_by_id w l.T.Local.id

(* §4.1 already reported a write whose place is reached straight from a
   read-only parameter; this rule adds the guests derived from one. *)
let direct w (l : T.Local.t) =
  match Hashtbl.find_opt w.origins l.T.Local.id with Some b -> b.read_only | None -> false

let add w (l : T.Local.t) p s =
  if not (Taint.is_empty s) then begin
    let old = taint_of w l in
    Hashtbl.replace w.taints l.T.Local.id (Taint.union old (under p s))
  end

let signature_of (r : T.Verb_ref.t) =
  match r.T.Verb_ref.owner with
  | S.Declared id -> Hashtbl.find_opt Env.signatures id
  | S.Intrinsic spelling ->
      List.find_map
        (fun (_, (sg : S.t)) -> if sg.S.owner = S.Intrinsic spelling then Some sg else None)
        Intrinsics.methods

let summary_of (r : T.Verb_ref.t) =
  match r.T.Verb_ref.owner with
  | S.Declared id -> Hashtbl.find_opt summaries id
  | S.Intrinsic _ -> None

let rec expr w (e : T.Expr.t) : Taint.t =
  match e.T.Expr.node with
  | T.Expr.Integer_lit _ | T.Expr.Decimal_lit _ | T.Expr.Text_lit _ | T.Expr.Bool_lit _
  | T.Expr.Type_arg _ | T.Expr.Enum_member _ | T.Expr.Invalid ->
      Taint.empty
  | T.Expr.Var (T.Name_ref.Local l) -> taint_of w l
  | T.Expr.Var _ -> Taint.empty
  | T.Expr.Map_read { target; _ } ->
      ignore (expr w target);
      Taint.empty
  | T.Expr.Array_lit items ->
      List.fold_left (fun acc i -> Taint.union acc (under [ Elem ] (expr w i))) Taint.empty items
  | T.Expr.Map_lit entries ->
      List.fold_left
        (fun acc (k, v) -> Taint.union acc (under [ Elem ] (Taint.union (expr w k) (expr w v))))
        Taint.empty entries
  | T.Expr.Case { case; payload } -> under [ Case case ] (expr w payload)
  | T.Expr.Field { target; field; _ } -> navigate (expr w target) [ Field field ]
  | T.Expr.Case_read { target; case; handler } ->
      let t = navigate (expr w target) [ Case case ] in
      Taint.union t (handler_value w handler)
  | T.Expr.Ref inner | T.Expr.Spawn inner -> expr w inner
  | T.Expr.Init fields ->
      List.fold_left
        (fun acc (f : T.Field_value.t) ->
          let name = f.T.Field_value.name in
          let v = store_field e.T.Expr.ty name (expr w f.T.Field_value.value) in
          Taint.union acc (under [ Field name ] v))
        Taint.empty fields
  | T.Expr.Match m ->
      let scrutinee =
        List.fold_left (fun acc s -> Taint.union acc (expr w s)) Taint.empty m.T.Match.scrutinees
      in
      let arms =
        List.fold_left
          (fun acc (a : T.Arm.t) ->
            List.iter
              (fun (p : T.Pattern.t) ->
                Option.iter
                  (fun (b : T.Local.t) ->
                    Hashtbl.replace w.taints b.T.Local.id
                      (store b.T.Local.ty (navigate scrutinee [ Case p.T.Pattern.case ])))
                  p.T.Pattern.binder)
              a.T.Arm.patterns;
            Taint.union acc (arm_value w a.T.Arm.body))
          Taint.empty m.T.Match.arms
      in
      Taint.union arms (opt_handler w m.T.Match.handler)
  | T.Expr.Call { callee; args; handler } ->
      let r = call w e callee (List.map (arg w) args) args in
      Taint.union r (opt_handler w handler)
  | T.Expr.Construct { ctor; args; handler } ->
      let r = call w e ctor (List.map (arg w) args) args in
      Taint.union r (opt_handler w handler)
  | T.Expr.Construct_fields { ctor; fields; handler } ->
      let taints =
        List.map
          (fun (f : T.Field_value.t) -> (f.T.Field_value.name, expr w f.T.Field_value.value))
          fields
      in
      (* A field constructor's parameters are its fields, by name. *)
      let params = match signature_of ctor with Some sg -> sg.S.params | None -> [] in
      let taint_of_param (p : S.param) =
        Option.value ~default:Taint.empty (List.assoc_opt p.S.name taints)
      in
      let r =
        match summary_of ctor with
        | Some s -> substitute (Array.of_list (List.map taint_of_param params)) s.result
        | None when params = [] ->
            whole (List.fold_left (fun acc (_, t) -> Taint.union acc t) Taint.empty taints)
        | None ->
            List.fold_left
              (fun acc (p : S.param) ->
                Taint.union acc (under [ Field p.S.name ] (store p.S.ty (taint_of_param p))))
              Taint.empty params
      in
      Taint.union (store e.T.Expr.ty r) (opt_handler w handler)
  | T.Expr.Subscript { target; impl; args } ->
      let t = expr w target in
      let rest = List.map (expr w) args in
      let r =
        match summary_of impl with
        | Some s -> substitute (Array.of_list (t :: rest)) s.result
        | None -> navigate t [ Elem ]
      in
      store_or_place e r
  | T.Expr.Call_value { callee; args; handler } ->
      let fn = expr w callee in
      let taints = List.map (arg w) args in
      let tys =
        match callee.T.Expr.ty with
        | Ty.Verb v -> Option.to_list v.Ty.this_ @ v.Ty.params
        | _ -> []
      in
      (match callee.T.Expr.ty with
      | Ty.Verb { Ty.this_ = Some _; is_mut = true; _ } ->
          write_subject w args taints (whole (passed (List.tl tys) (List.tl taints)))
      | _ -> ());
      let r = whole (Taint.union fn (passed tys taints)) in
      Taint.union (store e.T.Expr.ty r) (opt_handler w handler)
  | T.Expr.Op { left; right; handler; impl; swapped; _ } ->
      let l = expr w left and r = expr w right in
      let args = if swapped then [ r; l ] else [ l; r ] in
      let res =
        match summary_of impl with
        | Some s -> substitute (Array.of_list args) s.result
        | None -> whole (Taint.union l r)
      in
      Taint.union (store e.T.Expr.ty res) (opt_handler w handler)
  | T.Expr.Flip { value; impl; handler } ->
      let v = expr w value in
      let res = one impl v in
      Taint.union (store e.T.Expr.ty res) (opt_handler w handler)
  | T.Expr.Coerce { ctor; value } ->
      let v = expr w value in
      let res = one ctor v in
      store e.T.Expr.ty res
  | T.Expr.Lambda l -> lambda w e l

(* A call with one argument. *)
and one callee v =
  match summary_of callee with Some s -> substitute [| v |] s.result | None -> whole v

(* A subscript names a place, so what it yields is read where it is, not
   stored: its taint stays whole unless the value is a copy. *)
and store_or_place (e : T.Expr.t) r = if carries e.T.Expr.ty then r else Taint.empty

and arg w = function
  | T.Arg.Value e -> expr w e
  | T.Arg.Block b ->
      (* A block argument may run any number of times, each run seeing what
         the last one stored, so it is walked until that stops growing. *)
      (* After the block a local holds what any run stored, so each run is
         joined into the one before, and the walk stops once a run adds
         nothing. A `let` or an assignment replaces what a run sees, which is
         why the join, and not the size of the table, decides. *)
      let rec settle () =
        let before = Hashtbl.copy w.taints in
        block w b;
        Hashtbl.iter
          (fun id old -> Hashtbl.replace w.taints id (Taint.union old (taint_by_id w id)))
          before;
        let grew =
          Hashtbl.fold
            (fun id now grew ->
              grew
              || not (Taint.subset now (Option.value ~default:Taint.empty (Hashtbl.find_opt before id))))
            w.taints false
        in
        if grew then settle ()
      in
      settle ();
      Taint.empty

and call w (e : T.Expr.t) (callee : T.Verb_ref.t) taints args =
  let s = summary_of callee in
  let sg = signature_of callee in
  let tys =
    match sg with Some sg -> List.map (fun (p : S.param) -> p.S.ty) sg.S.params | None -> []
  in
  let res =
    match s with
    | Some s -> substitute (Array.of_list taints) s.result
    | None -> whole (passed tys taints)
  in
  (match sg with
  | Some sg when sg.S.is_mut && S.is_method sg ->
      let into =
        match s with
        | Some s -> substitute (Array.of_list taints) s.into_this
        | None -> whole (passed (List.tl tys) (List.tl taints))
      in
      write_subject w args taints into
  | _ -> ());
  store e.T.Expr.ty res

(* What a verb with no body to summarise -- an intrinsic, a function value --
   may have kept of its arguments: anything a parameter's type can hold a
   guest in. A parameter whose type cannot hold one keeps nothing. *)
and passed tys taints =
  let rec go tys taints =
    match (tys, taints) with
    | ty :: tys, t :: taints -> Taint.union (store ty t) (go tys taints)
    | [], t :: taints -> Taint.union t (go [] taints)
    | _, [] -> Taint.empty
  in
  go tys taints

(* A `!` call writes its subject: it may not reach a read-only guest, and what
   the call stores in it is now there. *)
and write_subject w args taints into =
  match (args, taints) with
  | T.Arg.Value subject :: _, own :: _ ->
      check_subject w subject own;
      (match place subject with Some (l, p) -> add w l p into | None -> ())
  | _ -> ()

(* effects.md §4.4: a `!` call is an error when its subject reaches a guest
   derived from a read-only binding. *)
and check_subject w (subject : T.Expr.t) own =
  let reaches =
    match place subject with
    | Some (l, _) when direct w l -> Taint.empty
    | Some (l, p) -> navigate (taint_of w l) p
    | None -> own
  in
  if read_only w reaches then
    error w subject.T.Expr.span
      (Printf.sprintf "a `!` call writes its subject, and it reaches a guest taken from %s"
         (blame w reaches))

and opt_handler w = function Some h -> handler_value w h | None -> Taint.empty

and handler_value w (h : T.Handler.t) =
  Option.iter
    (fun (b : T.Local.t) -> Hashtbl.replace w.taints b.T.Local.id Taint.empty)
    h.T.Handler.binder;
  resolving w h.T.Handler.body

(* A `return` in a match arm gives the arm's value, not the verb's
   (docs/semantics.md §9). *)
and arm_value w b =
  let verb = w.returned in
  w.returned <- Taint.empty;
  block w b;
  let arm = w.returned in
  w.returned <- verb;
  arm

and resolving w b =
  w.resolved <- Taint.empty :: w.resolved;
  block w b;
  match w.resolved with
  | r :: rest ->
      w.resolved <- rest;
      r
  | [] -> Taint.empty

and lambda w (e : T.Expr.t) (l : T.Lambda.t) =
  (* A lambda captures nothing (concurrency.md §5.2): its body sees only its
     own parameters, every one read-only but a `mut` lambda's `this`. *)
  let writable_this =
    match e.T.Expr.ty with Ty.Verb { Ty.this_ = Some _; is_mut = true; _ } -> true | _ -> false
  in
  let inner =
    { w with taints = Hashtbl.create 16; returned = Taint.empty; resolved = [] }
  in
  List.iteri
    (fun i (p : T.Local.t) ->
      let read_only = not (i = 0 && writable_this) in
      Hashtbl.replace w.origins p.T.Local.id { name = p.T.Local.name; read_only };
      Hashtbl.replace inner.taints p.T.Local.id (Taint.singleton (elem p.T.Local.id [] [])))
    l.T.Lambda.params;
  block inner l.T.Lambda.body;
  Taint.empty

and block w (b : T.Block.t) = List.iter (stat w) b.T.Block.stats

and stat w (s : T.Stat.t) =
  match s.T.Stat.node with
  | T.Stat.Expr e | T.Stat.Spawn e | T.Stat.Abort e -> ignore (expr w e)
  | T.Stat.Let { local; value } ->
      Hashtbl.replace w.taints local.T.Local.id (store local.T.Local.ty (expr w value))
  | T.Stat.Assign { target; value } -> (
      let v = store target.T.Expr.ty (expr w value) in
      match place target with
      | Some (l, []) when not (direct w l) -> Hashtbl.replace w.taints l.T.Local.id v
      (* A store through a guest is rejected whatever the guest was taken
         from (lifetimes.md §1.1, [Guests]), so only a `!` call is left for
         this rule. *)
      | Some (l, p) -> add w l p v
      | None -> ignore (expr w target))
  | T.Stat.Return e -> w.returned <- Taint.union w.returned (store e.T.Expr.ty (expr w e))
  | T.Stat.Resolve e -> (
      let v = expr w e in
      match w.resolved with r :: rest -> w.resolved <- Taint.union r v :: rest | [] -> ())

(* ---------------------------------------------------------------------- *)
(* Verbs                                                                  *)
(* ---------------------------------------------------------------------- *)

type body = { decl : int; signature : S.t; params : T.Local.t list; run : walk -> unit }

let walk_body ~report (b : body) =
  let w =
    {
      report;
      taints = Hashtbl.create 32;
      origins = Hashtbl.create 8;
      returned = Taint.empty;
      resolved = [];
    }
  in
  let writable_this = b.signature.S.is_mut && S.is_method b.signature in
  List.iteri
    (fun i (p : T.Local.t) ->
      let read_only = not (i = 0 && writable_this) in
      Hashtbl.replace w.origins p.T.Local.id { name = p.T.Local.name; read_only };
      Hashtbl.replace w.taints p.T.Local.id (Taint.singleton (elem p.T.Local.id [] [])))
    b.params;
  b.run w;
  let index = Hashtbl.create 8 in
  List.iteri (fun i (p : T.Local.t) -> Hashtbl.replace index p.T.Local.id i) b.params;
  let to_index s =
    Taint.fold
      (fun e acc ->
        match Hashtbl.find_opt index e.origin with
        | Some i -> Taint.add (elem i e.src e.at) acc
        | None -> acc)
      s Taint.empty
  in
  let into_this =
    match b.params with
    | this :: _ when writable_this ->
        Taint.remove (elem 0 [] []) (to_index (taint_of w this))
    | _ -> Taint.empty
  in
  merge b.decl { result = to_index w.returned; into_this }

let bodies (p : T.Program.t) =
  let of_decl (d : T.Decl.t) =
    match d.T.Decl.node with
    | T.Decl.Verb { signature; body = T.Decl.Checked { params; body } } ->
        Some { decl = d.T.Decl.id; signature; params; run = (fun w -> block w body) }
    | T.Decl.Subscript { signature; params; value = Some v } ->
        Some
          {
            decl = d.T.Decl.id;
            signature;
            params;
            run = (fun w -> w.returned <- Taint.union w.returned (expr w v));
          }
    | _ -> None
  in
  List.concat_map
    (fun (pkg : T.Package.t) -> List.filter_map of_decl pkg.T.Package.decls)
    p.T.Program.packages
  @ List.map
      (fun (i : T.Instance.t) ->
        {
          decl = i.T.Instance.decl;
          signature = i.T.Instance.signature;
          params = i.T.Instance.params;
          run = (fun w -> block w i.T.Instance.body);
        })
      p.T.Program.instances

let run (p : T.Program.t) =
  Hashtbl.reset summaries;
  let bodies = bodies p in
  (* Every body starts from nothing, so a callee not yet walked is not
     mistaken for one that has no body to walk. *)
  List.iter (fun (b : body) -> Hashtbl.replace summaries b.decl empty) bodies;
  let rec settle () =
    changed := false;
    List.iter (walk_body ~report:false) bodies;
    if !changed then settle ()
  in
  settle ();
  List.iter (walk_body ~report:true) bodies
