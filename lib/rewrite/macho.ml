(* A Mach-O object with its symbols renamed. The symbol table is the
   `LC_SYMTAB` load command's: an array of `nlist` entries, each naming
   itself by an offset into one string table. A stamped name is longer than
   the placeholder it replaces, so the new names go after the table's end,
   and each renamed symbol points at its new name. An object's string table
   is the last thing in its file, so the table simply grows; one that is not
   is copied to the end first, as an ELF one is. Nothing else in the file
   moves, since relocations name a symbol by its index. *)

open Field

let mh_object = 1
let lc_symtab = 0x2

let magic s =
  if String.length s < 4 then None
  else
    match String.sub s 0 4 with
    | "\xcf\xfa\xed\xfe" -> Some (true, true)
    | "\xce\xfa\xed\xfe" -> Some (true, false)
    | "\xfe\xed\xfa\xcf" -> Some (false, true)
    | "\xfe\xed\xfa\xce" -> Some (false, false)
    | _ -> None

let is s = magic s <> None

let rewrite ~stamp input =
  let little, wide =
    match magic input with Some m -> m | None -> malformed "the file is not Mach-O"
  in
  let b = Bytes.of_string input in
  let u32 = u32 ~little b in
  if u32 12 <> mh_object then malformed "the file is not an object";
  let ncmds = u32 16 and sizeofcmds = u32 20 in
  let first = if wide then 32 else 28 in
  within b ~offset:first ~size:sizeofcmds "the load commands";
  (* The one `LC_SYMTAB` among the load commands, by the offset of its
     command. *)
  let rec find i at found =
    if i = ncmds then found
    else begin
      let cmd = u32 at and cmdsize = u32 (at + 4) in
      if cmdsize < 8 || cmdsize > first + sizeofcmds - at then
        malformed "a load command runs past the load commands";
      let found =
        if cmd <> lc_symtab then found
        else if found <> None then malformed "it has two symbol tables"
        else if cmdsize < 24 then malformed "the symbol table command is too small"
        else Some at
      in
      find (i + 1) (at + cmdsize) found
    end
  in
  match find 0 first None with
  | None -> (input, 0)
  | Some command ->
      let symoff = u32 (command + 8) and nsyms = u32 (command + 12) in
      let stroff = u32 (command + 16) and strsize = u32 (command + 20) in
      let entsize = if wide then 16 else 12 in
      if nsyms > Bytes.length b / entsize then malformed "the symbol table runs past the end of the file";
      within b ~offset:symoff ~size:(nsyms * entsize) "the symbol table";
      within b ~offset:stroff ~size:strsize "the string table";
      let added = Appended.create strsize in
      let renamed = ref [] in
      for i = 0 to nsyms - 1 do
        let entry = symoff + (i * entsize) in
        let strx = u32 entry in
        if strx <> 0 then
          let old =
            cstring b ~table:stroff ~size:strsize ~at:strx "a symbol's name"
          in
          match Name.rewrite ~stamp old with
          | None -> ()
          | Some fresh -> renamed := (entry, Appended.add added fresh) :: !renamed
      done;
      if Appended.is_empty added then (input, 0)
      else begin
        List.iter (fun (entry, at) -> set_u32 ~little b entry at) !renamed;
        (* The grown table keeps the alignment its entries had: 8 bytes in a
           64-bit file, 4 in a 32-bit one. *)
        let align = if wide then 8 else 4 in
        let padding = (align - (added.size mod align)) mod align in
        let size = added.size + padding in
        let out = Buffer.create (Bytes.length b + Buffer.length added.text + padding) in
        let offset =
          if stroff + strsize = Bytes.length b then begin
            Buffer.add_bytes out b;
            stroff
          end
          else begin
            Buffer.add_bytes out b;
            Buffer.add_subbytes out b stroff strsize;
            Bytes.length b
          end
        in
        Buffer.add_buffer out added.text;
        Buffer.add_string out (String.make padding '\000');
        let result = Buffer.to_bytes out in
        set_u32 ~little result (command + 16) offset;
        set_u32 ~little result (command + 20) size;
        (Bytes.to_string result, List.length !renamed)
      end
