(* What a linker's errors say, read so that a failed link is reported in
   the program's terms: a library a `system` row asks for that the linker
   cannot find, the undefined symbols and the foreign verbs they belong to,
   and whether anything else went wrong. Build includes it. *)

(* Whether [text], a linker's errors, reports that the linker cannot find
   the library [name], as `ld.lld`, `lld-link`, `ld64`, GNU `ld` and
   `zig cc` write it (`zig cc` looks for a library itself before it
   links). The name must end where the linker's word does, so `-lz` is
   not found in `-lzstd`. *)
let unfound_library text name =
  let in_word = function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' | '+' | '-' -> true | _ -> false in
  let ends i = i >= String.length text || not (in_word text.[i]) in
  List.exists
    (fun before ->
      let word = before ^ name in
      let n = String.length word in
      let rec at i j = j >= n || (text.[i + j] = word.[j] && at i (j + 1)) in
      let rec from i = i <= String.length text - n && ((at i 0 && ends (i + n)) || from (i + 1)) in
      from 0)
    [ "unable to find library -l"; "library not found for -l"; "cannot find -l"; "system library '"; "system library \"" ]

(* A failed link of [libraries] as the error that names the row of the
   library the linker could not find, when its [text] reports that. *)
let library_error libraries text =
  List.find_map
    (fun (l : Foreign_c.library) ->
      if unfound_library text l.name then
        Some
          (Printf.sprintf
             "%s names the system library `%s`, which the linker cannot find for the build's target (ffi.md §2.4)"
             l.row l.name)
      else None)
    libraries

