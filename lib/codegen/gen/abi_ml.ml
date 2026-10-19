(* Reads runtime/zane_abi.h, named on the command line, and prints the
   [Abi] module: each `#define ZANE_NAME number` as `let name = number`,
   and [values], every one by its C name, for the test that compares them
   with what the runtime's structs measure. A `#define` of a name alone is
   the include guard; any other line that is not a plain number is a
   mistake in the header, which stops the build here rather than giving the
   compiler a number the runtime does not have. *)

let () =
  let path = Sys.argv.(1) in
  let lines = In_channel.with_open_bin path In_channel.input_lines in
  let defines =
    List.filter_map
      (fun line ->
        match String.split_on_char ' ' (String.trim line) |> List.filter (( <> ) "") with
        | [ "#define"; _ ] -> None
        | [ "#define"; name; value ] -> (
            let ok_name =
              String.length name > 5
              && String.sub name 0 5 = "ZANE_"
              && String.for_all (function 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false) name
            in
            match (ok_name, String.for_all (function '0' .. '9' -> true | _ -> false) value) with
            | true, true when value <> "" -> Some (name, value)
            | _ ->
                Printf.eprintf "%s: `%s` is not `#define ZANE_NAME number`\n" path (String.trim line);
                exit 1)
        | "#define" :: _ ->
            Printf.eprintf "%s: `%s` is not `#define ZANE_NAME number`\n" path (String.trim line);
            exit 1
        | _ -> None)
      lines
  in
  let ocaml name = String.lowercase_ascii (String.sub name 5 (String.length name - 5)) in
  print_string
    "(* Generated from runtime/zane_abi.h by lib/codegen/gen/abi_ml.ml: the\n\
    \   offsets, sizes and counts emitted code relies on, as the runtime has\n\
    \   them. *)\n\n";
  List.iter (fun (name, value) -> Printf.printf "let %s = %s\n" (ocaml name) value) defines;
  print_string "\n(* Every number above, by its name in the header. *)\nlet values =\n  [\n";
  List.iter (fun (name, value) -> Printf.printf "    (%S, %s);\n" name value) defines;
  print_string "  ]\n"
