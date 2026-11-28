(* Calls marked `comptime` (spec effects.md §5.6, docs/design/comptime.md),
   evaluated in every build, between lowering and stage 5. Lowering lifted
   each marked call into a function of no parameters (Cgt.Lower_comptime);
   each is run here, to completion, and the value it gives is written as
   code in place of every call of it. A call that cannot be evaluated, or
   that writes capability-backed state, is a compile-time error naming the
   call. The runs take nothing from stage 5's budgets (optimization.md O6),
   and no budget of their own ends them. *)

open Cgt.Nodes
module V = Value

(* The call of a lifted function at its site: through its address, with no
   arguments. *)
let site (e : Expr.t) =
  match e.Expr.node with
  | Expr.Call_value { fn = { Expr.node = Expr.Function s; _ }; args = [] } -> Some s
  | _ -> None

let failed span message = Diagnostic.error span message

(* The message a run that could not finish gives the program's author. *)
let why_not span = function
  | V.Stop why ->
      failed span
        ("this `comptime` call cannot be evaluated at compile time: it reaches " ^ why)
  | Eval.Writes what ->
      failed span
        ("a `comptime` call writes no capability-backed state, and this one does: " ^ what)
  | Stack_overflow ->
      failed span "this `comptime` call nests calls deeper than the compiler can evaluate"
  | e -> raise e

(* The value [symbol] gives, run with the build's [arguments], reading the
   monotonic clock through [clock]. *)
let evaluate prog ~arguments ~clock (symbol, span) =
  let run = Eval.start ~explicit:{ Eval.arguments; reads = 0; clock } prog in
  match Eval.call run symbol [] with
  | exception ((V.Stop _ | Eval.Writes _ | Stack_overflow) as e) -> Error (why_not span e)
  | v -> (
      match V.export v with
      | Some c -> Ok c
      | None ->
          Error
            (failed span
               "this `comptime` call gives a value that holds an address, which cannot be built \
                into the program"))

(* The code that builds [c], a value of [t], in a function whose locals and
   labels [fresh] numbers. *)
let built ~fresh span t c =
  match Materialize.expr ~fresh t c with
  | Some e -> e
  | None -> Diagnostic.bug ~span "a `comptime` call's value that cannot be written as code"

(* [f] with every call of a lifted function in [values] replaced by the code
   that builds the value it gave. Each list the code makes takes locals and a
   label [f] does not use yet. *)
let replace values (f : Func.t) =
  let next = ref (Fold.largest f) in
  let fresh () =
    incr next;
    !next
  in
  let value (e : Expr.t) =
    Option.bind (site e) (Hashtbl.find_opt values)
    |> Option.map (fun (c, span) -> built ~fresh span e.Expr.ty c)
  in
  { f with Func.body = Cgt.Traverse.map_stats value (fun _ -> None) f.Func.body }

let run ?(c = []) ?(clock = Eval.Live) ~arguments (p : Program.t) =
  if p.Program.comptime = [] then Ok p
  else
    let prog = Eval.program_of ~c p in
    ignore (Constants.register prog p.Program.funcs);
    (* In the order lowering reached them. Once one is evaluated, its
       function gives its value at once, to a later one that calls it. *)
    let values = Hashtbl.create 16 in
    let errors =
      List.filter_map
        (fun ((symbol, span) as marked) ->
          match evaluate prog ~arguments ~clock marked with
          | Error d -> Some d
          | Ok c ->
              Hashtbl.replace values symbol (c, span);
              (match Eval.Funcs.find_opt prog.Eval.funcs symbol with
              | Some e ->
                  let n = ref 0 in
                  let fresh () =
                    incr n;
                    !n
                  in
                  let body = [ Stat.Return (built ~fresh span e.Eval.func.Func.ret c) ] in
                  Eval.Funcs.replace prog.Eval.funcs symbol
                    (Eval.entry { e.Eval.func with Func.body })
              | None -> ());
              None)
        p.Program.comptime
    in
    if errors <> [] then Error errors
    else
      let lifted = Hashtbl.create 16 in
      List.iter (fun (s, _) -> Hashtbl.replace lifted s ()) p.Program.comptime;
      Ok
        {
          p with
          Program.funcs =
            List.filter_map
              (fun (f : Func.t) ->
                if Hashtbl.mem lifted f.Func.symbol then None else Some (replace values f))
              p.Program.funcs;
          comptime = [];
        }
