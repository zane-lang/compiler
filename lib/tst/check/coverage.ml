(* Whether a match's arms cover every combination of its scrutinees' cases
   (adt.md §5.2, §5.6). An arm covers exactly one combination, so what is
   missing is counted rather than listed: the combinations number the
   product of the case counts, which can be far too many to write out, and
   the arms cover as many as they have distinct valid keys. Only the first
   three missing ones are found, by walking the combinations in order and
   skipping the covered ones, which takes at most as many steps as there
   are arms, plus three. *)

open Env

(* The error for a match whose scrutinees have [cases], one list per
   scrutinee, and whose arms cover the [covered] keys, each a combination's
   cases joined with commas; [None] when every combination is covered. *)
let missing (all_cases : string list list) (covered : (string, _) Hashtbl.t) =
  let total, saturated =
    List.fold_left
      (fun (n, sat) cases ->
        let k = List.length cases in
        if n = 0 || k = 0 then (0, false)
        else if sat || n > max_int / k then (max_int, true)
        else (n * k, false))
      (1, false) all_cases
  in
  let valid key =
    let cases = String.split_on_char ',' key in
    List.length cases = List.length all_cases && List.for_all2 List.mem cases all_cases
  in
  let covered_count = Hashtbl.fold (fun key _ n -> if valid key then n + 1 else n) covered 0 in
  let missing = total - covered_count in
  if missing <= 0 then None
  else
    let rec combos = function
      | [] -> Seq.return []
      | cases :: rest ->
          let tails = combos rest in
          Seq.flat_map (fun c -> Seq.map (fun tail -> c :: tail) tails) (List.to_seq cases)
    in
    let shown =
      combos all_cases
      |> Seq.filter (fun combo -> not (Hashtbl.mem covered (String.concat "," combo)))
      |> Seq.take 3 |> List.of_seq
    in
    let rest = missing - List.length shown in
    Some
      (Printf.sprintf "the match does not cover %s%s; every case needs an arm, and there is no default"
         (String.concat ", " (List.map (fun c -> quote (String.concat ", " c)) shown))
         (if saturated then Printf.sprintf " (and more than %d more)" rest
          else if rest > 0 then Printf.sprintf " (and %d more)" rest
          else ""))
