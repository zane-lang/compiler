(* What a package's interface headers declare (spec ffi.md §2.1,
   docs/design/ffi.md F6), read from clang's AST rather than parsed here.

   Each interface header is compiled alone with the package's flags, since
   two headers that are each valid need not be valid together, and the
   linked clang writes every function, variable and typedef whose expansion
   location is in it, and every struct those reach, laid out for the
   build's target (clang_stubs.cpp). A declaration only an included header
   makes is not in the table: such a header is seen by the C compiler and
   by nothing else.

   A type is canonical, so a typedef is read as what it names, and an
   integer type carries its size and its width, the bits that hold its
   value, from the target's own information. *)

type ctype =
  | Void
  | Bool
  (* Its size and width in bits, its name, as `unsigned long`, and the
     standard typedef it was written through, as `int64_t`, when it was:
     the spec's types name both kinds (spec ffi.md §3.3), and a canonical
     `long` alone cannot say it was an `int64_t`. *)
  | Int of { signed : bool; size : int; width : int; name : string; standard : string option }
  (* Its size in bits, whether it is IEEE 754 binary32 or binary64, and its
     name. *)
  | Float of { size : int; ieee : bool; name : string }
  (* Whether what it points to is `const`, and what that is. *)
  | Pointer of { const : bool; pointee : ctype }
  (* A struct or union, by its tag, or by the typedef that names an
     anonymous one. *)
  | Record of { union : bool; name : string }
  | Array of { count : int; element : ctype }
  | Function of { params : ctype list; result : ctype; variadic : bool }
  (* A function declared without a prototype, as `int f();`. *)
  | Unprototyped of { result : ctype }
  (* Any other, by its spelling: an enum, a vector, a complex type. *)
  | Other of string

type field = { field : string; ty : ctype; offset : int; bit_width : int option }

type record = {
  union : bool;
  (* Whether an interface header declares it, as a handle's C type must
     be declared (spec ffi.md §4.1). *)
  declared : bool;
  (* Its size, alignment and fields, when it is complete. *)
  layout : layout option;
}

and layout = { size : int; align : int; fields : field list }

type func = { ty : ctype; external_ : bool }
type var = { ty : ctype; external_ : bool; thread_local : bool }

(* A package's table, by name, and the variables its C code defines with
   external linkage, which its compiled sources say rather than its
   headers: a foreign variable names one (spec ffi.md §5.1). *)
type t = {
  functions : (string * func) list;
  variables : (string * var) list;
  typedefs : (string * ctype) list;
  records : (string * record) list;
  defined : string list;
}

let empty = { functions = []; variables = []; typedefs = []; records = []; defined = [] }

exception Malformed of string

let number w = match int_of_string_opt w with Some n -> n | None -> raise (Malformed (w ^ " is no number"))

(* The words of [text]: bare tokens, and names written as their length,
   `:` and their bytes, which may hold spaces. *)
let words text =
  let n = String.length text in
  let rec skip i = if i < n && text.[i] = ' ' then skip (i + 1) else i in
  let rec go i acc =
    let i = skip i in
    if i >= n then List.rev acc
    else
      let j = ref i in
      while !j < n && text.[!j] <> ' ' && text.[!j] <> ':' do incr j done;
      if !j < n && text.[!j] = ':' then
        let len = number (String.sub text i (!j - i)) in
        if len < 0 || !j + 1 + len > n then raise (Malformed "a name runs past the end of the table");
        go (!j + 1 + len) (String.sub text (!j + 1) len :: acc)
      else go !j (String.sub text i (!j - i) :: acc)
  in
  go 0 []

