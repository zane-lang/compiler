(* CGT terms built by hand, and a stage 5 program to evaluate them in, for
   the tests of the evaluator and of codegen. *)

module C = Cgt.Nodes
module Value = Optimize__Value
module Eval = Optimize__Eval

let e node ty = { C.Expr.node; ty }
let i64 n = e (C.Expr.Int n) C.Ty.I64

let program funcs =
  {
    Eval.funcs = Eval.functions funcs;
    layouts = Hashtbl.create 1;
    globals = Hashtbl.create 1;
    constants = Hashtbl.create 1;
    memo = Value.Key.create 8;
    left = Eval.total;
    c = Optimize__C_cross.program None [] [];
    holding = Hashtbl.create 1;
  }

let func ?(values = []) symbol params body =
  { C.Func.symbol; linkage = C.Linkage.Local; params; places = []; ret = C.Ty.I64; body; values }
