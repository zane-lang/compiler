(* Experimental (docs/experiments/goose-comparison): with `ZANE_REF32=1`,
   every reservation the runtime makes is carved from one range below
   2^35, the cage (runtime/region.c), so a reference is stored as its
   address shifted right by 3, in 32 bits. *)

let on () = Sys.getenv_opt "ZANE_REF32" = Some "1"
