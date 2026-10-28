(* A `let`-bound value that is not a function counts as what it is: the
   `match` named `label` is the fifth level and the `if` inside it the sixth.
   A function bound by `let = function` counts its cases, so `bound`'s inner
   `try` is the sixth level too. *)
let describe args =
  List.iter
    (fun arg ->
      if arg > 0 then
        match arg with
        | _ ->
            for _ = 1 to arg do
              let label = match arg with 1 -> "one" | _ -> if arg > 2 then "many" else "two" in
              print_string label
            done)
    args

let bound = function
  | 0 -> ()
  | n -> (
      match n with
      | 1 -> ()
      | _ ->
          if n > 2 then
            List.iter (fun m -> if m > 3 then try print_int m with Exit -> ()) [ n ])
