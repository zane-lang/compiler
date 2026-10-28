(* A package's `c.coda` (spec ffi.md §2.3): its C build settings, one per
   row of its `c` table, each for the targets a pattern matches. The file
   lives in the package's directory, so `zanec` reads it from each
   `--package` directory itself (docs/design/ffi.md F5).

   Every path a row names stays inside the package's directory, and a
   `source` pattern that applies to the build matches some file. What a
   row is wrong about is reported against the file, naming the row by its
   number, counted from one below the header. *)

type setting = Source | Include | Define | Archive | System

type row = { number : int; setting : setting; value : string }

let file_name = "c.coda"

let setting_names =
  [ ("source", Source); ("include", Include); ("define", Define); ("archive", Archive); ("system", System) ]

(* Whether [text] matches [pattern], in which `*` matches any run of
   characters and every other character itself. *)
let glob_matches pattern text =
  let np = String.length pattern and nt = String.length text in
  (* The classic two-pointer match, backtracking to the last `*`. *)
  let rec go p t star mark =
    if t < nt then
      if p < np && pattern.[p] = '*' then go (p + 1) t (Some p) t
      else if p < np && pattern.[p] = text.[t] then go (p + 1) (t + 1) star mark
      else match star with Some s -> go (s + 1) (mark + 1) star (mark + 1) | None -> false
    else
      let rec rest p = p = np || (pattern.[p] = '*' && rest (p + 1)) in
      rest p
  in
  go 0 0 None 0

(* The macros the fixed flags of every C compilation set or rely on (spec
   ffi.md §2.2, docs/design/ffi.md F2): a `define` of one would undo them. *)
let fixed_macros =
  [ "__FAST_MATH__"; "__FINITE_MATH_ONLY__"; "__STDC__"; "__STDC_VERSION__"; "__STDC_HOSTED__"; "__NO_MATH_ERRNO__"; "__ROUNDING_MATH__" ]

let is_identifier name =
  name <> ""
  && (match name.[0] with 'a' .. 'z' | 'A' .. 'Z' | '_' -> true | _ -> false)
  && String.for_all (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false) name

