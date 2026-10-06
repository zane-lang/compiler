(* Stage 5 (docs/design/optimization.md): every value the program can have at
   compile time computed there. The package constants that fold are found
   first, so that a read of one folds wherever it is; then each function is
   folded from the leaves up. *)

open Cgt.Nodes

let run (p : Program.t) =
  let table f xs =
    let t = Hashtbl.create 64 in
    List.iter (fun x -> let k, v = f x in Hashtbl.replace t k v) xs;
    t
  in
  let prog =
    {
      Eval.funcs = table (fun (f : Func.t) -> (f.Func.symbol, f)) p.Program.funcs;
      layouts = table Fun.id p.Program.layouts;
      globals = table (fun (g : Global.t) -> (g.Global.symbol, g)) p.Program.globals;
      constants = Hashtbl.create 16;
      memo = Value.Key.create 64;
      left = Eval.total;
    }
  in
  Constants.find prog p.Program.funcs;
  let failed = Value.Key.create 64 in
  { p with Program.funcs = List.map (Fold.func prog failed) p.Program.funcs }
