(* A whole program lowered (docs/design/lowering.md): each verb's function,
   once the walk in [Lower] has reached it, the functions that make package
   constants (L16), and the program's roots, `main` or a library's every
   verb. *)

module T = Tst.Nodes
module S = Tst.Signature
module Tty = Tst.Ty
open Nodes
open State
open Type_layout
open Verbs
open Outcome
open Build
open Lower

(* Whether a slot of type [t] has a layout lowering knows the size of: a
   declared type, a list or a text. A runtime value such as `Console` is
   the runtime's own, and has none. *)
let rec laid_out (t : Tty.t) =
  match t with
  | Tty.Roaming t -> laid_out t
  | Tty.Named _ -> true
  | _ -> is_text t || is_list t

let func st (v : verb) : Func.t =
  let span = v.body.T.Block.span in
  st.next <- 0;
  st.values <- [];
  st.current <- symbol st v;
  let env = Hashtbl.create 16 in
  let places = ref [] in
  let params =
    List.map
      (fun (p : T.Local.t) ->
        let id = fresh st in
        if by_address st v p then begin
          Hashtbl.replace env p.T.Local.id (Pointer id);
          if laid_out p.T.Local.ty then places := (id, ty st p.T.Local.span p.T.Local.ty) :: !places;
          (id, Nodes.Ty.Ptr)
        end
        else begin
          (* An `&T` parameter is a settled owner's address (memory.md
             §4.1). That owner never moves and outlives the reference
             (§4.2), so its whole slot is there for the call too. *)
          (match p.T.Local.ty with
          | Tty.Reference r when laid_out r -> places := (id, ty st p.T.Local.span r) :: !places
          | _ -> ());
          Hashtbl.replace env p.T.Local.id (slot st p.T.Local.ty id);
          (id, ty st p.T.Local.span p.T.Local.ty)
        end)
      v.params
  in
  let places = List.rev !places in
  (* A `^T` parameter is an owner of the body (lifetimes.md §1.5): it is held
     in the body's own arena, so the body's drain ends it unless the body
     moved it on. *)
  let enter scope =
    List.concat
      (List.map2
         (fun (p : T.Local.t) (id, t) ->
           if roaming st p.T.Local.ty && held st p.T.Local.span p.T.Local.ty then begin
             let kept = fresh st in
             Hashtbl.replace env p.T.Local.id (slot st p.T.Local.ty kept);
             [ bind_local st scope p kept { Expr.node = Expr.Local id; ty = t } ]
           end
           else [])
         v.params params)
  in
  List.iter (fun (id, lit) -> Hashtbl.replace env id (Literal lit)) v.literals;
  let o = outcome st span v in
  let linkage =
    match v.signature.S.home with
    | S.Package p when st.exports p ->
        if v.instance = [] then Linkage.Exported else Linkage.Shared
    | S.Package p when st.stamped p ->
        if v.instance = [] then Linkage.Imported else Linkage.Shared
    | _ ->
        if Hashtbl.mem st.exported v.key then Linkage.Exported
        else if Hashtbl.mem st.imported v.key then Linkage.Imported
        else Linkage.Local
  in
  let linkage =
    if linkage = Linkage.Imported && st.import_bodies then Linkage.Available else linkage
  in
  if linkage = Linkage.Imported then
    { Func.symbol = symbol st v; linkage; params; places; ret = returned o; body = []; values = [] }
  else begin
    st.returns <- (if plain o then Fun.id else outcome_case o done_);
    st.ret <- v.signature.S.ret;
    st.aborts <- Option.value ~default:Tty.Error v.signature.S.abort;
    let ctx =
      {
        env;
        exit = Function;
        expanding = [];
        abort =
          (fun _ value ->
            let value =
              match v.signature.S.abort with
              | Some t -> escape st span t None value
              | None -> value
            in
            [ Stat.Return (outcome_case o aborted value) ]);
        resolve = None;
        finish = no_block;
        exit_call = (fun _ -> [ Stat.Return (outcome_case o exited unit_) ]);
        scope = { arena = None; settles = []; wants = [] };
      }
    in
    let body =
      match Hashtbl.find_opt st.foreign_verbs v.key with
      | Some f -> Lower_foreign.body st env span v f
      | None -> block ~enter st ctx v.body
    in
    { Func.symbol = symbol st v; linkage; params; places; ret = returned o; body; values = st.values }
  end

