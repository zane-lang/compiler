(* An anonymous `fun x -> match x with` is one level, and so is an anonymous
   `function`. The fixture nests on purpose: four such closures, one inside
   the next, and the `if` in the innermost make five, the most the limit
   allows. Counting a `fun` and its `match` as two would make it eight. *)
let print_large_cells sheets =
  (* Level 1: `fun sheet -> match sheet with`. *)
  List.iter
    (fun sheet ->
      match sheet with
      | [] -> ()
      | rows ->
          (* Level 2: `function`. *)
          List.iter
            (function
              | [] -> ()
              | cells ->
                  (* Level 3: `fun cell -> match cell with`. *)
                  List.iter
                    (fun cell ->
                      match cell with
                      | None -> ()
                      | Some digits ->
                          (* Levels 4 and 5: `fun d -> match d with`, then `if`. *)
                          List.iter
                            (fun d -> match d with 0 -> () | _ -> if d > 1 then print_int d)
                            digits)
                    cells)
            rows)
    sheets
