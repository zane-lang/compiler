(* Exact Dyck-language intersection with a finite transition system.

   A frame summarizes every balanced path from its entry node to an exit on
   its matching closing delimiter. Recursive calls reuse the same frame;
   neither nesting depth nor sentence length is bounded. This is pushdown
   reachability, not a bounded counter attached to one reported witness. *)

open Automaton
open Output

let delimiters =
  [ ("LPAREN", "RPAREN"); ("LBRACKET", "RBRACKET"); ("LCURLY", "RCURLY") ]

let closing token = List.assoc_opt token delimiters
let is_closing token = List.exists (fun (_, close) -> close = token) delimiters

(* Ignoring nonterminals is sound only when every production's terminal
   skeleton is balanced. Substitution then preserves the Dyck language, by
   induction over the derivation tree. Fail closed for other grammars. *)
let validate automaton =
  Hashtbl.iter
    (fun _ production ->
      let rhs = match String.split_on_char '>' production with
        | _ :: rhs -> words (String.concat ">" rhs)
        | [] -> [] in
      let pending = ref [] in
      List.iter
        (fun token ->
          if StringSet.mem token automaton.terminals then
            match closing token with
            | Some close -> pending := close :: !pending
            | None when is_closing token ->
                (match !pending with
                 | close :: rest when close = token -> pending := rest
                 | _ -> invalid_arg
                     ("--prove-balanced requires balanced production skeletons: "
                      ^ production))
            | None -> ())
        rhs;
      if !pending <> [] then invalid_arg
        ("--prove-balanced requires balanced production skeletons: " ^ production))
    automaton.production_text

type 'node trace =
  | Empty
  | Edge of 'node * string * 'node
  | Join of 'node trace * 'node trace

let join left right = match left, right with
  | Empty, trace | trace, Empty -> trace
  | _ -> Join (left, right)

let steps trace =
  let rec walk work result = match work with
    | [] -> List.rev result
    | Empty :: rest -> walk rest result
    | Edge (before, token, after) :: rest ->
        walk rest ((before, token, after) :: result)
    | Join (left, right) :: rest -> walk (left :: right :: rest) result
  in
  walk [trace] []

type 'node frame = {
  id : int;
  entry : 'node;
  closer : string option;
  reached : ('node, 'node trace) Hashtbl.t;
  exits : ('node, 'node trace) Hashtbl.t;
  callers : ((int * 'node * string), 'node caller) Hashtbl.t;
}
and 'node caller = {
  parent : 'node frame;
  prefix : 'node trace;
  opening : 'node trace;
}

type 'node result =
  | Closed of int
  | Candidate of int * 'node * 'node trace
  | Overflow of int
  | Timed_out of int

let run ~initial ~terminals ~advance ~accepts ~limit ~deadline =
  let frames = Hashtbl.create 1024 in
  let queue = Queue.create () in
  let count = ref 0 in
  let overflow = ref false in
  let candidate = ref None in
  let reserve () =
    if !count >= limit then (overflow := true; false)
    else (incr count; true)
  in
  let reach frame node trace =
    if not (Hashtbl.mem frame.reached node) && reserve () then begin
      Hashtbl.add frame.reached node trace;
      Queue.add (frame, node) queue
    end
  in
  let frame entry closer =
    match Hashtbl.find_opt frames (entry, closer) with
    | Some frame -> Some frame
    | None when reserve () ->
        let frame = {
          id = Hashtbl.length frames; entry; closer;
          reached = Hashtbl.create 8; exits = Hashtbl.create 4;
          callers = Hashtbl.create 4;
        } in
        Hashtbl.add frames (entry, closer) frame;
        reach frame entry Empty;
        Some frame
    | None -> None
  in
  let return caller exit trace =
    reach caller.parent exit (join caller.prefix (join caller.opening trace))
  in
  ignore (frame initial None);
  let started = Unix.gettimeofday () in
  let processed = ref 0 in
  while not (Queue.is_empty queue) && not !overflow && !candidate = None
        && Unix.gettimeofday () < deadline do
    let current, node = Queue.take queue in
    let prefix = Hashtbl.find current.reached node in
    incr processed;
    if !processed mod 128 = 0 && progress_due () then
      show_progress_line
        (Printf.sprintf "balanced summaries | entries %d | frames %d | queued %d | %s"
          !count (Hashtbl.length frames) (Queue.length queue)
          (elapsed_clock (Unix.gettimeofday () -. started)));
    (match current.closer with
    | None ->
        if accepts node then candidate := Some (node, prefix)
    | Some close ->
        List.iter (fun exit ->
          if not (Hashtbl.mem current.exits exit) && reserve () then begin
            let trace = join prefix (Edge (node, close, exit)) in
            Hashtbl.add current.exits exit trace;
            Hashtbl.iter (fun _ caller -> return caller exit trace) current.callers
          end)
          (advance node close));
    if !candidate = None && not !overflow then
      List.iter (fun token ->
        if not (is_closing token) then
          List.iter (fun next ->
            match closing token with
            | None -> reach current next (join prefix (Edge (node, token, next)))
            | Some close ->
                (match frame next (Some close) with
                | None -> ()
                | Some child ->
                    let key = (current.id, node, token) in
                    if not (Hashtbl.mem child.callers key) && reserve () then begin
                      let caller = {
                        parent = current; prefix;
                        opening = Edge (node, token, next);
                      } in
                      Hashtbl.add child.callers key caller;
                      Hashtbl.iter (fun exit trace -> return caller exit trace)
                        child.exits
                    end))
            (advance node token))
        terminals
  done;
  clear_progress ();
  match !candidate with
  | Some (node, trace) -> Candidate (!count, node, trace)
  | None when !overflow -> Overflow !count
  | None when not (Queue.is_empty queue) -> Timed_out !count
  | None -> Closed !count