(* L16. The function that makes a package constant: the first call makes
   its value, in a scope of its own, and stores it in the constant's
   variable, whose blocks then move into the program's own region; every
   call gives the variable's address. A context that finds another making
   it waits for it. A program's constants live as long as it does, as its
   own region does, so nothing ends them. The constant is local to a
   program's object, and shared by every object of a library or a stamped
   dependency that reads it, as a generic instance is. *)
let made st decl : Func.t =
  let c = Hashtbl.find st.constants decl in
  let span = c.value.T.Expr.span in
  st.next <- 0;
  st.current <- c.symbol;
  let linkage =
    if (not st.library) && not (st.stamped c.package) then Linkage.Local else Linkage.Shared
  in
  let lowered = ty st span c.ty in
  let value = c.symbol ^ ".value" and state = c.symbol ^ ".state" in
  st.globals <-
    { Global.symbol = state; linkage; ty = Nodes.Ty.I64; per_thread = false }
    :: { Global.symbol = value; linkage; ty = lowered; per_thread = false }
    :: st.globals;
  let global g = ptr (Expr.Global g) in
  let scope = { arena = None; settles = []; wants = [] } in
  let ctx = { (constant_ctx ()) with scope } in
  let stored = Stat.Store { address = global value; value = moved st ctx span c.ty c.value } in
  let settled = List.concat_map (fun settle -> settle ()) (List.rev scope.settles) in
  let finish =
    Expr.Runtime
      {
        fn = Runtime.Constant_end;
        args = [ global state; global value; layout_table (layout st span c.ty) ];
      }
  in
  let body = (stored :: settled) @ [ Stat.Eval { Expr.node = finish; ty = Nodes.Ty.Void } ] in
  let body = close st scope body in
  let begin_ = Expr.Runtime { fn = Runtime.Constant_begin; args = [ global state ] } in
  let begin_ = { Expr.node = begin_; ty = Nodes.Ty.I64 } in
  let one = { Expr.node = Expr.Int 1L; ty = Nodes.Ty.I64 } in
  let first = Expr.Binary { op = Expr.Eq; left = begin_; right = one } in
  let first = { Expr.node = first; ty = Nodes.Ty.I1 } in
  {
    Func.symbol = c.symbol;
    linkage;
    params = [];
    places = [];
    ret = Nodes.Ty.Ptr;
    body = [ Stat.If { cond = first; body }; Stat.Return (global value) ];
    values = [];
  }

