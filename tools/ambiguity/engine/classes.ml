(* `--dump-classes`: the terminal classes the automaton merged, which is what
   the search sees in place of individual tokens. *)

open Output
open Automaton

let dump automaton =
  let members = Hashtbl.create 64 in
  Hashtbl.iter
    (fun token id ->
      Hashtbl.replace members id
        (token :: Option.value (Hashtbl.find_opt members id) ~default:[]))
    automaton.terminal_class;
  let classes =
    Hashtbl.fold (fun _ tokens result -> List.sort compare tokens :: result)
      members []
    |> List.sort compare
  in
  let singletons = List.filter (fun tokens -> List.length tokens = 1) classes in
  let merged = List.filter (fun tokens -> List.length tokens > 1) classes in
  printf "%d terminals in %d classes (%d merged, %d singleton).\n"
    (StringSet.cardinal automaton.terminals)
    (List.length classes) (List.length merged) (List.length singletons);
  List.iter
    (fun tokens -> printf "  { %s }\n" (String.concat " " tokens))
    merged;
  if singletons <> [] then
    printf "  singletons: %s\n"
      (String.concat " " (List.concat singletons));
  exit 0
