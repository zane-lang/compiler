(* Experimental (docs/experiments/goose-comparison): the compact memory
   layout. Each part is on by default, on every target, and turns off when
   its variable is set to `0` in the environment while compiling. *)

(* A switch that is on unless set to `0`. *)
let switch name = Sys.getenv_opt name <> Some "0"

(* The target's triple, when the build names one; the host's otherwise. *)
let target : string option ref = ref None

(* Whether [triple] names any of [words]. *)
let names triple words =
  let n = String.length triple in
  let has w =
    let k = String.length w in
    let rec at i = i + k <= n && (String.sub triple i k = w || at (i + 1)) in
    at 0
  in
  List.exists has words

(* The kind of image the target's linker writes: a PE image on Windows, a
   Mach-O image on Apple's systems, an ELF image elsewhere. *)
type image = Pe | Mach_o | Elf

(* The host's kind, looked up once: lowering asks for the image's kind for
   every box and sum, and the host does not change while it runs. macOS is
   recognized by its version file, as [Codegen.Build.darwin] recognizes
   it, so any other Unix host, a Linux one without `/proc` included, is
   ELF. *)
let host_image =
  lazy
    (if Sys.win32 then Pe
     else if Sys.file_exists "/System/Library/CoreServices/SystemVersion.plist" then Mach_o
     else Elf)

let image () =
  let windows = [ "windows"; "mingw"; "win32"; "msvc" ] and apple = [ "apple"; "darwin"; "macos" ] in
  match !target with
  | Some triple when names triple windows -> Pe
  | Some triple when names triple apple -> Mach_o
  | Some _ -> Elf
  | None -> Lazy.force host_image

(* Whether the build is a plugin package's dynamic library (packages.md
   §8.1). A host loads several into one process, each a runtime of its own,
   and each would reserve the addresses near its own image that frame
   references and image boxes need, so the second could find none: a
   dynamic library takes none of the parts below that place memory near
   the image, and its frames and chunks lie anywhere. *)
let library = ref false

(* The symbol the target's linker defines at the program image's start,
   which a frame reference counts from (runtime/region.c): the PE image's
   base on Windows, the Mach-O header on macOS (LLVM adds its `_`), the ELF
   header elsewhere. *)
let image_symbol () =
  match image () with Pe -> "__ImageBase" | Mach_o -> "_mh_execute_header" | Elf -> "__ehdr_start"

(* `ZANE_FRAME_REFS`: every context's frames are in the 2 GiB right below
   the program's image (runtime/region.c), so a stored reference, which
   names a frame's slot or a global, is its signed 32-bit distance from the
   image's start; and a list's handle is 16 bytes, its count and room 32
   bits each, the room counted in elements. *)
let frames () = switch "ZANE_FRAME_REFS" && not !library

(* `ZANE_CHUNK_BOXES`: a boxed member's block is stored in 32 bits as its
   MiB's number, which the runtime gives each MiB of a context's frames and
   of a chunk, and its offset in that MiB in 8-byte units (runtime/arena.c,
   zane_mib_bases), with chunks anywhere. It is on by default for a Mach-O
   target, since image boxes need a window that arm64 macOS has no room
   for: the system loads the image at 4 GiB and keeps the addresses below
   it unmapped, and the dyld shared cache, with the range the system
   reserves after it, fills the addresses from 6 GiB to 63 GiB (#418).
   Chunk boxes need frame references, so `ZANE_FRAME_REFS=0` turns them
   off. Otherwise `ZANE_CHUNK_BOXES=1` turns them on for every target,
   whatever `ZANE_IMAGE_BOXES` is, and `ZANE_CHUNK_BOXES=0` turns them off, which on
   a Mach-O target brings image boxes back. With any other value, or
   unset, a Mach-O target takes chunk boxes unless `ZANE_IMAGE_BOXES` is
   `0`, which leaves boxes 8 bytes, and other targets do not. *)
let chunk_boxes () =
  frames ()
  &&
  match Sys.getenv_opt "ZANE_CHUNK_BOXES" with
  | Some "1" -> true
  | Some "0" -> false
  | Some _ | None -> image () = Mach_o && switch "ZANE_IMAGE_BOXES"

(* `ZANE_IMAGE_BOXES`, with frame references: the runtime takes its chunks
   from a window within 16 GiB of the program's image (runtime/region.c),
   so a boxed member's block is stored as its signed distance from the
   image in 8-byte units, in 32 bits ([Nodes.Ty.Box32]). Chunk boxes also
   store 32 bits, with their own encoding, and take the place of image
   boxes when they are on. *)
let image_boxes () = frames () && (switch "ZANE_IMAGE_BOXES" || chunk_boxes ())

(* `ZANE_NICHE_SUMS`, with 32-bit boxes: a sum whose first case carries
   nothing and whose second case is a box or a reference is laid out as that
   word alone, with 0 for the first case: a box never names the image's first
   byte, nor MiB number 0, and a reference never names the image's first
   byte. *)
let niche () = image_boxes () && switch "ZANE_NICHE_SUMS"

(* Experimental: with `ZANE_BUMP_REGIONS=1`, emitted code takes a box's
   block, or an empty list's first block, only at the innermost region's
   frontier: it never pops a block that a value returned early, and keeps no
   count of the blocks handed out, so a block's only cost is the frontier's
   load and store. A returned block waits for its scope to drain. *)
let bump () = Sys.getenv_opt "ZANE_BUMP_REGIONS" = Some "1"
