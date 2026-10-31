(* A package's C that reaches the link as objects rather than through its
   module (docs/design/ffi.md F4, F9): an `archive` row's static library,
   read member by member, and each C source whose module holds assembly,
   emitted as an object of its own (object_stubs.cpp). The symbols an
   object defines are what renaming needs of it, and its sections what
   the linker-set test needs. *)

external emit_raw : string -> string -> string -> (string, string) result = "zane_object_emit"
external read_raw : string -> ((string * string) list * string list * string * string, string) result
  = "zane_object_read"
external triple_arch : string -> string = "zane_triple_arch"
external members_raw : string -> ((string * string) list, string) result = "zane_archive_members"

(* What an object holds: the C names of the global symbols it defines,
   and of those the ones that are data, the names of the variables and
   functions local to it, its sections' names, the architecture it is for, as
   [triple_arch] spells a triple's, the symbols its linker directives
   name, and, for Mach-O, the global symbols it defines without the `_`
   every C name takes there, which renaming cannot reach. *)
type contents = {
  defined : string list;
  data : string list;
  locals : string list;
  sections : string list;
  arch : string;
  directed : string list;
  unprefixed : string list;
}

(* The symbols the COFF linker directives [text] names, as a `.drectve`
   section holds them: `/EXPORT:NAME[=INTERNAL][,...]`, which
   `__declspec(dllexport)` writes, `/INCLUDE:NAME` and
   `/ALTERNATENAME:NAME=OTHER`, each spelled with `/` or `-`, in any case,
   and quoted or not. Other directives name no symbol. *)
let directive_names text =
  let unquoted s = String.concat "" (String.split_on_char '"' s) in
  let named token =
    match String.index_opt token ':' with
    | None -> []
    | Some i when i > 1 && (token.[0] = '/' || token.[0] = '-') -> (
        let argument = unquoted (String.sub token (i + 1) (String.length token - i - 1)) in
        let first = List.hd (String.split_on_char ',' argument) in
        match String.lowercase_ascii (String.sub token 1 (i - 1)) with
        | "export" | "alternatename" -> String.split_on_char '=' first
        | "include" -> [ first ]
        | _ -> [])
    | Some _ -> []
  in
  String.split_on_char ' ' (String.map (function '\t' | '\n' | '\r' | '\000' -> ' ' | c -> c) text)
  |> List.concat_map named
  |> List.filter (fun n -> n <> "")

(* Whether [section] is one an object's constructors or destructors are
   listed in, so linking the object runs them: ELF's `.init_array`,
   `.fini_array`, `.preinit_array`, `.ctors` and `.dtors`, each perhaps
   with a priority after a `.`; Mach-O's `__mod_init_func`,
   `__mod_term_func` and `__init_offsets` in any segment; and COFF's
   `.CRT$XC` and `.CRT$XT` groups. *)
let runs_code section =
  let named n = section = n || String.starts_with ~prefix:(n ^ ".") section in
  List.exists named [ ".init_array"; ".fini_array"; ".preinit_array"; ".ctors"; ".dtors" ]
  || List.exists
       (fun n -> String.ends_with ~suffix:("," ^ n) section)
       [ "__mod_init_func"; "__mod_term_func"; "__init_offsets" ]
  || String.starts_with ~prefix:".CRT$XC" section
  || String.starts_with ~prefix:".CRT$XT" section

let read bytes =
  let kind k = List.filter_map (fun (n, kind) -> if kind = k then Some n else None) in
  Result.map
    (fun (names, sections, arch, directives) ->
      {
        defined =
          List.filter_map (fun (n, kind) -> if kind = "local" || kind = "unprefixed" then None else Some n) names;
        data = kind "data" names;
        locals = kind "local" names;
        sections;
        arch;
        directed = directive_names directives;
        unprefixed = kind "unprefixed" names;
      })
    (read_raw bytes)

(* The module [bitcode] holds optimized and emitted as an object for
   [triple] and [cpu], kept in [cache]'s `foreign/assembled/` under a hash
   of what made it: how the object is emitted, the module's own key, the
   target and the processor. *)
let emit ?cache ~triple ~cpu ~key bitcode =
  (* Named anew whenever the emitter changes what it makes, so an object
     an earlier one made is not taken from the cache: `init_array` since
     constructors go there. *)
  let emitter = "assembled.init_array" in
  let key = Digest.to_hex (Digest.string (String.concat "\000" [ emitter; key; triple; cpu ])) in
  let kept = Option.map (fun c -> List.fold_left Filename.concat c [ "foreign"; "assembled"; key ^ ".o" ]) cache in
  match Option.bind kept Cache.read with
  | Some object_ -> Ok object_
  | None ->
      Result.map
        (fun object_ ->
          Option.iter (fun kept -> Cache.keep_string ~dir:(Filename.dirname kept) ~kept object_) kept;
          object_)
        (emit_raw bitcode triple cpu)

(* The members of a static library, each its name and its bytes. *)
let members = members_raw
