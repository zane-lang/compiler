(* An `else if` chain is one level however many links it has: four levels
   around a chain of four `if`s make five. *)
let classify xs =
  List.iter
    (fun x ->
      match x with
      | Some n ->
          while n > 0 do
            if n = 1 then print_string "one"
            else if n = 2 then print_string "two"
            else if n = 3 then print_string "three"
            else if n = 4 then print_string "four"
            else print_string "many"
          done
      | None -> ())
    xs
