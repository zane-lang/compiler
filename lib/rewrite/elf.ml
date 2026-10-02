(* An ELF relocatable object with its symbols renamed. A symbol names itself
   by an offset into a string table, and a stamped name is longer than the
   placeholder it replaces, so the new names cannot go where the old ones
   are. Instead the string table is copied to the end of the file with the
   new names after it, its section header points there, and each renamed
   symbol points at its new name. The old table stays behind, unread, and
   nothing else in the file moves: relocations and section groups name a
   symbol by its index, not its name. *)

exception Malformed of string

let malformed what = raise (Malformed what)

type layout = {
  wide : bool;  (** ELFCLASS64 *)
  little : bool;
}

let u16 l b o =
  if o < 0 || o + 2 > Bytes.length b then malformed "a header runs past the end of the file";
  if l.little then Bytes.get_uint16_le b o else Bytes.get_uint16_be b o

let u32 l b o =
  if o < 0 || o + 4 > Bytes.length b then malformed "a header runs past the end of the file";
  Int32.to_int (if l.little then Bytes.get_int32_le b o else Bytes.get_int32_be b o)
  land 0xFFFF_FFFF

let u64 l b o =
  if o < 0 || o + 8 > Bytes.length b then malformed "a header runs past the end of the file";
  let v = if l.little then Bytes.get_int64_le b o else Bytes.get_int64_be b o in
  if Int64.compare v 0L < 0 || Int64.compare v (Int64.of_int max_int) > 0 then
    malformed "an offset is too large";
  Int64.to_int v

let set_u32 l b o v =
  let v = Int32.of_int v in
  if l.little then Bytes.set_int32_le b o v else Bytes.set_int32_be b o v

let set_u64 l b o v =
  let v = Int64.of_int v in
  if l.little then Bytes.set_int64_le b o v else Bytes.set_int64_be b o v

(* A field that is 4 bytes wide in a 32-bit file and 8 in a 64-bit one. *)
let word l b o = if l.wide then u64 l b o else u32 l b o
let set_word l b o v = if l.wide then set_u64 l b o v else set_u32 l b o v

let is b = Bytes.length b >= 4 && Bytes.sub_string b 0 4 = "\x7fELF"

type section = { header : int; kind : int; offset : int; size : int; link : int }

let sht_symtab = 2
let et_rel = 1

let sections l b =
  let shoff = word l b (if l.wide then 0x28 else 0x20) in
  let shentsize = u16 l b (if l.wide then 0x3A else 0x2E) in
  let shnum = u16 l b (if l.wide then 0x3C else 0x30) in
  if shoff = 0 then [||]
  else begin
    if shentsize < (if l.wide then 64 else 40) then malformed "the section headers are too small";
    let at i =
      let h = shoff + (i * shentsize) in
      {
        header = h;
        kind = u32 l b (h + 4);
        offset = word l b (h + if l.wide then 24 else 16);
        size = word l b (h + if l.wide then 32 else 20);
        link = u32 l b (h + if l.wide then 40 else 24);
      }
    in
    (* With 0xff00 sections or more, the count is the first header's size. *)
    let shnum = if shnum = 0 then (at 0).size else shnum in
    Array.init shnum at
  end

(* The NUL-terminated name at [o] in the string table [t]. *)
let name b t o =
  if o >= t.size then malformed "a symbol's name lies outside its string table";
  let start = t.offset + o in
  match Bytes.index_from_opt b start '\000' with
  | Some stop when stop < t.offset + t.size -> Bytes.sub_string b start (stop - start)
  | _ -> malformed "a symbol's name is not terminated within its string table"

let rewrite ~stamp input =
  let b = Bytes.of_string input in
  if Bytes.length b < 0x34 then malformed "the file is too short for an ELF header";
  let wide =
    match Bytes.get b 4 with
    | '\001' -> false
    | '\002' -> true
    | _ -> malformed "the ELF class is neither 32- nor 64-bit"
  in
  let little =
    match Bytes.get b 5 with
    | '\001' -> true
    | '\002' -> false
    | _ -> malformed "the ELF byte order is unknown"
  in
  let l = { wide; little } in
  if u16 l b 16 <> et_rel then malformed "the file is not a relocatable object";
  let sections = sections l b in
  let within t =
    if t.offset + t.size > Bytes.length b then malformed "a section runs past the end of the file"
  in
  (* Each string table some symbol table names: the strings to append to it,
     and the end of the table they are appended after. *)
  let tables = Hashtbl.create 1 in
  let renamed = ref [] in
  Array.iter
    (fun symtab ->
      if symtab.kind = sht_symtab then begin
        within symtab;
        if symtab.link <= 0 || symtab.link >= Array.length sections then
          malformed "a symbol table names no string table";
        let strtab = sections.(symtab.link) in
        within strtab;
        let added, size, seen =
          match Hashtbl.find_opt tables symtab.link with
          | Some t -> t
          | None -> (Buffer.create 256, ref strtab.size, Hashtbl.create 64)
        in
        Hashtbl.replace tables symtab.link (added, size, seen);
        let entsize = if wide then 24 else 16 in
        for i = 0 to (symtab.size / entsize) - 1 do
          let entry = symtab.offset + (i * entsize) in
          let old = u32 l b entry in
          if old <> 0 then
            match Name.rewrite ~stamp (name b strtab old) with
            | None -> ()
            | Some fresh ->
                let at =
                  match Hashtbl.find_opt seen fresh with
                  | Some at -> at
                  | None ->
                      let at = !size in
                      Buffer.add_string added fresh;
                      Buffer.add_char added '\000';
                      size := at + String.length fresh + 1;
                      Hashtbl.add seen fresh at;
                      at
                in
                renamed := (entry, at) :: !renamed
        done
      end)
    sections;
  List.iter (fun (entry, at) -> set_u32 l b entry at) !renamed;
  (* Each grown table, copied to the end of the file with its new names. *)
  let out = Buffer.create (Bytes.length b + 4096) in
  Buffer.add_bytes out b;
  let moves =
    Hashtbl.fold
      (fun index (added, size, _) moves ->
        if Buffer.length added = 0 then moves
        else begin
          let t = sections.(index) in
          let offset = Buffer.length out in
          Buffer.add_subbytes out b t.offset t.size;
          Buffer.add_buffer out added;
          (t, offset, !size) :: moves
        end)
      tables []
  in
  let result = Buffer.to_bytes out in
  List.iter
    (fun (t, offset, size) ->
      set_word l result (t.header + if wide then 24 else 16) offset;
      set_word l result (t.header + if wide then 32 else 20) size)
    moves;
  (Bytes.to_string result, List.length !renamed)
