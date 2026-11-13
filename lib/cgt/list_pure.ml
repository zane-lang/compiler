(* Experimental (docs/experiments/goose-comparison): the functions of the
   program being compiled that cannot change any list's count -- they push
   to, make room in and remove from no list, spawn nothing, call nothing
   through a value or into C (which may call back), and call only such
   functions -- by symbol. A function imported without its body is never
   one: its body is in another object. Emptied when a program is lowered and filled by
   the optimizer's Loop_pushes when it runs, so empty in a build that does
   not optimize; read by codegen, which makes room before a loop of pushes only
   when nothing else in the loop could take it (Loop_shapes.may_grow). *)

let functions : (string, unit) Hashtbl.t = Hashtbl.create 64