(* A `define` row's value: `NAME` or `NAME=VALUE`. *)
let define_problem value =
  let name = match String.index_opt value '=' with Some i -> String.sub value 0 i | None -> value in
  if not (is_identifier name) then
    Some (Printf.sprintf "`%s` is not a macro definition: write `NAME` or `NAME=VALUE`" value)
  else if List.mem name fixed_macros then
    Some (Printf.sprintf "`%s` is set by the flags every C source is compiled with, and cannot be defined" name)
  else None

(* A path relative to the package's directory, as its parts, or why it is
   not one: an absolute path, or one whose `..` leaves the directory. *)
let relative_parts path =
  if path = "" then Error "an empty path names nothing"
  else if (not (Filename.is_relative path)) || (String.length path >= 2 && path.[1] = ':') then
    Error (Printf.sprintf "`%s` is absolute; a path stays inside the package's directory" path)
  else
    let parts = String.split_on_char '/' path |> List.concat_map (String.split_on_char '\\') in
    let rec walk depth kept = function
      | [] -> Ok (List.rev kept)
      | ("" | ".") :: rest -> walk depth kept rest
      | ".." :: rest ->
          if depth = 0 then Error (Printf.sprintf "`%s` leaves the package's directory" path)
          else walk (depth - 1) (List.tl kept) rest
      | part :: rest -> walk (depth + 1) (part :: kept) rest
    in
    walk 0 [] parts

let problem path row message = Diagnostic.in_file path (Printf.sprintf "row %d: %s" row message)

(* The rows of the `c` table, in the order they are written, or the
   problems with the file as a whole. *)
let rows_of doc path =
  let root = Coda.root doc in
  let unknown =
    List.init (Coda.map_len doc root) (Coda.map_key_at doc root)
    |> List.filter (fun k -> k <> "c")
    |> List.map (fun k -> Diagnostic.in_file path (Printf.sprintf "`%s` is not a table of `c.coda`; its one table is `c`" k))
  in
  match Coda.map_get doc root "c" with
  | None -> Error (Diagnostic.in_file path "`c.coda` holds no `c` table" :: unknown)
  | Some table when Coda.node_kind doc table <> Coda.NodeTable ->
      Error (Diagnostic.in_file path "`c` is a table whose header is `setting value target`" :: unknown)
  | Some table ->
      let columns = List.init (Coda.table_col_count doc table) (Coda.table_col_name doc table) in
      if columns <> [ "setting"; "value"; "target" ] then
        Error
          (Diagnostic.in_file path
             (Printf.sprintf "the `c` table's header is `%s`; it is `setting value target`" (String.concat " " columns))
          :: unknown)
      else if unknown <> [] then Error unknown
      else
        Ok
          (List.init (Coda.table_row_count doc table) (fun i ->
               let row = Coda.table_row_at doc table i in
               (i + 1, Coda.row_get doc row "setting", Coda.row_get doc row "value", Coda.row_get doc row "target")))

(* A row checked on its own, before its target is considered. *)
let checked path (number, setting, value, target) =
  let problem = problem path number in
  match List.assoc_opt setting setting_names with
  | None ->
      Error
        (problem
           (Printf.sprintf "`%s` is not a setting; the settings are `source`, `include`, `define`, `archive` and `system`"
              setting))
  | Some setting -> (
      let check =
        match setting with
        | Source | Include | Archive -> Result.map (fun _ -> ()) (relative_parts value)
        | Define -> ( match define_problem value with Some why -> Error why | None -> Ok ())
        | System ->
            if value <> "" && String.for_all (function ' ' | '\t' | '/' | '\\' -> false | _ -> true) value then Ok ()
            else Error (Printf.sprintf "`%s` is not a library name" value)
      in
      match check with Ok () -> Ok (target, { number; setting; value }) | Error why -> Error (problem why))

(* What Coda said is wrong with the file, under the place it points at.
   Its message starts with the file and position and goes on to draw the
   line, which the diagnostic draws itself. *)
let parse_problem path (e : Coda.error) =
  let first = match String.index_opt e.message '\n' with Some i -> String.sub e.message 0 i | None -> e.message in
  let marker = " error: " in
  let message =
    let n = String.length marker in
    let rec find i =
      if i + n > String.length first then first
      else if String.sub first i n = marker then String.sub first (i + n) (String.length first - i - n)
      else find (i + 1)
    in
    find 0
  in
  match Option.bind (Cache.read path) (fun text -> Location.position ~path text ~line:e.line ~column:e.col) with
  | Some p -> Diagnostic.error (Source.Span.of_loc (p, p)) message
  | None -> Diagnostic.in_file path message

(* The rows of [dir]'s `c.coda` that apply to a build for [triple], in the
   order they are written: none when the package has no `c.coda`. *)
let read ~triple dir =
  let path = Filename.concat dir file_name in
  let applying rows =
    let results = List.map (checked path) rows in
    match List.filter_map (function Error p -> Some p | Ok _ -> None) results with
    | [] ->
        Ok (List.filter_map (function Ok (target, row) when glob_matches target triple -> Some row | _ -> None) results)
    | problems -> Error problems
  in
  let parsed doc =
    let rows = rows_of doc path in
    Coda.free doc;
    Result.bind rows applying
  in
  if not (Sys.file_exists path) then Ok []
  else match Coda.parse_file path with Error e -> Error [ parse_problem path e ] | Ok doc -> parsed doc

(* Whether [path] is a directory, or a file, as far as it can be read: an
   entry that cannot be, such as a dangling symlink, is neither. *)
let is_dir path = try Sys.is_directory path with Sys_error _ -> false
let is_file path = try not (Sys.is_directory path) with Sys_error _ -> false

(* Every file of [dir] matching [pattern], each part of which is a `*`
   pattern over one directory's entries, as paths relative to [dir]. *)
let expand dir parts =
  let entries d = try Array.to_list (Sys.readdir d) |> List.sort compare with Sys_error _ -> [] in
  let rec go prefix = function
    | [] -> []
    | [ last ] ->
        entries (Filename.concat dir prefix)
        |> List.filter (glob_matches last)
        |> List.map (fun e -> if prefix = "" then e else Filename.concat prefix e)
        |> List.filter (fun p -> is_file (Filename.concat dir p))
    | part :: rest ->
        entries (Filename.concat dir prefix)
        |> List.filter (glob_matches part)
        |> List.map (fun e -> if prefix = "" then e else Filename.concat prefix e)
        |> List.filter (fun p -> is_dir (Filename.concat dir p))
        |> List.concat_map (fun p -> go p rest)
  in
  go "" parts

(* The package's C sources (spec ffi.md §2.1): the `.c` files directly in
   [dir], then those each `source` row's pattern matches, in the order the
   rows are written, each once. A file a pattern matches that is not a
   `.c` file is not a C source, and is skipped. A pattern that matches
   nothing is an error. *)
let sources dir rows =
  let path = Filename.concat dir file_name in
  let direct =
    (try Array.to_list (Sys.readdir dir) with Sys_error _ -> [])
    |> List.filter (fun f -> Filename.check_suffix f ".c" && is_file (Filename.concat dir f))
    |> List.sort compare
  in
  let listed row =
    match (row.setting, relative_parts row.value) with
    | Source, Ok parts -> (
        match expand dir parts with
        | [] -> Error (problem path row.number (Printf.sprintf "`%s` matches no file" row.value))
        | found -> Ok (List.filter (fun f -> Filename.check_suffix f ".c") found))
    | _ -> Ok []
  in
  let results = List.map listed rows in
  let rec unique acc = function
    | [] -> List.rev acc
    | f :: rest -> unique (if List.mem f acc then acc else f :: acc) rest
  in
  match List.filter_map (function Error p -> Some p | Ok _ -> None) results with
  | [] -> Ok (unique [] (direct @ List.concat_map (function Ok fs -> fs | Error _ -> []) results))
  | problems -> Error problems

(* The package's interface headers (spec ffi.md §2.1): the `.h` files
   directly in [dir]. *)
let interface_headers dir =
  (try Array.to_list (Sys.readdir dir) with Sys_error _ -> [])
  |> List.filter (fun f -> Filename.check_suffix f ".h" && is_file (Filename.concat dir f))
  |> List.sort compare
