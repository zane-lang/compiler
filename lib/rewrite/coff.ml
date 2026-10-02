(* A COFF object with its symbols renamed, in either header form: the
   standard one, or the "big object" one an object with very many sections
   uses. A symbol keeps a name of up to 8 bytes in its own record, and a
   longer one as an offset into the string table, which directly follows the
   symbol table and is the last thing in the file. A stamped name is always
   longer than 8 bytes, so each renamed symbol gets an offset, and the new
   names grow the string table at the file's end. Nothing else moves, since
   relocations name a symbol by its index. *)

open Field

(* x86, x86-64, ARM Thumb-2, and ARM64. *)
let machines = [ 0x14c; 0x8664; 0x1c4; 0xaa64 ]

(* The class identifier a big-object header carries. *)
let bigobj_class = "\xc7\xa1\xba\xd1\xee\xba\xa9\x4b\xaf\x20\xfa\xf6\x6a\xa4\xdc\xb8"

type header = { symbols : int; count : int; record : int }

let header s =
  let n = String.length s in
  let u16 o = String.get_uint16_le s o in
  let u32 o = Int32.to_int (String.get_int32_le s o) land 0xFFFF_FFFF in
  if n >= 56 && u16 0 = 0 && u16 2 = 0xffff then
    if u16 4 >= 2 && List.mem (u16 6) machines && String.sub s 12 16 = bigobj_class then
      Some { symbols = u32 48; count = u32 52; record = 20 }
    else None
  else if n >= 20 && List.mem (u16 0) machines && u16 16 = 0 then
    Some { symbols = u32 8; count = u32 12; record = 18 }
  else None

let is s = header s <> None

let rewrite ~stamp input =
  let h = match header input with Some h -> h | None -> malformed "the file is not COFF" in
  let little = true in
  let b = Bytes.of_string input in
  if h.symbols = 0 then (input, 0)
  else begin
    if h.count > Bytes.length b / h.record then
      malformed "the symbol table runs past the end of the file";
    within b ~offset:h.symbols ~size:(h.count * h.record) "the symbol table";
    let strings = h.symbols + (h.count * h.record) in
    let size = u32 ~little b strings in
    if size < 4 then malformed "the string table is too small";
    within b ~offset:strings ~size "the string table";
    if strings + size <> Bytes.length b then
      malformed "something follows the string table";
    let added = Appended.create size in
    let renamed = ref [] in
    (* Each symbol's auxiliary records, which follow it, are skipped. *)
    let rec walk i =
      if i < h.count then begin
        let entry = h.symbols + (i * h.record) in
        let name =
          if u32 ~little b entry = 0 then
            let offset = u32 ~little b (entry + 4) in
            if offset < 4 then malformed "a symbol's name lies outside its string table";
            cstring b ~table:strings ~size ~at:offset "a symbol's name"
          else
            let field = Bytes.sub_string b entry 8 in
            match String.index_opt field '\000' with
            | Some n -> String.sub field 0 n
            | None -> field
        in
        (match Name.rewrite ~stamp name with
        | None -> ()
        | Some fresh -> renamed := (entry, Appended.add added fresh) :: !renamed);
        walk (i + 1 + u8 b (entry + h.record - 1))
      end
    in
    walk 0;
    if Appended.is_empty added then (input, 0)
    else begin
      List.iter
        (fun (entry, at) ->
          set_u32 ~little b entry 0;
          set_u32 ~little b (entry + 4) at)
        !renamed;
      set_u32 ~little b strings added.size;
      (Bytes.to_string b ^ Buffer.contents added.text, List.length !renamed)
    end
  end
