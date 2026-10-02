(* Reading and writing an object file's fixed-width fields, every read
   bounds-checked, and the string table a rewrite appends its new names to.
   A file that does not hold together raises [Malformed], which [Rewrite]
   reports rather than lets escape. *)

exception Malformed of string

let malformed what = raise (Malformed what)

let check b o n =
  if o < 0 || n < 0 || o > Bytes.length b - n then malformed "a header runs past the end of the file"

let u8 b o =
  check b o 1;
  Bytes.get_uint8 b o

let u16 ~little b o =
  check b o 2;
  if little then Bytes.get_uint16_le b o else Bytes.get_uint16_be b o

let u32 ~little b o =
  check b o 4;
  Int32.to_int (if little then Bytes.get_int32_le b o else Bytes.get_int32_be b o) land 0xFFFF_FFFF

let u64 ~little b o =
  check b o 8;
  let v = if little then Bytes.get_int64_le b o else Bytes.get_int64_be b o in
  if Int64.compare v 0L < 0 || Int64.compare v (Int64.of_int max_int) > 0 then
    malformed "an offset is too large";
  Int64.to_int v

let set_u32 ~little b o v =
  let v = Int32.of_int v in
  if little then Bytes.set_int32_le b o v else Bytes.set_int32_be b o v

let set_u64 ~little b o v =
  let v = Int64.of_int v in
  if little then Bytes.set_int64_le b o v else Bytes.set_int64_be b o v

(* Whether [size] bytes at [offset] lie within the file, checked without the
   sum that could overflow. *)
let within b ~offset ~size what =
  if offset < 0 || size < 0 || offset > Bytes.length b || size > Bytes.length b - offset then
    malformed (what ^ " runs past the end of the file")

(* The NUL-terminated string at index [at] of the string table of [size]
   bytes at [table], which must end within the table. The index is checked
   against the size before it is added to the table's offset. *)
let cstring b ~table ~size ~at what =
  if at < 0 || at >= size then malformed (what ^ " lies outside its string table");
  let start = table + at in
  match Bytes.index_from_opt b start '\000' with
  | Some stop when stop - table < size -> Bytes.sub_string b start (stop - start)
  | _ -> malformed (what ^ " is not terminated within its string table")

(* The names a rewrite appends to a string table that is [size] bytes long,
   each once: [add] gives the offset a new name will have in the grown
   table. *)
module Appended = struct
  type t = { text : Buffer.t; mutable size : int; seen : (string, int) Hashtbl.t }

  let create size = { text = Buffer.create 256; size; seen = Hashtbl.create 64 }

  let add t name =
    match Hashtbl.find_opt t.seen name with
    | Some at -> at
    | None ->
        let at = t.size in
        Buffer.add_string t.text name;
        Buffer.add_char t.text '\000';
        t.size <- at + String.length name + 1;
        Hashtbl.add t.seen name at;
        at

  let is_empty t = Buffer.length t.text = 0
end