let read text =
  let ws = ref (words text) in
  let next () = match !ws with w :: rest -> ws := rest; w | [] -> raise (Malformed "the table ended early") in
  let int () = number (next ()) in
  let flag () = next () = "1" in
  let rec ty () =
    match next () with
    | "V" -> Void
    | "B" -> Bool
    | "I" ->
        let signed = next () = "s" in
        let size = int () in
        let width = int () in
        let name = next () in
        let standard = match next () with "" -> None | s -> Some s in
        Int { signed; size; width; name; standard }
    | "F" ->
        let size = int () in
        let ieee = flag () in
        Float { size; ieee; name = next () }
    | "P" ->
        let const = flag () in
        Pointer { const; pointee = ty () }
    | "R" ->
        let union = next () = "u" in
        Record { union; name = next () }
    | "A" ->
        let count = int () in
        Array { count; element = ty () }
    | "N" ->
        let variadic = flag () in
        let n = int () in
        let params = List.init n (fun _ -> ty ()) in
        Function { params; result = ty (); variadic }
    | "K" -> Unprototyped { result = ty () }
    | "O" -> Other (next ())
    | w -> raise (Malformed ("no type is written " ^ w))
  in
  let field () =
    let field = next () in
    let ty = ty () in
    let offset = int () in
    let bit_width = match int () with -1 -> None | w -> Some w in
    { field; ty; offset; bit_width }
  in
  let record () =
    let union = next () = "u" in
    let declared = flag () in
    let layout =
      if flag () then
        let size = int () in
        let align = int () in
        let n = int () in
        Some { size; align; fields = List.init n (fun _ -> field ()) }
      else None
    in
    { union; declared; layout }
  in
  let rec entries t =
    match !ws with
    | [] -> t
    | _ -> (
        match next () with
        | "fun" ->
            let name = next () in
            let external_ = flag () in
            let f = { ty = ty (); external_ } in
            entries { t with functions = (name, f) :: t.functions }
        | "var" ->
            let name = next () in
            let external_ = flag () in
            let thread_local = flag () in
            let v = { ty = ty (); external_; thread_local } in
            entries { t with variables = (name, v) :: t.variables }
        | "typedef" ->
            let name = next () in
            entries { t with typedefs = (name, ty ()) :: t.typedefs }
        | "rec" ->
            let name = next () in
            entries { t with records = (name, record ()) :: t.records }
        | w -> raise (Malformed ("no entry is written " ^ w)))
  in
  let t = entries empty in
  {
    functions = List.rev t.functions;
    variables = List.rev t.variables;
    typedefs = List.rev t.typedefs;
    records = List.rev t.records;
    defined = [];
  }

(* Two tables as one: each name's first entry, in the order the headers
   are read, with a struct one header declares and another completes
   taken as declared and complete. *)
let merge a b =
  let union_by_name xs ys = xs @ List.filter (fun (n, _) -> not (List.mem_assoc n xs)) ys in
  let records =
    List.map
      (fun (n, (r : record)) ->
        match List.assoc_opt n b.records with
        | Some (r' : record) ->
            (n, { r with declared = r.declared || r'.declared; layout = (if r.layout = None then r'.layout else r.layout) })
        | None -> (n, r))
      a.records
  in
  {
    functions = union_by_name a.functions b.functions;
    variables = union_by_name a.variables b.variables;
    typedefs = union_by_name a.typedefs b.typedefs;
    records = union_by_name records b.records;
    defined = a.defined @ List.filter (fun n -> not (List.mem n a.defined)) b.defined;
  }

(* A type as C writes it, for a diagnostic. *)
let rec to_string = function
  | Void -> "void"
  | Bool -> "bool"
  | Int { standard = Some name; _ } | Int { name; _ } | Float { name; _ } -> name
  | Pointer { pointee = Function { params; result; variadic }; _ } ->
      Printf.sprintf "%s (*)(%s%s)" (to_string result)
        (match params with [] when not variadic -> "void" | _ -> String.concat ", " (List.map to_string params))
        (if variadic then ", ..." else "")
  | Pointer { const; pointee } -> (if const then "const " else "") ^ to_string pointee ^ " *"
  | Record { union; name } -> (if union then "union " else "struct ") ^ name
  | Array { count; element } -> Printf.sprintf "%s[%d]" (to_string element) count
  | Function { params = []; result; variadic = false } -> to_string result ^ " (void)"
  | Function { params; result; variadic } ->
      Printf.sprintf "%s (%s%s)" (to_string result)
        (String.concat ", " (List.map to_string params))
        (if variadic then ", ..." else "")
  | Unprototyped { result } -> to_string result ^ " ()"
  | Other s -> s
