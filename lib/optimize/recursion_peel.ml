(* EXPERIMENT (LangArena zane-vs-goose; on with ZANE_PEEL_RECURSION=1): a
   function that calls itself made to do two levels of its recursion per
   call, as clang's inlining does for Goose's Binarytrees::Arena `build`
   (both leaf children of a depth-1 node written with no call, half of
   all nodes).

   LLVM's inliner never inlines a function into itself. So a copy of the
   function is made, `f$peel`, local to the module, whose own calls still
   go to `f`; `f`'s calls to itself go to the copy instead, and codegen
   marks the copy always to be inlined (Build, before the passes): `f`
   then holds the copy's body at each of its recursive calls, and the
   copy, no longer called, is dropped. A function of more than [budget]
   nodes is left, as is one whose body another object provides. *)

open Cgt.Nodes

let on () = Sys.getenv_opt "ZANE_PEEL_RECURSION" = Some "1"

let budget = 300

let suffix = "$peel"

let size ss =
  let n = ref 0 in
  Cgt.Traverse.walk_stats (fun _ -> incr n) (fun _ -> incr n) ss;
  !n

let calls_self (f : Func.t) =
  Cgt.Traverse.exists_in f.Func.body
    ~expr:(fun e -> match e.Expr.node with Expr.Call { fn; _ } -> fn = f.Func.symbol | _ -> false)
    ~stat:(fun _ -> false)

(* [ss] with every call to [from] made a call to [into]. *)
let redirect from into ss =
  let rec stats ss = List.map stat ss
  and stat (s : Stat.t) : Stat.t = Cgt.Traverse.map_stat_parts expr stats s
  and expr (e : Expr.t) : Expr.t =
    match e.Expr.node with
    | Expr.Call { fn; args } when fn = from -> { e with node = Expr.Call { fn = into; args = List.map expr args } }
    | _ -> Cgt.Traverse.map_expr_parts expr stats e
  in
  stats ss

let peelable (f : Func.t) =
  (match f.Func.linkage with Linkage.Local | Linkage.Exported | Linkage.Shared -> true | _ -> false)
  && calls_self f && size f.Func.body <= budget

let program (p : Program.t) : Program.t =
  if not (on ()) then p
  else
    let funcs =
      List.concat_map
        (fun (f : Func.t) ->
          if peelable f then begin
            let copy = { f with Func.symbol = f.Func.symbol ^ suffix; linkage = Linkage.Local } in
            if Sys.getenv_opt "ZANE_PEEL_RECURSION_DEBUG" = Some "1" then Printf.eprintf "peel: %s\n" f.Func.symbol;
            [ { f with Func.body = redirect f.Func.symbol copy.Func.symbol f.Func.body }; copy ]
          end
          else [ f ])
        p.Program.funcs
    in
    { p with Program.funcs }
