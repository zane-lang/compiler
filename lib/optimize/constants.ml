(* The package constants that fold (docs/design/optimization.md O9). A
   constant's maker (docs/design/lowering.md L16) is run as the program would
   run it the first time the constant is read. One that finishes with a
   value that can be written as code, and makes no output, has that value:
   a read of it anywhere folds to it. Making one may read another, so the
   search repeats until a pass finds no new one. *)

open Cgt.Nodes
module V = Value

(* A maker's shape, as lowering builds it: make the value the first time,
   then give its variable's address. *)
let maker (f : Func.t) =
  match f.Func.body with
  | [
   Stat.If
     {
       cond =
         {
           Expr.node =
             Expr.Binary
               {
                 op = Expr.Eq;
                 left =
                   {
                     Expr.node =
                       Expr.Runtime
                         {
                           fn = Cgt.Runtime.Constant_begin;
                           args = [ { Expr.node = Expr.Global state; _ } ];
                         };
                     _;
                   };
                 _;
               };
           _;
         };
       _;
     };
   Stat.Return { Expr.node = Expr.Global value; _ };
  ] ->
      Some { Eval.maker = f.Func.symbol; state; value; known = None }
  | _ -> None

let find (prog : Eval.program) (funcs : Func.t list) =
  let all = List.filter_map maker funcs in
  List.iter
    (fun (k : Eval.constant) ->
      Hashtbl.replace prog.Eval.constants k.Eval.state k;
      Hashtbl.replace prog.Eval.constants k.Eval.value k)
    all;
  let made (k : Eval.constant) =
    let run = Eval.start ~making:k.Eval.state prog in
    match
      let p = Eval.ptr_of (Eval.call run k.Eval.maker []) in
      (V.load p, run.Eval.outputs)
    with
    | value, [] -> (
        match V.export value with
        | Some c when V.size c <= Materialize.max_size ->
            let ty = (Hashtbl.find prog.Eval.globals k.Eval.value).Global.ty in
            if Materialize.expr ty c <> None then Some c else None
        | _ -> None)
    | _, _ :: _ -> None
    | exception (V.Stop _ | Eval.Left _ | Eval.Returned _) -> None
  in
  let rec pass () =
    let found =
      List.fold_left
        (fun found (k : Eval.constant) ->
          if k.Eval.known <> None then found
          else
            match made k with
            | Some c ->
                k.Eval.known <- Some c;
                true
            | None -> found)
        false all
    in
    if found then pass ()
  in
  pass ()
