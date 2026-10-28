(* Five levels, the most the limit allows: fun > if > match > while > for. *)
let deepest xs =
  List.iter
    (fun x ->
      if x > 0 then
        match x with
        | 1 -> ( try print_int x with Exit -> ())
        | _ ->
            while x > 1 do
              for _ = 1 to x do
                print_int x
              done
            done)
    xs