(* Each C symbol [text], a linker's errors, reports as undefined, beside the
   function referencing it, as GNU `ld` writes it (`in function `F':` and
   then `undefined reference to `S'`), as `ld.lld` and `lld-link` do
   (`undefined symbol: S`, then `>>> referenced by …:(F)`) and as `ld64`
   does (`"_S", referenced from:`, then `F in …`). *)
let undefined_symbols text =
  (* What follows the first [prefix] in [line]. *)
  let after prefix line =
    let n = String.length prefix and m = String.length line in
    let rec find i = if i + n > m then None else if String.sub line i n = prefix then Some (i + n) else find (i + 1) in
    Option.map (fun i -> String.sub line i (m - i)) (find 0)
  in
  let before stop s = match String.index_opt s stop with Some i -> String.sub s 0 i | None -> s in
  (* [s] up to its last [word]. *)
  let before_last word s =
    let n = String.length word in
    let rec find i = if i < 0 then s else if String.sub s i n = word then String.sub s 0 i else find (i - 1) in
    find (String.length s - n)
  in
  (* The text between the `:(` after the object's path and the last `)`:
     lld writes the referencing function there, and it may hold
     parentheses itself, as the path may, an archive member's
     `lib.a(m.o)` among them. *)
  let parenthesized s =
    let opening =
      match after ":(" s with Some rest -> Some (String.length s - String.length rest - 1) | None -> String.index_opt s '('
    in
    match (opening, String.rindex_opt s ')') with
    | Some i, Some j when j > i -> Some (String.sub s (i + 1) (j - i - 1))
    | _ -> None
  in
  (* Whether a GNU `ld` line locates its reference in code: its section,
     in `:(SECTION+0xN):`, is `.text` or one of `.text.`, or it gives a
     source line instead. `ld` writes no `in function` header for a
     reference from data, which the last header does not own. *)
  let in_code line =
    match after ":(" line with
    | Some rest ->
        let section = before '+' (before ')' rest) in
        section = ".text" || String.starts_with ~prefix:".text." section
    | None -> true
  in
  (* The function in lld's parenthesized location, which its Mach-O
     flavour writes `symbol F+0xN`. *)
  let located f =
    let f = if String.starts_with ~prefix:"symbol " f then String.sub f 7 (String.length f - 7) else f in
    match String.rindex_opt f '+' with
    | Some i when String.length f > i + 2 && String.sub f (i + 1) 2 = "0x" -> String.sub f 0 i
    | _ -> f
  in
  let found = ref [] in
  let func = ref None and symbol = ref None in
  List.iter
    (fun line ->
      match
        ( after "in function `" line,
          after "undefined reference to `" line,
          after "undefined symbol: " line,
          after ">>> " line,
          after "\", referenced from:" line )
      with
      | Some f, _, _, _, _ -> func := Some (before '\'' f)
      | _, Some s, _, _, _ ->
          (* A reference no function owns is kept too, so that it counts
             among the symbols no foreign verb explains. *)
          let f = if in_code line then !func else None in
          found := (before '\'' s, Option.value ~default:"" f) :: !found
      | _, _, Some s, _, _ -> symbol := Some (String.trim s)
      | _, _, _, Some r, _ -> (
          match (!symbol, parenthesized r) with Some s, Some f -> found := (s, located f) :: !found | _ -> ())
      | _, _, _, _, Some _ -> (
          match after "\"" line with Some s -> symbol := Some (before '"' s) | None -> symbol := None)
      | None, None, None, None, None -> (
          match !symbol with
          | Some s when String.starts_with ~prefix:" " line && after " in " line <> None ->
              found := (s, before_last " in " (String.trim line)) :: !found
          | _ -> ()))
    (String.split_on_char '\n' text);
  List.sort_uniq compare !found

(* A failed link as the error that names each foreign verb whose C
   function nothing linked defines, when its [text] reports that, and whether
   that is every undefined symbol [text] names: the glue's thunk for a
   foreign verb is the verb's symbol and `.ffi`, so the function
   referencing the undefined symbol names the verb. Where the target puts
   `_` before every C name, as Mach-O does ([underscored]), both names
   lose it. *)
let undefined_error ?(underscored = false) text =
  let unprefixed f s =
    if underscored && String.starts_with ~prefix:"_" f then
      let drop x = if String.starts_with ~prefix:"_" x then String.sub x 1 (String.length x - 1) else x in
      (drop f, drop s)
    else (f, s)
  in
  let verb (s, f) =
    let f, s = unprefixed f s in
    if String.ends_with ~suffix:".ffi" f then
      let f = String.sub f 0 (String.length f - 4) in
      Some ((match String.index_opt f '(' with Some i -> String.sub f 0 i | None -> f), s)
    else None
  in
  let undefined = undefined_symbols text in
  match List.sort_uniq compare (List.filter_map verb undefined) with
  | [] -> None
  | missing ->
      let named = List.length (List.filter (fun u -> verb u <> None) undefined) in
      let message =
        String.concat "\n"
          (List.map
             (fun (v, s) ->
               Printf.sprintf
                 "the foreign verb `%s` calls the C function `%s`, which an interface header declares and nothing \
                  linked defines: no C source, `archive` row or `system` row of its package gives it (ffi.md §2.4)"
                 v s)
             missing)
      in
      Some (message, named = List.length undefined)

(* Whether a linker's [text] reports any error other than undefined
   symbols: a symbol defined twice, or any other error. *)
let other_link_errors text =
  let has part line =
    let n = String.length part in
    let rec at i = i <= String.length line - n && (String.sub line i n = part || at (i + 1)) in
    at 0
  in
  List.exists
    (fun line ->
      has "duplicate symbol" line || has "multiple definition" line
      || has "error:" line
         && not
              (List.exists (fun p -> has p line)
                 [ "undefined"; "linker command failed"; "ld returned"; "too many errors" ]))
    (String.split_on_char '\n' text)

(* Whether [part] occurs in [s]. *)
let holds part s =
  let n = String.length part in
  let rec at i = i <= String.length s - n && (String.sub s i n = part || at (i + 1)) in
  at 0

(* Whether [text], what `ld64.lld` wrote, reports that it cannot read a text
   stub of the macOS SDK because the stub lists an architecture its LLVM
   does not know. The macOS 27.2 SDK's stubs list `arm64e.x1`, which LLVM 21
   does not know, and LLD rejects the whole stub (#419). *)
let unreadable_stubs text = holds "could not load TAPI file" text && holds "unknown architecture" text

(* [text], what `ld64.lld` wrote on a link it finished, without its warnings
   that a system library, one installed under `/usr/lib/` or
   `/System/Library/`, is newer than the oldest macOS the program runs on.
   The oldest macOS is the oldest one the toolchain builds for on the
   target's architecture, 13.0 on arm64, so a program runs on every Mac
   that version supports, while the SDK's stubs give each system library
   the SDK's own version, 27.2 on macOS 27.2 (#419). The program uses the
   system libraries of the Mac it runs on, so the warning is noise. A
   library of the program's own that is newer is still warned of. *)
let without_system_version_warnings text =
  let system line =
    holds "which is newer than target minimum of" line
    && List.exists (fun prefix -> holds ("warning: " ^ prefix) line) [ "/usr/lib/"; "/System/Library/" ]
  in
  String.concat "\n" (List.filter (fun line -> not (system line)) (String.split_on_char '\n' text))
