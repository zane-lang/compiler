(* The places a program writes back into, as a file a library's build reads
   (docs/design/lowering.md §9, "Snapshots"). A program's build knows every
   place a spawned call writes back into; a library compiled for that
   program alone is given them, so its reads of every other place are plain
   loads. The library's build has the program's types only by name, so the
   file spells each place out: the innermost owner's type and the steps down
   from it, and the written value's type with every type it holds.

   The file is a header line, then one line per place, sorted and without
   repeats, so two programs that write back into the same places give the
   same bytes, which `zane` keys a dependency's object on. A line's fields
   are separated by tabs, which no type's spelling holds:

     OWNER  STEPS  HELD...

   OWNER is the owner's type, or `-` when the place is not known; STEPS the
   steps, separated by spaces, each `.member`, `case` or `elem`; and HELD
   the written value's type and each type it holds. *)

open State

let header = "zanec write-backs 1"

let step_to_string = function Member m -> "." ^ m | Case -> "case" | Elem -> "elem"

let step_of_string = function
  | "case" -> Some Case
  | "elem" -> Some Elem
  | s when String.length s > 1 && s.[0] = '.' -> Some (Member (String.sub s 1 (String.length s - 1)))
  | _ -> None

let line st (w : written) =
  let owner, steps =
    match w.place with
    | Some (o, steps) -> (Tst.Ty.to_string o, String.concat " " (List.map step_to_string steps))
    | None -> ("-", "")
  in
  String.concat "\t" (owner :: steps :: List.map Tst.Ty.to_string (Type_layout.held_types st w.of_type))

(* The file for the places [ws]. *)
let to_text st ws = String.concat "\n" (header :: List.sort_uniq compare (List.map (line st) ws)) ^ "\n"

(* The places a file holds, or [None] when it is not one. *)
let of_text text =
  let parse l =
    match String.split_on_char '\t' l with
    | "-" :: "" :: (_ :: _ as holding) -> Some { owner_place = None; holding }
    | owner :: steps :: (_ :: _ as holding) when owner <> "-" && owner <> "" -> (
        let steps = if steps = "" then [] else String.split_on_char ' ' steps in
        let parsed = List.filter_map step_of_string steps in
        if List.length parsed = List.length steps then Some { owner_place = Some (owner, parsed); holding }
        else None)
    | _ -> None
  in
  match List.filter (fun l -> l <> "") (String.split_on_char '\n' text) with
  | h :: lines when h = header ->
      let parsed = List.map parse lines in
      if List.for_all Option.is_some parsed then Some (List.filter_map Fun.id parsed) else None
  | _ -> None
