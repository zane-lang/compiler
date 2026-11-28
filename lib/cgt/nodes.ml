(* The code-generation tree (docs/design/lowering.md): the one input codegen reads.

   The tree describes the machine's operations. A call names one function,
   every type has a layout, and no node needs a declaration or an overload to
   be understood. The tree grows with each step of docs/design/lowering.md §8;
   the nodes here are those that lowering handles so far. *)

(* A CGT type is a machine layout (L5). [Handle] is `@primitives$String`
   (types.md §2.7), `@primitives$List<T>`, `@primitives$ListRef<T>` and `@primitives$ByteSet`, laid out as a list of bytes: a handle (memory.md §3.6), a
   pointer to the first byte or element, the length in bytes or elements,
   with no terminator, and the room in bytes of the block they are in, which
   is 0 when the handle owns no block: a literal's bytes belong to the module.
   [Void] is `Unit`, which has no storage. [Array] is
   `@primitives$Array<T, n>`: [n] elements inline, each at the element's
   stride, its size rounded up to its alignment (L5).
   [Struct] is a struct's members in the order [order] places them, [Sum] a variant's or
   enum's cases: a tag and room for the widest payload. [Ptr] is the address
   of a place, which is how a `mut` subject and a borrow are passed (L6),
   and what a reference holds: the address of the settled owner it names
   (memory.md §4.1). [I32] is `@primitives$I32`, [I64] `I64`, [F32] `F32`
   and [F64] `F64`. A boxed member is a [Ptr]
   to its payload's block (adt.md §4). [Packed] is a [Struct] or a [Sum]
   with no padding and alignment 1, a sum's tag one byte and its payload
   right after it: the experimental packed node of a pooled variant
   (docs/experiments/goose-comparison). Its members keep their own
   layouts. *)
