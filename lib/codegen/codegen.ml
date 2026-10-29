(* Codegen's entry module (docs/design/lowering.md §1). *)

type tier = Tiers.tier = Plain | Tier0 | Tier1

(* Lowering refuses each type that reaches the size limit (Cgt.Nodes.Ty.limit)
   where it is named. A frame is laid out here, from slots each below it, and
   one whose slots together reach it is refused as the build's error. *)

(* How many contexts [with_program] has made and not yet disposed, which
   the unit tests read. *)
let live = Atomic.make 0
let live_contexts () = Atomic.get live

(* The program, emitted into [m], whose context and lifetime are its
   caller's ([with_program]). Its entry is named `zane_main` whatever its symbol,
   since that is the name the runtime calls (L16). A function other objects
   link against keeps its symbol in theirs too, and one a stamped
   dependency's objects define is only declared, or has an
   [available_externally] body that LLVM can inline but never emits
   (docs/design/separate-compilation.md); the rest are local to this one.
   With [pack], every function but the entry is named with [packed] after
   its symbol, so an object built with packing links only against objects
   built with it too: one built without would call it with the other
   convention (docs/design/lowering.md §9). The module is for [triple] from the start, so each access is emitted
   with the alignment [data_layout] gives its type. *)
let packed = "~packed"

let program ?(fixed_region = Cgt.Runtime.default_fixed_region)
    ?(spawned_fixed_region = Cgt.Runtime.default_spawned_fixed_region) ?(pack = false) ?(memos = []) ?(version = false)
    ~triple ~data_layout m (p : Cgt.Nodes.Program.t) =
  let open Cgt.Nodes in
  let open Emit in
  let ctx = Llvm.module_context m in
  Llvm.set_target_triple triple m;
  Llvm.set_data_layout data_layout m;
  let env =
    {
      ctx;
      m;
      ptr = Llvm.pointer_type ctx;
      i64 = Llvm.i64_type ctx;
      funcs = Hashtbl.create 32;
      abis = Hashtbl.create 32;
      invokers = Hashtbl.create 8;
      callable = Hashtbl.create 8;
      registers = registers triple;
      pack;
      passings = Hashtbl.create 32;
      results = results triple;
      returnings = Hashtbl.create 32;
      globals = Hashtbl.create 8;
      walks = None;
      handle_tag = fst (tags ctx);
      value_tag = snd (tags ctx);
      version;
    }
  in
  env.walks <-
    Some
      (Walks.create
         { Walks.ctx; m; ptr = env.ptr; i64 = env.i64; runtime = runtime env }
         p.Program.layouts);
  List.iter
    (fun (g : Global.t) ->
      let v =
        match g.Global.linkage with
        | Cgt.Nodes.Linkage.Imported -> Llvm.declare_global (stored env g.Global.ty) g.Global.symbol m
        | _ -> Llvm.define_global g.Global.symbol (Llvm.const_null (stored env g.Global.ty)) m
      in
      if g.Global.per_thread then Llvm.set_thread_local true v;
      (* The runtime's, read at a fixed offset from the thread's pointer as
         Walks.zane_open is. *)
      if g.Global.per_thread && g.Global.linkage = Cgt.Nodes.Linkage.Imported then
        Llvm.set_thread_local_mode Llvm.ThreadLocalMode.InitialExec v;
      (match g.Global.linkage with
      | Cgt.Nodes.Linkage.Local -> Llvm.set_linkage Llvm.Linkage.Internal v
      | Cgt.Nodes.Linkage.Shared -> Llvm.set_linkage Llvm.Linkage.Link_once_odr v
      | Cgt.Nodes.Linkage.Exported | Cgt.Nodes.Linkage.Imported -> ()
      | Cgt.Nodes.Linkage.Available -> Diagnostic.bug "an optimization-only global");
      Hashtbl.replace env.globals g.Global.symbol v)
    p.Program.globals;
  List.iter
    (fun (c : Callback.t) -> Hashtbl.replace env.invokers (c.Callback.params, c.Callback.ret) c.Callback.symbol)
    p.Program.invokers;
  (* A lambda's adapter is named as the glue's C entry declares it
     (docs/design/ffi.md F11). *)
  let adapters = List.map (fun (c : Callback.t) -> Callback.adapter c.Callback.symbol) p.Program.callbacks in
  List.iter
    (fun (f : Func.t) ->
      let a = abi env (List.map snd f.Func.params) f.Func.ret in
      let fty = abi_type env a in
      let entry = Some f.Func.symbol = p.Program.entry in
      let name =
        if entry then "zane_main"
        else if List.mem f.Func.symbol adapters then Walks.foreign_name m f.Func.symbol
        else if pack then f.Func.symbol ^ packed
        else f.Func.symbol
      in
      let fn =
        match f.Func.linkage with
        | Cgt.Nodes.Linkage.Imported -> Llvm.declare_function name fty m
        | _ -> Llvm.define_function name fty m
      in
      (match f.Func.linkage with
      | _ when entry -> ()
      | Cgt.Nodes.Linkage.Local -> Llvm.set_linkage Llvm.Linkage.Internal fn
      | Cgt.Nodes.Linkage.Exported | Cgt.Nodes.Linkage.Imported -> ()
      | Cgt.Nodes.Linkage.Available -> Llvm.set_linkage Llvm.Linkage.Available_externally fn
      | Cgt.Nodes.Linkage.Shared -> Llvm.set_linkage Llvm.Linkage.Link_once_odr fn);
      declare_abi env fn a;
      declare_places env fn f a;
      Hashtbl.replace env.abis f.Func.symbol a;
      if Callback.crosses (List.map snd f.Func.params) f.Func.ret then Hashtbl.replace env.callable f.Func.symbol ();
      Hashtbl.replace env.funcs f.Func.symbol (fn, fty))
    (p.Program.funcs @ List.map (fun (m : Cgt.Memo.t) -> m.Cgt.Memo.func) memos);
  List.iter
    (fun (f : Func.t) -> if f.Func.linkage <> Cgt.Nodes.Linkage.Imported then func env f)
    p.Program.funcs;
  List.iter (Memos.memo env) memos;
  (* The module with the program's entry also says how large each context's
     range is, which the runtime reads when it makes one. *)
  if Option.is_some p.Program.entry then
    List.iter
      (fun (name, size) ->
        let g = Llvm.define_global name (Llvm.const_int env.i64 size) m in
        Llvm.set_global_constant true g)
      [ ("zane_fixed_region", fixed_region); ("zane_spawned_fixed_region", spawned_fixed_region) ];
  Walks.finish (walks env);
  match Llvm_analysis.verify_module m with
  | Some problem -> Diagnostic.bug ("codegen built an invalid module: " ^ problem)
  | None -> ()

(* The program's module lives only while [f] runs: its context and the
   module are disposed however [f] or the emit ends, since LLVM's bindings
   free neither on their own. *)
let with_module ?target ?pack ?memos ?version ?fixed_region ?spawned_fixed_region ?(c = []) p f =
  Result.bind (Build.target_machine ?target ~optimize:false ()) (fun (triple, tm) ->
      let data_layout = Llvm_target.DataLayout.as_string (Llvm_target.TargetMachine.data_layout tm) in
      let ctx = Llvm.create_context () in
      Atomic.incr live;
      Fun.protect
        ~finally:(fun () ->
          Llvm.dispose_context ctx;
          Atomic.decr live)
        (fun () ->
          let m = Llvm.create_module ctx "zane" in
          Fun.protect
            ~finally:(fun () ->
              Build.detach m;
              Llvm.dispose_module m)
            (fun () ->
              match program ?fixed_region ?spawned_fixed_region ?pack ?memos ?version ~triple ~data_layout m p with
              | () ->
                  Build.attach m c;
                  f m
              | exception Cgt.Nodes.Ty.Too_large ->
                  Error "a scope's frame takes 2^48 bytes or more, past the limit on any value's size")))

(* The program's module lives only while [f] runs: its context and the
   module are disposed however [f] or the emit ends, since LLVM's bindings
   free neither on their own. With [memoize], the functions [Cgt.Memo]
   picks are remembered, the same in every build, so a tiered build's two
   tiers emit the same module (docs/design/tiers.md T3). With [version],
   each loop over elements the optimized passes can split is emitted twice
   for them to tell apart (Emit.versioned); a tiered build's two tiers
   both take it. *)
let with_program ?target ?pack ?(memoize = false) ?version ?fixed_region ?spawned_fixed_region ?c p f =
  let p, memos = if memoize then Cgt.Memo.plan p else (p, []) in
  with_module ?target ?pack ~memos ?version ?fixed_region ?spawned_fixed_region ?c p f

let ir m = Llvm.string_of_llmodule m

let target_cpu ?target () =
  Result.map
    (fun (_, tm) -> Llvm_target.TargetMachine.cpu tm)
    (Build.target_machine ?target ~optimize:true ())

let c_compiler = Build.cc

type c_package = Foreign_c.package = {
  prefix : string;
  sources : (string * string) list;
  glue : (string * string) list;
  thunks : string list;
}

let global_prefix ?target () =
  Result.map
    (fun (_, tm) -> Walks.global_prefix (Llvm_target.DataLayout.as_string (Llvm_target.TargetMachine.data_layout tm)))
    (Build.target_machine ?target ~optimize:false ())

let executable ?target ?optimize ?tier ?link m output =
  Build.executable ?target ?optimize ?tier ?link m output
let shared_library ?target m output = Build.shared_library ?target m output
let object_file ?target ?optimize ?tier m output = Build.object_file ?target ?optimize ?tier m output
let prepare ?target ?optimize ?tier m = Result.map ignore (Build.prepare ?target ?optimize ?tier m)
let bundle_runtime ~target ~optimize dir = Build.bundle_runtime ~target ~optimize dir
