(* Experimental (docs/experiments/goose-comparison): the compact memory
   layout. Each part is on by default on a Linux target, and set to `0` in
   the environment when compiling, turns off. *)

(* A switch that is on unless set to `0`. *)
let switch name = Sys.getenv_opt name <> Some "0"

(* The target's triple, when the build names one; the host's otherwise. *)
let target : string option ref = ref None

(* Whether the target is Linux: frame references need the ELF linker's
   `__ehdr_start` and Linux's `MAP_FIXED_NOREPLACE` (runtime/region.c). *)
let linux () =
  match !target with
  | Some triple ->
      let n = String.length triple in
      let rec at i = i + 5 <= n && (String.sub triple i 5 = "linux" || at (i + 1)) in
      at 0
  | None -> Sys.file_exists "/proc/sys/kernel/ostype"

(* `ZANE_FRAME_REFS`: every context's frames are in the 2 GiB right below
   the program's image (runtime/region.c), so a stored reference, which
   names a frame's slot or a global, is its signed 32-bit distance from the
   image's start; and a list's handle is 16 bytes, its count and room 32
   bits each, the room counted in elements. *)
let frames () = linux () && switch "ZANE_FRAME_REFS"

(* `ZANE_CHUNK_BOXES=1`, off by default: a boxed member's block is stored
   in 32 bits as its MiB's number, which the runtime gives each MiB of a
   context's frames and of a chunk, and its offset in that MiB in 8-byte
   units (runtime/arena.c, zane_mib_bases), with chunks anywhere. *)
let chunk_boxes () = frames () && Sys.getenv_opt "ZANE_CHUNK_BOXES" = Some "1"

(* `ZANE_IMAGE_BOXES`, with frame references: the runtime takes its chunks
   from a window within 16 GiB of the program's image (runtime/region.c),
   so a boxed member's block is stored as its signed distance from the
   image in 8-byte units, in 32 bits ([Nodes.Ty.Box32]). Chunk boxes store
   the same 32 bits, encoded their own way. *)
let image_boxes () = frames () && (switch "ZANE_IMAGE_BOXES" || chunk_boxes ())

(* `ZANE_NICHE_SUMS`, with 32-bit boxes: a sum whose first case carries
   nothing and whose second is a box or a reference is that word alone, 0
   for the first case: a box never names the image's first byte, nor MiB
   number 0, and a reference never names the image's first byte. *)
let niche () = image_boxes () && switch "ZANE_NICHE_SUMS"

(* Experimental: with `ZANE_BUMP_REGIONS=1`, emitted code takes a box's
   block, or an empty list's first block, at the innermost region's frontier
   alone: it never pops a block a value returned early, and keeps no count
   of the blocks out, so a block's only cost is the frontier's load and
   store. A returned block waits for its scope to drain. *)
let bump () = Sys.getenv_opt "ZANE_BUMP_REGIONS" = Some "1"