(* docs/design/symbols.md: a lambda is called by the verb it is written in
   and its place among that verb's lambdas, counted from 1 in source order,
   nested ones included, and a package lambda-variable's by the variable.
   [owner] is the verb's symbol, the variable's, or an enum map's. *)
let name_lambdas st owner (b : T.Block.t) =
  let n = ref 0 in
  let rec block (b : T.Block.t) =
    List.iter (fun s -> List.iter expr (Tst.Traverse.stat_exprs s)) b.T.Block.stats
  and expr e = List.iter part (Tst.Traverse.parts e)
  and part = function
    | Tst.Traverse.Same x -> expr x
    | Tst.Traverse.Arm b | Tst.Traverse.Handler b | Tst.Traverse.Block b -> block b
    | Tst.Traverse.Lambda b ->
        incr n;
        st.lambdas <- (b, Printf.sprintf "%s$lambda%d" owner !n) :: st.lambdas;
        block b
  in
  block b

(* The functions a library's object holds, besides what they call: every
   verb of each of its own packages that is not generic and has a function of its
   own (L11), and every lambda-variable, which other objects call by name
   (docs/design/separate-compilation.md C5). *)
let library_roots st (root : T.Package.t) =
  List.iter
    (fun (d : T.Decl.t) ->
      let declared (signature : S.t) =
        if signature.S.generics = [] then
          match verb_of st d.T.Decl.id [] with
          | Some v when not (expands v) -> ignore (symbol st v)
          | _ -> ()
      in
      match d.T.Decl.node with
      | T.Decl.Verb { signature; body = T.Decl.Checked _ | T.Decl.Foreign _ } -> declared signature
      | T.Decl.Subscript { signature; value = Some _; _ } -> declared signature
      | T.Decl.Constant { value = { T.Expr.node = T.Expr.Lambda l; ty; span }; _ } ->
          Hashtbl.replace st.exported ("lambda " ^ Lower_lambda.lambda st span ty l) ()
      | _ -> ())
    root.T.Package.decls

(* Every call the program spawns: a spawn anywhere in any package of the
   build, a stamped dependency's included, since its objects are built from
   the source checked here (docs/design/separate-compilation.md C2). A spawn
   read where it is written runs at once, but counts too. *)
let spawned (p : T.Program.t) =
  let found = ref [] in
  let call (e : T.Expr.t) =
    found := (match e.T.Expr.node with T.Expr.Spawn inner -> inner | _ -> e) :: !found
  in
  let rec block (b : T.Block.t) = List.iter stat b.T.Block.stats
  and stat (s : T.Stat.t) =
    (match s.T.Stat.node with T.Stat.Spawn e -> call e | _ -> ());
    List.iter expr (Tst.Traverse.stat_exprs s)
  and expr (e : T.Expr.t) =
    (match e.T.Expr.node with T.Expr.Spawn inner -> call inner | _ -> ());
    List.iter
      (function
        | Tst.Traverse.Same x -> expr x
        | Tst.Traverse.Arm b | Tst.Traverse.Handler b | Tst.Traverse.Block b | Tst.Traverse.Lambda b ->
            block b)
      (Tst.Traverse.parts e)
  in
  let decl (d : T.Decl.t) =
    match d.T.Decl.node with
    | T.Decl.Verb { body = T.Decl.Checked { body; _ }; _ } -> block body
    | T.Decl.Subscript { value = Some e; _ } | T.Decl.Constant { value = e; _ } -> expr e
    | T.Decl.Enum_map { entries; _ } -> List.iter (fun (_, e) -> expr e) entries
    | _ -> ()
  in
  List.iter (fun (pkg : T.Package.t) -> List.iter decl pkg.T.Package.decls) p.T.Program.packages;
  List.iter (fun (i : T.Instance.t) -> block i.T.Instance.body) p.T.Program.instances;
  List.iter (fun (d : T.Defaults.t) -> List.iter (fun (_, e) -> expr e) d.T.Defaults.values) p.T.Program.defaults;
  !found

(* The places spawned calls may write back into (concurrency.md §4.4): each
   `mut` call's subject reached through an owner, which the call works on a
   copy of and writes back when it returns (Lower_spawn). A subject whose
   type, or whose owner's, names a type parameter is in a generic verb's
   body, which is lowered only as its instances, and they are walked too. *)
let written_back st calls =
  let subject (e : T.Expr.t) =
    match e.T.Expr.node with
    | T.Expr.Call { callee = { owner = S.Declared id; instance; _ }; args; _ } -> (
        match verb_of st id instance with
        | Some v when v.signature.S.is_mut -> (
            match Lower_calls.passed v args with T.Arg.Value s :: _ -> Some s | _ -> None)
        | Some _ -> None
        | None -> ( match args with T.Arg.Value s :: _ -> Some s | _ -> None))
    | T.Expr.Call_value { callee; args = T.Arg.Value s :: _; _ } -> (
        match Tty.strip_mode callee.T.Expr.ty with
        | Tty.Verb fv when not (fv.Tty.is_mut && Option.is_some fv.Tty.this_) -> None
        | _ -> Some s)
    | _ -> None
  in
  List.filter_map
    (fun e ->
      match subject e with
      | Some s ->
          let w = written_into st s in
          let generic = function Some (o, _) -> Tty.free_params o <> [] | None -> false in
          if Tty.free_params w.of_type = [] && (not (generic w.place)) && through_owner st s
             && not (reference st w.of_type)
          then Some w
          else None
      | None -> None)
    calls

(* A program lowers from its root package's `main`; a [library] from every
   function its own packages declare, into an object with no entry.

   A package given a stamp is named by it already: its identity is its
   stamped name (docs/design/separate-compilation.md C6, C10), which a `%`
   in it gives away, since no package name holds one. The packages that
   share the first package's stamp, or are unstamped with it, are the
   project being compiled: its library packages, which a library's object
   holds every one of (dependencies.md §3.1). Any other stamp is a
   dependency, which arrives as objects of its own, and an unstamped
   dependency of a stamped package is compiled into its module (C6). A
   library's own packages without a stamp are named with the `!`
   placeholder, and ones with a stamp are named with it, as a dependency
   compiled from source is. *)
(* L16's constants, in the order they are made: the packages a package
   depends on first, and within a package in the order declared. A constant
   that is a lambda is a function, made by nothing. *)
let constants_in_order (p : T.Program.t) =
  let constant (d : T.Decl.t) =
    match d.T.Decl.node with
    | T.Decl.Constant { value = { T.Expr.node = T.Expr.Lambda _; _ }; _ } -> None
    | T.Decl.Constant _ -> Some d.T.Decl.id
    | _ -> None
  in
  List.concat_map
    (fun (pkg : T.Package.t) -> List.filter_map constant pkg.T.Package.decls)
    (List.rev p.T.Program.packages)

(* The entry the runtime calls, `zane.start`: [makes], then a call to
   [entry], `main`'s symbol among [funcs], whose result it drops. *)
let start_function st main span entry makes (funcs : Func.t list) =
  let ret =
    match List.find_opt (fun (f : Func.t) -> f.Func.symbol = entry) funcs with
    | Some f -> f.Func.ret
    | None -> Diagnostic.bug "lowering: `main` was not lowered"
  in
  let call = { Expr.node = Expr.Call { fn = entry; args = [] }; ty = ret } in
  let t = main.signature.S.ret in
  let dropped =
    if held st span t then begin
      let scope = { arena = None; settles = []; wants = [] } in
      close st scope [ bind st scope span t (fresh st) call ]
    end
    else [ Stat.Eval call ]
  in
  {
    Func.symbol = "zane.start";
    linkage = Linkage.Local;
    params = [];
    places = [];
    ret = Nodes.Ty.Void;
    body = makes @ dropped;
    values = [];
  }

let program ?(library = false) ?(import_bodies = false) ?(fixed_region = Runtime.default_fixed_region)
    (p : T.Program.t) =
  let stamp_of id =
    match String.rindex_opt id '%' with Some i -> String.sub id 0 (i + 1) | None -> ""
  in
  let root = match p.T.Program.packages with r :: _ -> stamp_of r.T.Package.name | [] -> "" in
  let own p = String.equal (stamp_of p) root in
  let exports p = library && own p in
  let stamp p = if library && own p && root = "" then "!" else "" in
  let stamped p = (not (own p)) && stamp_of p <> "" in
  (* A program none of whose code spawns runs on one thread, so nothing
     writes back while it reads (lowering.md §9). A library's code may run
     in a program that spawns. *)
  let calls = spawned p in
  let exclusive = (not library) && calls = [] in
  let st = create ~region:fixed_region ~import_bodies ~library ~exclusive ~exports ~stamp ~stamped in
  let add decl instance signature params body =
    let key = key decl instance in
    Hashtbl.replace st.verbs key { decl; key; instance; signature; params; body; literals = [] };
    name_lambdas st (Symbol.verb ~stamp:st.stamp signature instance) body
  in
  List.iter
    (fun (pkg : T.Package.t) ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Type { name; params; reference; definition } ->
              Hashtbl.replace st.types (pkg.T.Package.name, name) (params, definition, reference)
          | T.Decl.Enum_map { enum; property; entries; _ } ->
              Hashtbl.replace st.maps d.T.Decl.id (enum, entries);
              let stat (_, (e : T.Expr.t)) = { T.Stat.node = T.Stat.Expr e; span = e.T.Expr.span } in
              name_lambdas st
                (Symbol.ty ~stamp:st.stamp enum ^ "." ^ property)
                { T.Block.stats = List.map stat entries; span = d.T.Decl.span }
          | T.Decl.Constant { name; value; ty } -> (
              let owner = st.stamp pkg.T.Package.name ^ pkg.T.Package.name ^ "$" ^ name in
              Hashtbl.replace st.constants d.T.Decl.id
                { symbol = owner; package = pkg.T.Package.name; ty; value };
              match value.T.Expr.node with
              | T.Expr.Lambda { body; _ } ->
                  if st.stamped pkg.T.Package.name then
                    Hashtbl.replace st.imported ("lambda " ^ owner) ();
                  st.lambdas <- (body, owner) :: st.lambdas;
                  name_lambdas st owner body
              | _ ->
                  let stat = { T.Stat.node = T.Stat.Expr value; span = value.T.Expr.span } in
                  name_lambdas st owner { T.Block.stats = [ stat ]; span = value.T.Expr.span })
          | T.Decl.Verb { signature; body = T.Decl.Checked { params; body } } ->
              add d.T.Decl.id [] signature params body
          (* A foreign verb's function takes the parameters its signature
             names, and calls into C (Lower_foreign). *)
          | T.Decl.Verb { signature; body = T.Decl.Foreign f } ->
              let span = d.T.Decl.span in
              let params =
                List.mapi
                  (fun i (p : S.param) -> { T.Local.id = -(i + 1); name = p.S.name; ty = p.S.ty; span })
                  signature.S.params
              in
              Hashtbl.replace st.foreign_verbs (key d.T.Decl.id []) f;
              add d.T.Decl.id [] signature params { T.Block.stats = []; span }
          (* A subscript's body is the place it names (functions.md §2.9). *)
          | T.Decl.Subscript { signature; params; value = Some e } ->
              let return = { T.Stat.node = T.Stat.Return e; span = e.T.Expr.span } in
              let body = { T.Block.stats = [ return ]; span = e.T.Expr.span } in
              add d.T.Decl.id [] signature params body
          | _ -> ())
        pkg.T.Package.decls)
    p.T.Program.packages;
  List.iter
    (fun (d : T.Defaults.t) ->
      Hashtbl.replace st.defaults (key d.T.Defaults.decl d.T.Defaults.args) d.T.Defaults.values)
    p.T.Program.defaults;
  (* An instance's signature still names its parameters; its body already
     has its arguments. *)
  List.iter
    (fun (i : T.Instance.t) ->
      let sub = Tty.subst (List.map (fun ((p : Tty.param), a) -> (p.id, a)) i.T.Instance.args) in
      let signature = i.T.Instance.signature in
      let signature =
        { signature with S.ret = sub signature.S.ret; abort = Option.map sub signature.S.abort }
      in
      add i.T.Instance.decl i.T.Instance.args signature i.T.Instance.params i.T.Instance.body)
    p.T.Program.instances;
  if not library then st.written_back <- Some (written_back st calls);
  try
    (* The root package is the first (docs/design/semantics.md §2), and its `main`
       is where the program starts (packages.md §6.2). *)
    let root =
      match p.T.Program.packages with
      | r :: _ -> r
      | [] -> Diagnostic.bug "lowering: assembly gave it no packages"
    in
    (* In the order calls first reach them, the roots first. *)
    let rec drain acc =
      match Queue.take_opt st.pending with
      | Some v -> drain (func st v :: acc)
      | None -> (
          match Queue.take_opt st.made with
          | Some decl -> drain (made st decl :: acc)
          | None -> List.rev acc)
    in
    let finish ?(start = fun _ -> []) entry =
      let funcs = drain [] in
      let funcs = start funcs @ funcs @ List.rev st.spawned in
      let layouts = List.rev_map (fun n -> (n, Hashtbl.find st.layouts n)) st.named in
      Ok (Regions.run ~wants:st.wants { Program.funcs; entry; layouts; globals = List.rev st.globals; foreign = List.rev st.thunks; exclusive = st.exclusive })
    in
    if library then begin
      List.iter
        (fun (pkg : T.Package.t) -> if own pkg.T.Package.name then library_roots st pkg)
        p.T.Program.packages;
      finish None
    end
    else
      let main =
        List.find_map
          (fun (d : T.Decl.t) ->
            match d.T.Decl.node with
            | T.Decl.Verb { signature; _ } when signature.S.name = "main" ->
                verb_of st d.T.Decl.id []
            | _ -> None)
          root.T.Package.decls
      in
      match main with
      | None ->
          Diagnostic.bug
            (Printf.sprintf "lowering: the root package `%s` declares no `main`"
               root.T.Package.name)
      | Some main ->
          (* The runtime calls `main` and reads no outcome from it. *)
          let span = main.body.T.Block.span in
          if not (plain (outcome st span main)) then
            Diagnostic.bug ~span "lowering: `main` can abort or exit";
          (* L16: every package constant is made before `main` runs, the
             packages a package depends on first, and within a package in
             the order declared. One that reads another makes that one
             first. *)
          let constants = constants_in_order p in
          (* The runtime calls `void zane_main(void)` (runtime/zane.h), so
             the entry is always a function of that type: one that makes the
             constants, if there are any, and then calls `main`, discarding
             its result. Calling `main` itself would give the runtime a
             function whose type depends on what `main` returns. A result
             that is an owner or owns a block is held in the start
             function's own arena, as any dropped result like it is, so a
             large one takes a frame of the program's range rather than the
             machine stack. *)
          let entry = symbol st main in
          (* Made before [finish] drains, so what they call is lowered. *)
          let makes = List.map (fun decl -> Stat.Eval (constant st decl)) constants in
          finish
            ~start:(fun funcs -> [ start_function st main span entry makes funcs ])
            (Some "zane.start")
  with Refused d -> Error d