module Ty = struct
  type t =
    | Void
    | I1
    (* `@primitives$U8`, the byte primitive (spec syntax.md §2.7), an
       unsigned byte, widened by zero-extension. *)
    | I8
    | I32
    | I64
    | F32
    | F64
    | Handle
    (* Experimental (frame references): a list's handle with its items a
       pointer, and its count and its room in 32 bits each. *)
    | Handle16
    | Ptr
    (* Experimental (Ref32.frames): a reference, stored as its signed
       distance from the program's image in 32 bits, which a [Convert]
       turns into a [Ptr] and back. *)
    | Ref
    (* Experimental (Ref32.image_boxes): a boxed member's block, stored as its
       signed distance from the program's image in 8-byte units, in 32 bits,
       0 for none; a [Convert] turns it into a [Ptr] and back. *)
    | Box32
    | Struct of t list
    | Sum of t list
    | Array of t * int
    | Packed of t

  (* A value's spare byte ([spare]) and a sum's byte niche ([byte_niche]). *)
  type spare = { path : int list option; at : int; first : int; free : int }
  type byte_niche = { case : int; path : int list option; at : int; first : int; count : int; free : int }

  (* No type takes [limit] bytes or more: no such value can be placed, since
     the runtime's chunk map covers 48-bit addresses
     (docs/design/platforms.md, "Address range supported by the runtime").
     A size is built up by [add] and [times], which check each step against
     the limit before taking it, so none can overflow on the way, and raise
     [Too_large] when a step would pass the limit. *)
  let limit = 1 lsl 48

  exception Too_large

  let add a b = if a > limit - b then raise Too_large else a + b
  let times stride n = if n < 0 || (stride > 0 && n > limit / stride) then raise Too_large else stride * n
  let round_up size align = add size (align - 1) / align * align

  let below_limit size = if size >= limit then raise Too_large else size

  (* The limit below which a byte niche's spare byte offset must lie, since
     a layout's tag holds that offset in 24 bits (Layout.byte_niche_tag). *)
  let max_niche_at = 1 lsl 24

  (* Each sum's byte niche, found once, keyed by whether niches are on and
     by the sum's cases. *)
  let byte_niches : (bool * t list, byte_niche option) Hashtbl.t = Hashtbl.create 64

  (* Size and alignment in bytes on a 64-bit target. A bare [Struct] is laid
     out as C lays it out, and a bare [Sum] is its tag and then its payload
     room at offset 8, the form a runtime record such as an outcome keeps;
     lowering gives a value's type through [tight], which keeps a [Struct]
     only when it has no padding and a [Sum] only as a niche or byte niche,
     and packs the rest (docs/design/lowering.md L5). [Too_large] when the
     type takes [limit] bytes or more. *)
  let rec size_align = function
    | Void -> (0, 1)
    | I1 | I8 -> (1, 1)
    | I32 | F32 -> (4, 4)
    | I64 | F64 | Ptr -> (8, 8)
    | Handle -> (24, 8)
    | Handle16 -> (16, 8)
    | Ref | Box32 -> (4, 4)
    | Struct ts ->
        let size, align =
          List.fold_left
            (fun (size, align) t ->
              let s, a = size_align t in
              (below_limit (add (round_up size a) s), max align a))
            (0, 1) ts
        in
        (below_limit (round_up size align), align)
    | Sum ts when Option.is_some (byte_niche ts) -> (
        match byte_niche ts with Some { case; _ } -> size_align (List.nth ts case) | None -> (0, 1))
    | Sum ts when niche ts -> (4, 4)
    | Sum ts -> ( match words ts with 0 -> (4, 4) | n -> (below_limit (add 8 (times 8 n)), 8))
    | Array (t, n) ->
        let size, align = size_align t in
        (below_limit (times (round_up size align) n), align)
    | Packed (Struct ts) -> (List.fold_left (fun size t -> below_limit (add size (fst (size_align t)))) 0 ts, 1)
    | Packed (Sum ts) -> (below_limit (add 1 (room ts)), 1)
    | Packed t -> size_align t

  (* A packed sum's payload room in bytes: the size of its widest case. *)
  and room ts = List.fold_left (fun n t -> max n (fst (size_align t))) 0 ts

  (* A sum's payload room, in 8-byte words: enough for its widest case, and
     aligned for every case, since no layout here needs an alignment above
     8. *)
  and words ts = List.fold_left (fun n t -> max n ((fst (size_align t) + 7) / 8)) 0 ts

  (* Experimental (Ref32.niche): a sum of either no value or a box or
     reference is laid out as that one word, with 0 for no value. *)
  and niche ts = Ref32.niche () && (ts = [ Void; Ref ] || ts = [ Void; Box32 ])

  (* A sum of one case with a payload and other cases with none, whose
     payload has a byte with an unused value (a [spare] byte) for each of
     the other cases, is laid out as the payload's bytes alone. Each other
     case is one of those unused values at that byte: the first unused value
     for the first such case, and so on. *)
  and byte_niche ts =
    let key = (Ref32.niche (), ts) in
    match Hashtbl.find_opt byte_niches key with
    | Some n -> n
    | None ->
        let n = find_byte_niche ts in
        Hashtbl.replace byte_niches key n;
        n

  (* Found once for each sum (byte_niches): a sum nested in a member would
     otherwise be asked again for each layer above it, doubling the work at
     each layer. A spare byte beyond the offset [Layout.byte_niche_tag] can
     hold is not used. *)
  and find_byte_niche ts =
    if List.length ts < 2 then None
    else
      match List.filter (fun (_, t) -> t <> Void) (List.mapi (fun i t -> (i, t)) ts) with
      | [ (case, t) ] -> (
          let count = List.length ts - 1 in
          match spare t with
          | Some s when s.free >= count && s.at < max_niche_at ->
              Some { case; path = s.path; at = s.at; first = s.first; count; free = s.free }
          | _ -> None)
      | _ -> None

  (* A byte of a value of [t] that some values never occupy: at [at], where
     [free] values from [first] up are unused. A [Bool] holds 0 or 1, a
     packed sum's tag holds one value for each case, and a sum with a byte
     niche leaves free the values its own cases do not take. [path] leads
     through members and elements to the [Bool] that owns the byte, which a
     niche sum's own layout holds as a byte (Emit.lltype); [path] is empty
     for a tag. *)
  and spare t : spare option =
    let inside base i (s : spare) : spare = { s with at = base + s.at; path = Option.map (fun p -> i :: p) s.path } in
    match t with
    | I1 -> Some { path = Some []; at = 0; first = 2; free = 254 }
    | Struct ts | Packed (Struct ts) ->
        let packed = match t with Packed _ -> true | _ -> false in
        let rec go i at = function
          | [] -> None
          | m :: rest -> (
              let s, a = size_align m in
              let at = if packed then at else round_up at a in
              match spare m with Some sp -> Some (inside at i sp) | None -> go (i + 1) (at + s) rest)
        in
        go 0 0 ts
    | Array (e, n) when n > 0 -> Option.map (inside 0 0) (spare e)
    | Packed (Sum ts) when List.length ts < 256 ->
        Some { path = None; at = 0; first = List.length ts; free = 256 - List.length ts }
    | Sum ts -> (
        match byte_niche ts with
        | Some n when n.first + n.count < 256 -> Some { path = None; at = n.at; first = n.first + n.count; free = n.free - n.count }
        | _ -> None)
    | _ -> None

  (* Where a struct's members go, given their types in declaration order:
     the [i]th declared member is the [(order ts).(i)]th member of the
     struct's layout. Members are placed in decreasing order of alignment,
     those of one alignment in declaration order. Every layout's size is a
     multiple of its alignment, so no padding falls between members: only
     the tail is rounded up (docs/design/lowering.md L5). The order depends
     only on the member types, so every object that lays out a type lays it
     out the same way, and the order is the identity when the members are
     already sorted. *)
  let order ts =
    (* A member past the limit makes its struct a type that no value can
       have, which is refused where the type is named (Type_layout.ty), so
       the order the member gets until then does not matter; 8 is the
       largest alignment any layout here needs. *)
    let alignment t = match size_align t with _, a -> a | exception Too_large -> 8 in
    let indexed = List.mapi (fun i t -> (i, alignment t)) ts in
    let sorted = List.stable_sort (fun (_, a) (_, b) -> compare b a) indexed in
    let positions = Array.make (List.length ts) 0 in
    List.iteri (fun at (i, _) -> positions.(i) <- at) sorted;
    positions

  (* The layout lowering gives a struct or sum of already-laid-out members
     (docs/design/lowering.md L5). A struct that C's layout would pad is
     packed: no padding, its tail included, and alignment 1; a struct with
     no padding keeps its natural layout and alignment. A sum with a niche or
     a byte niche is laid out as that niche; any other sum of at most 256
     cases is packed, its tag one byte and its payload room right after it,
     and a sum of more cases keeps the 4-byte tag of a bare [Sum]. A type too
     large to measure is left for the size check to refuse. *)
  let tight t =
    match t with
    | Struct _ when (try fst (size_align (Packed t)) < fst (size_align t) with Too_large -> false) -> Packed t
    | Sum ts when List.length ts <= 256 && not (niche ts) && (try Option.is_none (byte_niche ts) with Too_large -> false) ->
        Packed t
    | t -> t

  (* [xs], given one for each of the members [ts] in declaration order,
     reordered into the layout's order. *)
  let placed ts xs =
    let positions = order ts in
    let out = Array.make (List.length xs) None in
    List.iteri (fun i x -> out.(positions.(i)) <- Some x) xs;
    List.map Option.get (Array.to_list out)

  (* Whether [order ts] moves any member. *)
  let reordered ts =
    let positions = order ts in
    let moved = ref false in
    Array.iteri (fun i at -> if i <> at then moved := true) positions;
    !moved

  (* Where each member of a struct of [ts] starts. *)
  let offsets ts =
    let _, offsets =
      List.fold_left
        (fun (at, acc) t ->
          let s, a = size_align t in
          let start = (at + a - 1) / a * a in
          (start + s, start :: acc))
        (0, []) ts
    in
    List.rev offsets

  (* Where each member of a packed struct of [ts] starts. *)
  let packed_offsets ts =
    List.rev (snd (List.fold_left (fun (at, acc) t -> (at + fst (size_align t), at :: acc)) (0, []) ts))

  (* Where each member of the struct [t], packed or not, starts. *)
  let member_offsets = function
    | Struct ts -> offsets ts
    | Packed (Struct ts) -> packed_offsets ts
    | _ -> []

  (* A struct's members, packed or not. *)
  let members = function Struct ts | Packed (Struct ts) -> ts | _ -> []

  (* A bare [Sum]'s payload starts after its tag (see [size_align]); a
     value's sum keeps its payload at [payload_at]. *)
  let payload_offset = 8

  (* A list's handle: [Handle16] with frame references, else [Handle]. *)
  let list_handle () = if Ref32.frames () then Handle16 else Handle

  (* Where the sum [t]'s payload starts, packed or not. *)
  let payload_at = function
    | Packed _ -> 1
    | Sum ts when niche ts || Option.is_some (byte_niche ts) -> 0
    | _ -> payload_offset

  (* Whether a value of the type has a handle among its bytes: the value is a
     handle, or has a handle as a member, a case's payload or an element. A
     boxed member's payload and a reference's owner are in storage of their
     own, which a [Ptr] names. *)
  let rec holds_handle = function
    | Handle | Handle16 -> true
    | Struct ts | Sum ts -> List.exists holds_handle ts
    | Array (t, _) | Packed t -> holds_handle t
    | Void | I1 | I8 | I32 | I64 | F32 | F64 | Ptr | Ref | Box32 -> false

  let rec to_string = function
    | Void -> "void"
    | I1 -> "i1"
    | I8 -> "i8"
    | I32 -> "i32"
    | I64 -> "i64"
    | F32 -> "f32"
    | F64 -> "f64"
    | Handle -> "handle"
    | Handle16 -> "handle16"
    | Ptr -> "ptr"
    | Ref -> "ref"
    | Box32 -> "box32"
    | Struct ts -> "{" ^ String.concat ", " (List.map to_string ts) ^ "}"
    | Sum ts -> "<" ^ String.concat " | " (List.map to_string ts) ^ ">"
    | Array (t, n) -> Printf.sprintf "[%d x %s]" n (to_string t)
    | Packed t -> "packed " ^ to_string t
end

(* The semantics of a scalar conversion (types.md §2.9), which the optimizer
   uses to fold conversions and which codegen's `llvm.fptosi.sat` matches for
   a truncation. A float is held as a double either way; an [F32] is a double
   that [single] has rounded. *)
module Scalar = struct
  let single f = Int32.float_of_bits (Int32.bits_of_float f)

  (* The bits of an integer type. *)
  let bits = function Ty.I8 -> 8 | Ty.I32 -> 32 | _ -> 64

  (* The floats of type [from] that truncate toward zero into the integer
     type [t]: those above [lower], or at it when [inclusive], and below
     [upper]. Each bound is exact in [from]. The first float below -2^31
     that truncates out of an [I32] is -2^31 - 1 when a double holds it;
     an [F32] holds nothing between -2^31 and the next float below, and
     neither holds anything between -2^63 and the next below it. *)
  let truncation ~from t =
    let half = Float.pow 2. (float_of_int (bits t - 1)) in
    if bits t = 32 && from = Ty.F64 then (Float.neg half -. 1., false, half)
    else (Float.neg half, true, half)

  (* The least and the greatest value of the integer type [t]. *)
  let ends t =
    if bits t = 32 then (Int64.of_int32 Int32.min_int, Int64.of_int32 Int32.max_int)
    else (Int64.min_int, Int64.max_int)

  let truncates_into ~from t f =
    let lower, inclusive, upper = truncation ~from t in
    (if inclusive then f >= lower else f > lower) && f < upper

  (* An integer to the nearest float of [t], rounded once. A double holds
     every [I64] up to 2^53 exactly; above that, an integer is first rounded
     to odd, which keeps a later rounding to an [F32] from rounding
     twice. *)
  let to_float t (i : int64) =
    match t with
    | Ty.F32 ->
        let limit = Int64.shift_left 1L 53 in
        if Int64.compare i (Int64.neg limit) > 0 && Int64.compare i limit < 0 then
          single (Int64.to_float i)
        else if Int64.equal i Int64.min_int then single (Int64.to_float i)
        else
          let m = Int64.abs i in
          let kept = Int64.logand m (Int64.lognot 0x7FFL) in
          let odd = if Int64.equal kept m then kept else Int64.logor kept 0x800L in
          let f = single (Int64.to_float odd) in
          if Int64.compare i 0L < 0 then Float.neg f else f
    | _ -> Int64.to_float i
end

(* Where a type's owned blocks are (memory.md §3.6): every handle and boxed
   member, outermost first, each of which may own a dynamic block. A list's block holds elements laid out as
   [elements] says, [stride] bytes apart, and a box's holds one payload of
   [size] bytes laid out as [payload] says. A position inside a variant
   payload is there only while each of [tags] -- a tag's offset and the case
   it must hold -- is live. A layout is named by the type it describes, and
   the program lists each one once, so a layout may name itself. *)
module Layout = struct
  type kind =
    | Text
    | List of { stride : int; elements : string }
    (* An array's [count] elements inline, [stride] bytes apart from the
       position's offset: one position for all the elements, however many
       there are. *)
    | Array of { count : int; stride : int; elements : string }
    | Box of { size : int; payload : string }
    (* A foreign handle that owns its C object (docs/design/ffi.md F12):
       its pointer and its stamp, ended by the free thunk [free] and, in a
       settled place, overwritten through the set thunk [set]. *)
    | Foreign of { free : string; set : string option }

  type position = { kind : kind; offset : int; size : int; tags : (int * int) list }
  type t = string

  (* Experimental (Ty.niche): the tag a position under a niche sum's case
     [i] names, which a walk tests as a nonzero word, and the case a tag
     names either way. *)
  let niche_tag i = -i - 1

  (* The tag a position under a packed sum's case [i] names, which a walk
     tests as the byte at the sum's start; a bare sum's case [i] is [i]
     itself, tested as a 4-byte word. *)
  let packed_base = 1 lsl 48

  let packed_tag i = packed_base + i
  let packed_case t = if t >= packed_base then Some (t - packed_base) else None

  (* The tag a position under a byte-niche sum's case [case] names, which
     a walk tests as the byte at [at] past the sum holding none of the
     [count] values from [first] up. [at] is below Ty.max_niche_at. *)
  let byte_niche_base = 1 lsl 50

  let byte_niche_tag ~case ~at ~first ~count =
    -byte_niche_base - ((case lsl 40) lor (at lsl 16) lor (first lsl 8) lor count)

  let byte_niche t =
    if t > -byte_niche_base then None
    else
      let v = -t - byte_niche_base in
      Some (v lsr 40, (v lsr 16) land 0xffffff, (v lsr 8) land 0xff, v land 0xff)

  let tag_case t =
    match (byte_niche t, packed_case t) with
    | Some (case, _, _, _), _ -> case
    | None, Some case -> case
    | None, None -> if t < 0 then -t - 1 else t
  (* Whether a value of layout [l], whose positions [find] gives, holds a
     foreign handle: anywhere, or, with [settled], only where a settled
     overwrite replaces the handle through its setter, which is in no
     variant's payload and in no list (spec ffi.md §4.3). *)
  let holds_handle ?(settled = false) find l =
    let seen = Hashtbl.create 8 in
    let rec go l =
      (not (Hashtbl.mem seen l))
      &&
      (Hashtbl.replace seen l ();
       List.exists
         (fun p ->
           ((not settled) || p.tags = [])
           &&
           match p.kind with
           | Foreign _ -> true
           | Box { payload = l; _ } | Array { elements = l; _ } -> go l
           | List { elements = l; _ } -> (not settled) && go l
           | Text -> false)
         (Option.value ~default:[] (find l)))
    in
    go l
end

module Expr = struct
  (* A spawned call's subject that owns blocks goes into a region of its
     own before the call starts (runtime/spawn.c, docs/design/lowering.md
     §9). The frame's member [field] holds the subject's address, through
     which the call reads the subject; when the subject is copied into the
     frame, the copy is member [copy], and [field] is first set to point at
     the copy. *)
  type island = { field : int; copy : int option; size : int; value_layout : Layout.t }

  type t = { node : node; ty : Ty.t }

  and node =
    | Int of int64
    | Float of float
    | Bool of bool
    (* A view over constant bytes: a string literal the program embeds. *)
    | Text of string
    | Unit
    | Local of int
    (* The address of a local's slot, and the value at an address. *)
    | Address of int
    | Deref of t
    (* A call to a function of the program, by its symbol (L6). *)
    | Call of { fn : string; args : t list }
    (* A call through a function value: [fn] is the function's address, run
       before [args] (L14). *)
    | Call_value of { fn : t; args : t list }
    (* A call into the C runtime (L17), by the runtime's symbol. A string
       is passed to the runtime, and returned from it, through the address
       of a copy. *)
    | Runtime of { fn : Runtime.fn; args : t list }
    (* A call of a foreign verb's C function through the thunk the glue
       gives it (docs/design/ffi.md F8, F10): each argument, run in the
       order listed, is laid out as C lays out its type in a slot of its
       own, its padding bytes zeroed, and the thunk is handed the slots'
       addresses and the address of a zeroed slot for the result. A
       [Bool] goes as a byte that is 0 or 1. *)
    | Foreign_call of { thunk : string; args : t list }
    (* A math function of `@math$` (math.md §2) on operands of the node's
       type, run in the order listed. *)
    | Math of { fn : Math.fn; args : t list }
    (* An `@operators$` operation on two operands of one type: an integer or
       a float adds, multiplies, divides and compares; an [I1] adds as `or`,
       multiplies as `and` and compares. *)
    | Binary of { op : binop; left : t; right : t }
    (* An integer or a float negated, an [I1] inverted. *)
    | Flip of t
    (* A scalar converted to the node's type, the instruction picked by the
       two types (types.md §2.9): an integer widened by its sign or wrapped
       to its low bits, a float widened or rounded, an integer rounded to the
       nearest float, and a float truncated toward zero to an integer, which
       saturates when the result does not fit and gives zero for a NaN. *)
    | Convert of t
    (* A verb expanded where it is called (L11): its body runs here, and a
       `return` in it stores [result] and leaves [label]. The expression's
       value is [result] once the body is left. *)
    | Expand of { label : int; body : stat list; result : int option }
    (* A struct built from its members, each given with its index and run in
       the order listed, which is the order they were written. *)
    | Record of (int * t) list
    | Member of { value : t; index : int }
    (* A sum with case [index] live, and the payload of case [index], read
       when that case is live. *)
    | Case of { index : int; payload : t }
    | Payload of { value : t; index : int }
    (* The address of a member inside the place an address names, down
       [path] through the struct type [within]. *)
    | Offset of { base : t; within : Ty.t; path : int list }
    (* A move out of the place an address names: the place's value, after
       which the place is spent (lifetimes.md §1.6). *)
    | Take of { address : t; layout : Layout.t }
    (* A value copied whole: every block it owns is copied too, so the copy
       owns blocks of its own (memory.md §2.3). *)
    | Copy of { value : t; layout : Layout.t }
    (* A boxed member's payload placed in a block of its own, and the address
       of the block (memory.md §3.6). *)
    | Box of { value : t; layout : Layout.t }
    (* A layout's table, for the runtime to read. *)
    | Layout of Layout.t
    (* The address of a function of the program, by its symbol. *)
    | Function of string
    (* The address of a variable of the program, by its symbol. *)
    | Global of string
    (* The value at an address reached through an owner, read as a coherent
       snapshot: retried while a spawned call writes back there
       (concurrency.md §4.4). *)
    | Snapshot of t
    (* A value on its way out of the arenas an exit drains: the function's,
       when [exit] is [None], or those opened inside the expansion [exit]
       names. Every block the value owns in those arenas first moves into
       the arena the exit returns to (memory.md §3.1, §3.5). *)
    | Escape of { value : t; layout : Layout.t; exit : int option }

  and binop = Add | Mul | Div | Eq | Less

  (* Where an assignment stores: a local's slot, or the place the address in
     it names, then a member path through the struct of type [ty]. *)
  and place = { local : int; deref : bool; ty : Ty.t; path : int list }

  (* A local is a slot the function owns (L3): [Let] fills a new one,
     [Assign] a place in an existing one, and [Expr.Local] reads it. [If] and
     [Repeat] are `@controlflow$branch` and `@controlflow$repeat`, [While]
     `@controlflow$work` and `@controlflow$register`, [Switch]
     jumps on a sum's tag (L13), and [Leave] ends the [Expand] its label
     names. [Scope] is a block's arena (L8), entered before its body and
     drained on every way out of it, and [Hold] fills a new local whose slot
     is in that arena. *)
  and stat =
    | Let of { id : int; value : t }
    | Hold of { id : int; scope : int; value : t; layout : Layout.t }
    | Scope of { id : int; body : stat list }
    | Assign of { place : place; value : t }
    | Eval of t
    | Return of t
    | If of { cond : t; body : stat list }
    | Repeat of { count : t; body : stat list }
    (* A worker (control-flow.md §3.7): [cond] is read, and [body] runs
       each time [cond] is true: [cond] calls the step, and [body] runs
       between one step and the next. No counter limits the loop, so it
       ends only when [cond] is false, or when a [Leave] or a [Return] in
       [body] leaves it. *)
    | While of { cond : t; body : stat list }
    | Switch of { value : t; cases : (int * stat list) list }
    | Leave of int
    (* A store through an address, and a value replaced there in place
       (memory.md §2.2): written at the occupant's address, with each boxed
       member's block kept, the other blocks the old value owned returned,
       and the new value's blocks arriving in the place's region. *)
    | Store of { address : t; value : t }
    (* With [setters], the place is settled or lent (memory.md §2.2) and
       the value holds a foreign handle that is no variant's payload nor a
       list's element: each such handle is replaced through its setter,
       keeping its object's address (spec ffi.md §4.3). Without [setters],
       the handle ends as everything else the old value owns does. *)
    | Overwrite of { address : t; value : t; layout : Layout.t; setters : bool }
    (* A value moved into a fresh place at an address: the value is stored,
       and the blocks it owns that the place's region outlives move into that
       region, which is an escape (memory.md §3.5). *)
    | Place of { address : t; value : t; layout : Layout.t }
    (* A slot of type [ty] in a scope's arena, zeroed so that it holds
       nothing until a [Place] fills it, which the drain then ends. *)
    | Reserve of { id : int; scope : int; ty : Ty.t; layout : Layout.t }
    (* A spawned call (concurrency.md §3). [args] run here, in the order they
       were written, and are stored in a frame of type [frame] in a scope's
       arena, whose first member is room for the result; then the function
       [thunk] runs on a thread of the pool, reads the arguments, and makes
       the call. The result is copied back to the slot [dest], of that first
       member's type and laid out as [layout] describes, when the call is
       joined: at a read, or when the scope drains, which first waits for the
       call (§4.1). [task] holds the frame's address. *)
    | Spawn of {
        task : int;
        scope : int;
        thunk : string;
        frame : Ty.t;
        args : t list;
        dest : int option;
        layout : Layout.t;
        island : island option;
      }
    (* Waiting for the call [task] names, whose result is then copied
       back. *)
    | Join of int

  (* A node's constructor, for a message about the node. *)
  let kind = function
    | Int _ -> "Int"
    | Float _ -> "Float"
    | Bool _ -> "Bool"
    | Text _ -> "Text"
    | Unit -> "Unit"
    | Local _ -> "Local"
    | Address _ -> "Address"
    | Deref _ -> "Deref"
    | Call _ -> "Call"
    | Call_value _ -> "Call_value"
    | Runtime _ -> "Runtime"
    | Foreign_call _ -> "Foreign_call"
    | Math _ -> "Math"
    | Binary _ -> "Binary"
    | Flip _ -> "Flip"
    | Convert _ -> "Convert"
    | Expand _ -> "Expand"
    | Record _ -> "Record"
    | Member _ -> "Member"
    | Case _ -> "Case"
    | Payload _ -> "Payload"
    | Offset _ -> "Offset"
    | Take _ -> "Take"
    | Copy _ -> "Copy"
    | Box _ -> "Box"
    | Layout _ -> "Layout"
    | Function _ -> "Function"
    | Global _ -> "Global"
    | Snapshot _ -> "Snapshot"
    | Escape _ -> "Escape"

  let binop_to_string = function
    | Add -> "+"
    | Mul -> "*"
    | Div -> "/"
    | Eq -> "=="
    | Less -> "<"
end

module Stat = struct
  type t = Expr.stat =
    | Let of { id : int; value : Expr.t }
    | Hold of { id : int; scope : int; value : Expr.t; layout : Layout.t }
    | Scope of { id : int; body : t list }
    | Assign of { place : Expr.place; value : Expr.t }
    | Eval of Expr.t
    | Return of Expr.t
    | If of { cond : Expr.t; body : t list }
    | Repeat of { count : Expr.t; body : t list }
    | While of { cond : Expr.t; body : t list }
    | Switch of { value : Expr.t; cases : (int * t list) list }
    | Leave of int
    | Store of { address : Expr.t; value : Expr.t }
    | Overwrite of { address : Expr.t; value : Expr.t; layout : Layout.t; setters : bool }
    | Place of { address : Expr.t; value : Expr.t; layout : Layout.t }
    | Reserve of { id : int; scope : int; ty : Ty.t; layout : Layout.t }
    | Spawn of {
        task : int;
        scope : int;
        thunk : string;
        frame : Ty.t;
        args : Expr.t list;
        dest : int option;
        layout : Layout.t;
        island : Expr.island option;
      }
    | Join of int

  (* A store into a whole local. *)
  let assign id (value : Expr.t) =
    Assign { place = { local = id; deref = false; ty = value.Expr.ty; path = [] }; value }
end

(* Which objects link against a function (docs/design/separate-compilation.md):
   only its own object, every object, or every object that also makes it, with
   the linker keeping one copy, as a generic instance is (C4). An imported
   function is a stamped dependency's, defined in that dependency's objects,
   so this object declares it and has no body for it (C1). *)
module Linkage = struct
  (* [Available] retains a dependency's body for optimization, but emits no
     definition in this object. Residual calls use the dependency's object. *)
  type t = Local | Exported | Shared | Imported | Available
end

(* A variable of the program, zeroed until it is stored to: a package
   constant's value, and how far its making has got (L16). *)
(* A variable of the program's. A [per_thread] variable has a copy on each
   thread, which starts out zero on that thread. *)
module Global = struct
  type t = { symbol : string; linkage : Linkage.t; ty : Ty.t; per_thread : bool }
end

(* [values] is each local that holds a value type. No reference names such a
   local (memory.md §2.4), so its slot is reached only through the addresses
   the function itself takes of it. [places] is each [Ptr] parameter that is
   the address of a slot that outlives the call, with the type that slot
   holds: a `mut` subject or an owned value passed by address, which is a
   slot of the caller's, and an `&T`, which is a settled owner's slot
   (memory.md §4.2). The whole slot can be read anywhere in the function. *)
module Func = struct
  type t = {
    symbol : string;
    linkage : Linkage.t;
    params : (int * Ty.t) list;
    places : (int * Ty.t) list;
    ret : Ty.t;
    body : Stat.t list;
    values : int list;
  }
end

(* A thunk for the glue to define (docs/design/ffi.md F8), a foreign
   verb's or a handle type's free or set thunk: its symbol, the package
   whose C code it calls, the C function, how each argument and the
   result are passed, as [Foreign_call] lays them out, and whether a call of
   it reads or writes capability-backed state, as a method on a foreign
   capability and an outside handle's free or set thunk do: stage 5 never
   folds such a call (F17). [writes] is whether it writes that state, as a
   `mut` method on a capability and an outside handle's thunks do: a call
   marked `comptime` may make a call that only reads it
   (docs/design/comptime.md). *)
module Foreign = struct
  type crossing =
    (* A scalar of the Zane type, which C converts to its own. *)
    | Scalar of Ty.t
    | Bool
    | Unit
    (* A string's or a list's handle, whose first two words are the
       `zane_bytes` or `zane_span` C reads. *)
    | View
    (* A string's handle, which C takes as a `const char *` to a copy of
       its bytes followed by a NUL, which the thunk makes. *)
    | Terminated
    (* An array's address. *)
    | Address
    (* A C-compatible value type, in C's layout. *)
    | Value
    (* A foreign handle's pointer, the first word of its value. *)
    | Handle
    (* A function value: C takes its lambda's C entry, whose offset the
       word before the lambda's code holds (Callback). *)
    | Function

  type t = {
    thunk : string;
    package : string;
    c_function : string;
    params : crossing list;
    result : crossing;
    capability : bool;
    writes : bool;
  }
end

(* A function value whose type C can call (docs/design/ffi.md F11; spec
   ffi.md §3.6), and the C types its parameters and result are passed as,
   read from its Zane type when it is lowered: a scalar, a `Bool` as
   [Truth], `Unit` as [Nothing], and a C-compatible value type as a [Record]
   of its fields, with an array field's length. The Zane type, not the CGT
   type, determines these, since a value type of one field has its field's
   CGT type and C passes the two differently. Such a lambda's value is its
   Zane function's address, as for any lambda, and the function carries the
   offset of its C entry in the word before its code. The entry, which the
   glue defines, calls the lambda's adapter, a function of the program that
   takes the addresses of slots holding its arguments and of a slot for its
   result. [symbol] is the lambda's symbol, [here] whether this object
   defines the lambda, and so its adapter and entry, and [entry] the
   symbol of the entry. A lambda that other objects define too, as each
   object that makes a generic instance holding the lambda does, has an
   entry in each object, named after that object's package, and their
   adapters merge into one. *)
module Callback = struct
  type shape =
    | Scalar of Ty.t
    | Truth
    | Nothing
    | Record of (shape * int option) list
    (* A string or a list C passes as a `zane_bytes` or a `zane_span`,
       which the adapter copies with the layout into a value of the
       program's own before the lambda runs. *)
    | View of { layout : Layout.t; text : bool; stride : int }
    (* An array C passes as a pointer to its elements, through which the
       adapter reads [n] elements of the shape. *)
    | Elements of shape * int
    (* A data handle's C object C passes as a pointer: a borrow, or, when
       [owned], a roaming owner the lambda's parameter takes. *)
    | Object of { owned : bool }
  type t = { symbol : string; takes : shape list; gives : shape; here : bool; entry : string }

  let entry symbol = symbol ^ ".c"
  let shared_entry package symbol = Printf.sprintf "%s$entry %s" package symbol
  let adapter symbol = symbol ^ ".adapter"

  let rec spell = function
    | Scalar t -> Ty.to_string t
    | Truth -> "i1"
    | Nothing -> "void"
    | Record fs ->
        let field (f, n) = match n with Some n -> Printf.sprintf "[%d x %s]" n (spell f) | None -> spell f in
        "{" ^ String.concat ", " (List.map field fs) ^ "}"
    | View _ -> "view"
    | Elements (s, n) -> Printf.sprintf "*[%d x %s]" n (spell s)
    | Object { owned } -> if owned then "^object" else "object"

  (* A value of a C-compatible type is passed to C, and back, in C's layout:
     its fields in declaration order (docs/design/ffi.md F10). In Zane the
     fields are where Ty.order places them, a struct of one field is that
     field, and a struct of no fields is no value (docs/design/lowering.md
     L5). A struct is passed as a copy, so its fields are moved between the
     two orders as it is copied, and no struct lies in memory that both
     languages read. [zane] and [c] are the two layouts of a shape. *)
  let rec layout ~c = function
    | Scalar t -> t
    | Truth -> Ty.I1
    | Nothing -> Ty.Void
    | Record fs -> (
        match List.map (field ~c) fs with
        | [] -> Ty.Void
        | [ t ] -> t
        | ts -> if c then Ty.Struct ts else Ty.tight (Ty.Struct (Ty.placed ts ts)))
    (* A view, an array's pointer and a C object hold no struct that either
       language reorders, so both layouts are the same. *)
    | View _ | Object _ -> Ty.Ptr
    | Elements (s, n) -> Ty.Array (layout ~c s, n)

  (* Zane lays out an array of no elements as holding nothing
     (Type_layout.shape), so with alignment 1, whereas C keeps its element's
     alignment. *)
  and field ~c (s, n) =
    match n with
    | Some 0 when not c -> Ty.Array (Ty.Void, 0)
    | Some n -> Ty.Array (layout ~c s, n)
    | None -> layout ~c s

  let zane = layout ~c:false
  let c = layout ~c:true

  (* Whether the two layouts of a shape differ: some struct in it, however
     deep, has its fields out of declaration order or holds an array of no
     elements. *)
  let moved shape = zane shape <> c shape

  (* The value [v] rebuilt member by member: from its Zane layout into its
     C one when [to_c], else back. [v] is read once for each member, so [v]
     must be a local or a load. *)
  let rec rebuild ~to_c shape (v : Expr.t) : Expr.t =
    match shape with
    | _ when not (moved shape) -> v
    | Record [ (s, None) ] -> rebuild ~to_c s v
    | Record [ (_, Some _) ] -> { Expr.node = Expr.Record []; ty = layout ~c:to_c shape }
    | Record fs ->
        let zs = List.map (field ~c:false) fs and cs = List.map (field ~c:true) fs in
        let positions = Ty.order zs and zs' = Array.of_list zs and cs' = Array.of_list cs in
        let member j (s, n) =
          let from, into, ty = if to_c then (positions.(j), j, zs'.(j)) else (j, positions.(j), cs'.(j)) in
          let read = { Expr.node = Expr.Member { value = v; index = from }; ty } in
          (* An array of no elements holds nothing, and its two layouts
             are of different types, so the other side's array is made
             empty. *)
          let into_ty = if to_c then cs'.(j) else zs'.(j) in
          match n with
          | None -> (into, rebuild ~to_c s read)
          | Some 0 -> (into, { Expr.node = Expr.Record []; ty = into_ty })
          | Some _ -> (into, read)
        in
        { Expr.node = Expr.Record (List.mapi member fs); ty = (if to_c then Ty.Struct cs else Ty.tight (Ty.Struct (Ty.placed zs zs))) }
    | _ -> v

  let to_c = rebuild ~to_c:true
  let of_c = rebuild ~to_c:false
end

(* One program is one module (L15). [entry] is the symbol of the function
   the runtime's C `main` calls (L16): always one that makes the package
   constants, if any, and then calls the root package's `main`. A library has
   no entry. [layouts] is each layout the program names, [globals] each of
   its variables, and [foreign] each thunk of the glue it calls.
   [exclusive] is whether the program runs on one thread: it is not a
   library, and no package of the build spawns. [comptime] is each function
   a call marked `comptime` was lifted into (Lower_comptime), with the
   call's span: each call of one is a call through its address with no
   arguments, which Optimize.Comptime replaces by the value it gives before
   codegen, which never sees one. [exports] is each exported lambda the
   build gives a C symbol (packages.md §8.3), as the symbol of its lifted
   function and the C name: a dynamic library has no entry, and a host
   calls these instead. *)
module Program = struct
  type t = {
    funcs : Func.t list;
    comptime : (string * Source.Span.t) list;
    entry : string option;
    layouts : (Layout.t * Layout.position list) list;
    globals : Global.t list;
    foreign : Foreign.t list;
    callbacks : Callback.t list;
    exclusive : bool;
    exports : (string * string) list;
    (* Whether the module is a plugin package's dynamic library, which has
       no entry and starts a runtime of its own (packages.md §8.1). *)
    plugin : bool;
  }
end
