(* Per-verb summaries computed to a fixed point. Verbs may call each other in
   a cycle, so an analysis that summarises what a verb does for its callers
   walks every body until no summary grows, then walks them once more to
   report. One [t] is made per run, so a run starts from nothing. *)

type 'a t = {
  summaries : (int, 'a) Hashtbl.t;
  empty : 'a;
  union : 'a -> 'a -> 'a;
  equal : 'a -> 'a -> bool;
  mutable changed : bool;
}

let create ~empty ~union ~equal =
  { summaries = Hashtbl.create 64; empty; union; equal; changed = false }

(* A verb's summary so far: [empty] until a walk of its body adds to it.
   [find_opt] tells a verb with a body, which [start] registered, from one
   without. *)
let find_opt t id = Hashtbl.find_opt t.summaries id
let find t id = Option.value ~default:t.empty (find_opt t id)
let start t id = if not (Hashtbl.mem t.summaries id) then Hashtbl.replace t.summaries id t.empty

(* Joins [s] into the verb's summary, noting whether that grew it. *)
let add t id s =
  let old = find t id in
  let now = t.union old s in
  if not (t.equal old now) then begin
    Hashtbl.replace t.summaries id now;
    t.changed <- true
  end

(* Runs [walk ~report:false] until no summary grows, then
   [walk ~report:true] once. *)
let settle t walk =
  let rec go () =
    t.changed <- false;
    walk ~report:false;
    if t.changed then go ()
  in
  go ();
  walk ~report:true
