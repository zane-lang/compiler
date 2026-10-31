(* Stage 5 (docs/design/optimization.md): every value the program can have at
   compile time computed there. The package constants that fold are found
   first, so that a read of one folds wherever it is; then each function is
   folded from the leaves up. *)

open Cgt.Nodes

let run (p : Program.t) =
  let p = Peel.program p in
  let table f xs =
    let t = Hashtbl.create 64 in
    List.iter (fun x -> let k, v = f x in Hashtbl.replace t k v) xs;
    t
  in
  let prog =
    {
      Eval.funcs = Eval.functions p.Program.funcs;
      layouts = table Fun.id p.Program.layouts;
      globals = table (fun (g : Global.t) -> (g.Global.symbol, g)) p.Program.globals;
      constants = Hashtbl.create 16;
      memo = Value.Key.create 64;
      left = Eval.total;
    }
  in
  Constants.find prog p.Program.funcs;
  let failed = Value.Key.create 64 in
  (* Callees first, a spawned call's thunk and a function named as a value
     among them, each folded body replacing its original, so that a
     caller's evaluation runs what its callees folded to (O6). A call back
     into a function still being folded runs its original body. *)
  let calls (f : Func.t) =
    let found = ref [] in
    Cgt.Traverse.walk_stats
      (fun e ->
        match e.Expr.node with
        | Expr.Call { fn; _ } | Expr.Function fn -> found := fn :: !found
        | _ -> ())
      (function Stat.Spawn { thunk; _ } -> found := thunk :: !found | _ -> ())
      f.Func.body;
    !found
  in
  let folded = Hashtbl.create 64 and visiting = Hashtbl.create 64 in
  let rec visit (f : Func.t) =
    if not (Hashtbl.mem folded f.Func.symbol || Hashtbl.mem visiting f.Func.symbol) then begin
      Hashtbl.replace visiting f.Func.symbol ();
      List.iter
        (fun fn -> Option.iter (fun (e : Eval.entry) -> visit e.Eval.func) (Eval.Funcs.find_opt prog.Eval.funcs fn))
        (calls f);
      let g = Fold.func prog failed f in
      Eval.Funcs.replace prog.Eval.funcs g.Func.symbol (Eval.entry g);
      Hashtbl.replace folded f.Func.symbol g
    end
  in
  List.iter visit p.Program.funcs;
  Loop_pushes.program
    { p with Program.funcs = List.map (fun (f : Func.t) -> Hashtbl.find folded f.Func.symbol) p.Program.funcs }
