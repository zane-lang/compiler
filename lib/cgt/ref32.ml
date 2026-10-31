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
(* Experimental: with `ZANE_BUMP_REGIONS=1`, emitted code takes a box's
   block, or an empty list's first block, at the innermost region's frontier
   alone: it never pops a block a value returned early, and keeps no count
   of the blocks out, so a block's only cost is the frontier's load and
   store. A returned block waits for its scope to drain. *)
(* Experimental: with `ZANE_NICHE_SUMS=1` as well as `ZANE_REF32=1`, a sum
   whose first case carries nothing and whose second is a 4-byte reference
   is that reference alone, 0 for the first case: a stored reference is
   never 0 in the cage. *)
let niche () = Sys.getenv_opt "ZANE_NICHE_SUMS" = Some "1" && on ()

let bump () = Sys.getenv_opt "ZANE_BUMP_REGIONS" = Some "1"

let frames () = Sys.getenv_opt "ZANE_FRAME_REFS" = Some "1" && not (on ())
