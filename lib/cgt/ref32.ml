(* Experimental (docs/experiments/goose-comparison): with `ZANE_REF32=1`,
   every reservation the runtime makes is carved from one range below
   2^35, the cage (runtime/region.c), so a reference is stored as its
   address shifted right by 3, in 32 bits. *)

let on () = Sys.getenv_opt "ZANE_REF32" = Some "1"

(* Experimental: with `ZANE_FRAME_REFS=1` (and not `ZANE_REF32=1`), every
   context's frames are in the 2 GiB right below the program's image
   (runtime/region.c), so a stored reference, which names a frame's slot or
   a global, is its signed 32-bit distance from the image's start; and a
   list's handle is 16 bytes, its count and room 32 bits each. *)
let frames () = Sys.getenv_opt "ZANE_FRAME_REFS" = Some "1" && not (on ())
