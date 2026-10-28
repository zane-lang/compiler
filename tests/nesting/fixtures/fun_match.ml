(* An anonymous `fun x -> match x with` is one level, and so is an anonymous
   `function`: four of them and an `if` make five. *)
let walk xss =
  List.iter
    (fun xs ->
      match xs with
      | [] -> ()
      | _ ->
          List.iter
            (function
              | [] -> ()
              | ys ->
                  List.iter
                    (fun y ->
                      match y with
                      | None -> ()
                      | Some zs ->
                          List.iter (fun z -> match z with 0 -> () | _ -> if z > 1 then print_int z) zs)
                    ys)
            xs)
    xss
