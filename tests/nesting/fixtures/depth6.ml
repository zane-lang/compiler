(* Six levels: the `if` inside the `for` is the site, reported once although
   the `match` inside it nests deeper still. *)
let too_deep xs =
  List.iter
    (fun x ->
      if x > 0 then
        match x with
        | 1 -> ( try print_int x with Exit -> ())
        | _ ->
            while x > 1 do
              for _ = 1 to x do
                if x = 2 then match x with _ -> print_int x
              done
            done)
    xs
