(* An ELF relocatable object with its symbols renamed. A symbol names itself
   by an offset into a string table, and a stamped name is longer than the
   placeholder it replaces, so the new names cannot go where the old ones
   are. Instead the string table is copied to the end of the file with the
   new names after it, its section header points there, and each renamed
   symbol points at its new name. The old table stays behind, unread, and
   nothing else in the file moves: relocations and section groups name a
   symbol by its index, not its name. *)

open Field

type layout = {
  wide : bool;  (** ELFCLASS64 *)
  little : bool;
}

let u16 l = Field.u16 ~little:l.little
let u32 l = Field.u32 ~little:l.little
let u64 l = Field.u64 ~little:l.little
let set_u32 l = Field.set_u32 ~little:l.little
let set_u64 l = Field.set_u64 ~little:l.little

(* A field that is 4 bytes wide in a 32-bit file and 8 in a 64-bit one. *)
let word l b o = if l.wide then u64 l b o else u32 l b o
let set_word l b o v = if l.wide then set_u64 l b o v else set_u32 l b o v

let is s = String.length s >= 4 && String.sub s 0 4 = "\x7fELF"

type section = { header : int; kind : int; offset : int; size : int; link : int; entsize : int }

let sht_symtab = 2
let sht_strtab = 3
let sht_dynsym = 11
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
        entsize = word l b (h + if l.wide then 56 else 36);
      }
    in
    (* With 0xff00 sections or more, the count is the first header's size. *)
    let shnum = if shnum = 0 then (at 0).size else shnum in
    if shoff > Bytes.length b || shnum > (Bytes.length b - shoff) / shentsize then
      malformed "the section headers run past the end of the file";
    Array.init shnum at
  end

(* The NUL-terminated name at [o] in the string table [t]. *)
let name b t o = cstring b ~table:t.offset ~size:t.size ~at:o "a symbol's name"

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
  let within t = Field.within b ~offset:t.offset ~size:t.size "a section" in
  (* Each string table some symbol table names: the strings to append to it,
     and the end of the table they are appended after. *)
  let tables = Hashtbl.create 1 in
  let renamed = ref [] in
  Array.iter
    (fun symtab ->
      (* A relocatable object a library is built into has no dynamic symbols.
         One that does is not rewritten, rather than rewritten in part. *)
      if symtab.kind = sht_dynsym then malformed "it has a dynamic symbol table";
      if symtab.kind = sht_symtab then begin
        within symtab;
        let entsize = if wide then 24 else 16 in
        if symtab.entsize <> entsize || symtab.size mod entsize <> 0 then
          malformed "a symbol table's entries are not ELF symbols";
        if symtab.link <= 0 || symtab.link >= Array.length sections then
          malformed "a symbol table names no string table";
        let strtab = sections.(symtab.link) in
        if strtab.kind <> sht_strtab then malformed "a symbol table names no string table";
        within strtab;
        let added =
          match Hashtbl.find_opt tables symtab.link with
          | Some added -> added
          | None ->
              let added = Appended.create strtab.size in
              Hashtbl.replace tables symtab.link added;
              added
        in
        for i = 0 to (symtab.size / entsize) - 1 do
          let entry = symtab.offset + (i * entsize) in
          let old = u32 l b entry in
          if old <> 0 then
            match Name.rewrite ~stamp (name b strtab old) with
            | None -> ()
            | Some fresh -> renamed := (entry, Appended.add added fresh) :: !renamed
        done
      end)
    sections;
  List.iter (fun (entry, at) -> set_u32 l b entry at) !renamed;
  (* Each grown table, copied to the end of the file with its new names. *)
  let out = Buffer.create (Bytes.length b + 4096) in
  Buffer.add_bytes out b;
  let moves =
    Hashtbl.fold
      (fun index (added : Appended.t) moves ->
        if Appended.is_empty added then moves
        else begin
          let t = sections.(index) in
          let offset = Buffer.length out in
          Buffer.add_subbytes out b t.offset t.size;
          Buffer.add_buffer out added.text;
          (t, offset, added.size) :: moves
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
