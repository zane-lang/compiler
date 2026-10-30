(* The file `--object` writes beside a package build's object
   (docs/design/ffi.md F15): for each C source and each glue module of the
   packages the object holds, the hash F3 keys its module by, which a
   consumer compares with the one it computes for the module it compiles
   from the dependency's checkout before it retains that module (F13).

   It is a Coda table, `c-hashes`, one row per module: the package as the
   object's symbols name it, `!` before a library's own package, which
   fetching stamps in the file as it does in the objects (`--rewrite`);
   the package as the glue's labels named it, which nothing rewrites, so a
   consumer writes the glue again under the same labels; whether the
   module is a `source` or the `glue` of an interface header; that file,
   relative to the package's directory; and the hash. *)

type kind = Source | Glue
type row = { package : string; labels : string; kind : kind; file : string; hash : string }

let table = "c-hashes"
let columns = [ "package"; "labels"; "module"; "file"; "hash" ]
let kind_name = function Source -> "source" | Glue -> "glue"

(* [s] as a quoted Coda string. *)
let quoted s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\t' -> Buffer.add_string b "\\t"
      | '\r' -> Buffer.add_string b "\\r"
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let header = table ^ " [\n"

(* The file's text for [rows]. *)
let write rows =
  let line (r : row) =
    "    " ^ String.concat " " (List.map quoted [ r.package; r.labels; kind_name r.kind; r.file; r.hash ]) ^ "\n"
  in
  header ^ "    " ^ String.concat " " columns ^ "\n" ^ String.concat "" (List.map line rows) ^ "]\n"

(* Whether [text] is such a file rather than an object. *)
let is text = String.starts_with ~prefix:header text

(* The rows of the file [text], or why it is not one. *)
let read text =
  match Coda.parse text None with
  | Error (e : Coda.error) -> Error e.message
  | Ok doc ->
      Fun.protect
        ~finally:(fun () -> Coda.free doc)
        (fun () ->
          match Coda.map_get doc (Coda.root doc) table with
          | Some t
            when Coda.node_kind doc t = Coda.NodeTable
                 && List.init (Coda.table_col_count doc t) (Coda.table_col_name doc t) = columns ->
              let row i =
                let r = Coda.table_row_at doc t i in
                let get = Coda.row_get doc r in
                let kind = match get "module" with "source" -> Some Source | "glue" -> Some Glue | _ -> None in
                Option.map
                  (fun kind -> { package = get "package"; labels = get "labels"; kind; file = get "file"; hash = get "hash" })
                  kind
              in
              let rows = List.init (Coda.table_row_count doc t) row in
              if List.for_all Option.is_some rows then Ok (List.filter_map Fun.id rows)
              else Error "a row's `module` is neither `source` nor `glue`"
          | _ -> Error (Printf.sprintf "it holds no `%s` table of `%s`" table (String.concat " " columns)))

(* The file [text] with each `!` of its packages replaced by [stamp], as
   fetching rewrites the objects beside it, and how many rows changed. *)
let rewrite ~stamp text =
  Result.map
    (fun rows ->
      let stamped (r : row) = { r with package = String.concat stamp (String.split_on_char '!' r.package) } in
      let rows' = List.map stamped rows in
      (write rows', List.length (List.filter (fun (a, b) -> a <> b) (List.combine rows rows'))))
    (read text)
