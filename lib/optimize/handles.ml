(* Foreign handles at the end of their lives in a fold (docs/design/ffi.md
   F12, F18): a drain ending the slots of a scope that hold them, and an
   overwrite replacing them. Each ends a handle by running its free thunk,
   or, where a settled overwrite replaces it, its set thunk, and both run
   by descending stamp, the order the running program runs them in. A
   handle is ended once: its pointer is nulled and its stamp made 0, as
   the runtime's end leaves it. *)

open Cgt.Nodes
open Value

(* A thunk to run, by the stamp that orders it, with its arguments, each
   a C object's pointer. *)
type action = { stamp : int64; thunk : string; args : v list }

let stamp_of v at = match read_path v (stamp_path at) with VInt s -> s | _ -> 0L

(* Every live handle in [v], a value of [t] laid out as [layout], ended:
   the value with each one nulled, and the free thunks to run. A boxed
   payload's handles and a list element's are ended in their cells. *)
let rec ended layouts layout t v acc =
  List.fold_left (fun (v, acc) pa -> ended_at layouts t pa v acc) (own v, acc) (positions layouts layout t v)

(* The handles at one position of [v] ended. *)
and ended_at layouts t ((p : Layout.position), at) v acc =
      match (p.Layout.kind, read_path v at) with
      | Layout.Foreign _, VNull -> (v, acc)
      | Layout.Foreign { free; _ }, ptr -> (vacate_handle v at, { stamp = stamp_of v at; thunk = free; args = [ ptr ] } :: acc)
      | Layout.Box { payload; _ }, VPtr b ->
          let inner, acc = ended layouts payload b.cell.ty b.cell.value acc in
          b.cell.value <- inner;
          (v, acc)
      | Layout.List { elements; _ }, VList l ->
          let acc = ref acc in
          for i = 0 to l.count - 1 do
            let c = l.items.(i) in
            let inner, a = ended layouts elements c.ty c.value !acc in
            c.value <- inner;
            acc := a
          done;
          (v, !acc)
      | Layout.Array { elements; _ }, _ ->
          let e, a = elements_at t v at in
          let acc = ref acc in
          let a =
            Array.map
              (fun x ->
                let x, more = ended layouts elements e x !acc in
                acc := more;
                x)
              a
          in
          (set_path v at (VRecord a), !acc)
      | _ -> (v, acc)

(* A settled overwrite of [old] by [incoming] (spec ffi.md §4.3): each
   handle of [old] that is in no variant's payload and no list keeps its
   place, its object set from the incoming one's by its set thunk, and the
   incoming one is consumed; every other handle of [old] is ended. Gives
   the incoming value with those places kept, and the thunks to run. *)
let rec settled layouts layout t old incoming acc =
  let theirs = positions layouts layout t incoming in
  List.fold_left
    (fun (incoming, acc) ((p : Layout.position), at) ->
      let both = List.assoc_opt p theirs = Some at in
      match (p.Layout.kind, read_path old at) with
      | Layout.Foreign { set = Some set; _ }, ptr when both && p.Layout.tags = [] && ptr <> VNull ->
          let kept = set_path (set_path incoming at ptr) (stamp_path at) (VInt (stamp_of old at)) in
          (kept, { stamp = stamp_of old at; thunk = set; args = [ ptr; read_path incoming at ] } :: acc)
      | Layout.Box { payload; _ }, VPtr b when both -> (
          match read_path incoming at with
          | VPtr n ->
              let inner, acc = settled layouts payload b.cell.ty b.cell.value n.cell.value acc in
              n.cell.value <- inner;
              (incoming, acc)
          | _ -> (incoming, acc))
      | Layout.Array { elements; _ }, _ when both ->
          let e, olds = elements_at t old at and _, news = elements_at t incoming at in
          let acc = ref acc in
          let news =
            Array.mapi
              (fun i n ->
                let n, more = settled layouts elements e olds.(i) n !acc in
                acc := more;
                n)
              news
          in
          (set_path incoming at (VRecord news), !acc)
      | _ ->
          (* Anything else of [old] there ends, as an overwrite ends it. *)
          let _, acc = ended_at layouts t (p, at) old acc in
          (incoming, acc))
    (own incoming, acc)
    (positions layouts layout t old)

(* [actions] run by descending stamp. *)
let run_all run_thunk actions =
  List.iter (fun a -> run_thunk a.thunk a.args) (List.stable_sort (fun a b -> Int64.compare b.stamp a.stamp) actions)
