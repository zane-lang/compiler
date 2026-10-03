open Ambiguity_engine
open Automaton

let graph count edges productions =
  let states = Array.init count (fun _ -> empty_state ()) in
  List.iter (fun (source, symbol, target) ->
    Hashtbl.replace states.(source).transitions symbol target) edges;
  let production_text = Hashtbl.create 16 in
  List.iteri (fun id rhs ->
    Hashtbl.add production_text id ("s -> " ^ String.concat " " rhs)) productions;
  { states; production_text; terminals = StringSet.empty;
    aliases = Hashtbl.create 0; terminal_class = Hashtbl.create 0;
    min_height = Array.make count 1 }

let () =
  let automaton = graph 5
      [(0,"A",1); (1,"n",3); (4,"B",2); (2,"m",3)]
      [["A";"n"]; ["B";"m"]; []] in
  let bases = Abstraction.reduction_bases automaton in
  assert (bases [3] 0 = IntSet.singleton 0);
  assert (bases [3] 1 = IntSet.singleton 4);
  assert (IntSet.is_empty (bases [3;2] 0));
  assert (bases [3;1;0] 0 = IntSet.singleton 0);
  assert (bases [3;1;0] 2 = IntSet.singleton 3);
  (* Compare the reverse matcher against independently enumerated forward
     labelled paths. This covers epsilon rules, cycles, shared targets and
     both short and fully retained suffixes. *)
  let random = Random.State.make [|20261001; 2|] in
  let symbols = [|"A"; "n"; "B"|] in
  for _ = 1 to 200 do
    let edges = List.init 5 (fun source ->
      Array.to_list symbols |> List.filter_map (fun symbol ->
        if Random.State.bool random then
          Some (source, symbol, Random.State.int random 5) else None))
      |> List.concat in
    let productions = List.init 20 (fun _ ->
      List.init (Random.State.int random 5)
        (fun _ -> symbols.(Random.State.int random 3))) in
    let automaton = graph 5 edges productions in
    let bases = Abstraction.reduction_bases automaton in
    List.iteri (fun prod rhs ->
      for _ = 1 to 5 do
        let suffix = List.init (1 + Random.State.int random 6)
            (fun _ -> Random.State.int random 5) in
        let expected = ref IntSet.empty in
        for source = 0 to 4 do
          let rec walk path state = function
            | [] -> Some path
            | symbol :: rest ->
                (match Hashtbl.find_opt automaton.states.(state).transitions symbol with
                 | None -> None
                 | Some target -> walk (target :: path) target rest) in
          match walk [source] source rhs with
          | None -> ()
          | Some path ->
              let rec compatible known actual = match known, actual with
                | [], _ | _, [] -> true
                | k :: ks, a :: tail -> k = a && compatible ks tail in
              if compatible suffix path then expected := IntSet.add source !expected
        done;
        assert (IntSet.equal (bases suffix prod) !expected)
      done) productions
  done
