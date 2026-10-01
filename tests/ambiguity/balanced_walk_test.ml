open Ambiguity_engine

let check edges initial accepted =
  let advance node token = List.filter_map (fun (source, label, target) ->
    if node = source && token = label then Some target else None) edges in
  let terminals = List.sort_uniq String.compare (List.map (fun (_, t, _) -> t) edges) in
  Balanced_walk.run ~initial ~terminals ~advance
    ~accepts:((=) accepted) ~limit:10000 ~deadline:(Unix.gettimeofday () +. 5.)

let candidate edges initial accepted =
  match check edges initial accepted with
  | Balanced_walk.Candidate (_, _, trace) ->
      let steps = Balanced_walk.steps trace in
      let last = List.fold_left (fun current (before, token, after) ->
        assert (current = before);
        assert (List.mem (before, token, after) edges);
        after) initial steps in
      assert (last = accepted);
      let pending = List.fold_left (fun pending (_, token, _) ->
        match Balanced_walk.closing token with
        | Some close -> close :: pending
        | None when Balanced_walk.is_closing token ->
            (match pending with
             | close :: rest when close = token -> rest
             | _ -> failwith "candidate has misnested delimiters")
        | None -> pending) [] steps in
      assert (pending = []);
      List.map (fun (_, token, _) -> token) steps
  | _ -> failwith "balanced candidate was lost"

let () =
  (* A depth beyond the previous bounded-counter experiment's ceiling. *)
  let depth = 32 in
  let edges = List.init depth (fun i -> (i, "LPAREN", i + 1))
    @ [(depth, "A", depth + 1)]
    @ List.init depth (fun i -> (depth + 1 + i, "RPAREN", depth + 2 + i)) in
  assert (List.length (candidate edges 0 (2 * depth + 1)) = 2 * depth + 1);
  (* Recursive activation summaries must return to the root. *)
  ignore (candidate [(0,"LPAREN",1); (1,"LPAREN",1); (1,"A",2);
                     (2,"RPAREN",2); (2,"EOF",3)] 0 3);
  (* Balanced counts alone would accept this crossing of delimiter types. *)
  (match check [(0,"LPAREN",1); (1,"LBRACKET",2); (2,"RPAREN",3);
                (3,"RBRACKET",4)] 0 4 with
   | Balanced_walk.Closed _ -> ()
   | _ -> failwith "misnested history survived");
  (* A reachable accepting state inside an unclosed frame is not acceptance. *)
  (match check [(0,"LPAREN",1); (1,"A",2)] 0 2 with
   | Balanced_walk.Closed _ -> ()
   | _ -> failwith "unclosed history survived");
  (* Differential check against explicit bounded paths in random finite
     graphs. Every reported candidate is also replayed edge by edge above. *)
  let random = Random.State.make [|1031|] in
  let labels = [|"LPAREN"; "RPAREN"; "LBRACKET"; "RBRACKET"; "A"|] in
  for _ = 1 to 250 do
    let edges = List.init 12 (fun _ ->
      (Random.State.int random 5,
       labels.(Random.State.int random (Array.length labels)),
       Random.State.int random 5)) in
    let bounded = ref false in
    let frontier = ref [(0, [])] in
    for _ = 0 to 8 do
      if List.mem (4, []) !frontier then bounded := true;
      frontier := List.concat_map (fun (node, pending) ->
        List.filter_map (fun (before, token, after) ->
          if before <> node then None else
          match Balanced_walk.closing token with
          | Some close -> Some (after, close :: pending)
          | None when Balanced_walk.is_closing token ->
              (match pending with
               | close :: rest when close = token -> Some (after, rest)
               | _ -> None)
          | None -> Some (after, pending)) edges) !frontier
        |> List.sort_uniq compare
    done;
    match check edges 0 4 with
    | Balanced_walk.Closed _ -> assert (not !bounded)
    | Balanced_walk.Candidate _ -> ignore (candidate edges 0 4)
    | _ -> failwith "small finite graph exceeded its proof budget"
  done
