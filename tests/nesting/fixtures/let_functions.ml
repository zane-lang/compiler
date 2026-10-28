(* A function bound by `let`, at top level, locally or in a `let module`,
   costs no level of its own; its body still counts from where it is bound.
   Each local function here reaches five, and would reach six if its name
   cost one. *)
let outer x =
  match x with
  | Some y ->
      if y > 0 then
        let rec step z =
          match z with 0 -> () | n -> if n > 1 then while false do step (n - 2) done
        in
        let module M = struct
          let pick n = match n with 0 -> if n = 0 then ( try step n with Exit -> ()) | _ -> ()
        end in
        let last : int -> unit = fun n -> if n > 0 then while false do for _ = 1 to n do () done done in
        M.pick y;
        last y
  | None -> ()
