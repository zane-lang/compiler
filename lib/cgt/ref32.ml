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

(* Experimental: with `ZANE_IMAGE_BOXES=1` as well as `ZANE_FRAME_REFS=1`,
   the runtime takes its chunks from a window within 16 GiB of the
   program's image (runtime/region.c), so a boxed member's block is stored
   as its signed distance from the image in 8-byte units, in 32 bits
   ([Nodes.Ty.Box32]). With `ZANE_CHUNK_BOXES=1` instead, the box is the
   same 32 bits and only its encoding differs ([chunk_boxes]). *)
let image_boxes () =
  (Sys.getenv_opt "ZANE_IMAGE_BOXES" = Some "1" || Sys.getenv_opt "ZANE_CHUNK_BOXES" = Some "1") && frames ()

(* Experimental: with `ZANE_CHUNK_BOXES=1` as well as `ZANE_FRAME_REFS=1`,
   a boxed member's block is stored in 32 bits as its MiB's number, which
   the runtime gives each MiB of a context's frames and of a chunk, and its
   offset in that MiB in 8-byte units (runtime/arena.c, zane_mib_bases):
   the same 32-bit box as image boxes, with chunks anywhere. *)
let chunk_boxes () = Sys.getenv_opt "ZANE_CHUNK_BOXES" = Some "1" && frames ()

(* Experimental: with `ZANE_NICHE_SUMS=1` as well as `ZANE_REF32=1` or
   `ZANE_IMAGE_BOXES=1` or `ZANE_CHUNK_BOXES=1`, a sum whose first case carries nothing and whose
   second is a 4-byte reference or box is that word alone, 0 for the first
   case: a stored reference is never 0 in the cage, and a box never names
   the image's first byte, nor MiB number 0. *)
let niche () = Sys.getenv_opt "ZANE_NICHE_SUMS" = Some "1" && (on () || image_boxes ())

(* Experimental: with `ZANE_BUMP_REGIONS=1`, emitted code takes a box's
   block, or an empty list's first block, at the innermost region's frontier
   alone: it never pops a block a value returned early, and keeps no count
   of the blocks out, so a block's only cost is the frontier's load and
   store. A returned block waits for its scope to drain. *)
let bump () = Sys.getenv_opt "ZANE_BUMP_REGIONS" = Some "1"
