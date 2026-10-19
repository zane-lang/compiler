(* Per-verb summaries computed to a fixed point. Verbs may call each other in
   a cycle, so an analysis that summarises what a verb does for its callers
   walks the bodies until no summary grows, then walks every body once more
   to report. One [t] is made per run, so a run starts from nothing.

   The walks go by a worklist. Every body is walked once; a walk reads other
   verbs' summaries through [read], which notes the body as one of their
   readers; and when [add] grows a summary, only its readers are walked
   again. A chain of calls listed callee last so settles in a walk per body
   and one more per caller, where walking every body until nothing grows
   would take a round per link. *)

type 'a t = {
  summaries : (int, 'a) Hashtbl.t;
  empty : 'a;
  union : 'a -> 'a -> 'a;
  equal : 'a -> 'a -> bool;
  (* By summary, the bodies whose walk read it, as positions in the list
     [settle] was given. *)
  readers : (int, (int, unit) Hashtbl.t) Hashtbl.t;
  (* The body being walked, while [settle] walks one to a fixed point. *)
  mutable walking : int option;
  (* The bodies waiting to be walked again, and which they are. *)
  queue : int Queue.t;
  queued : (int, unit) Hashtbl.t;
  (* How many bodies [settle] has walked before reporting: a hook for the
     test that holds the walks to linear. *)
  mutable walks : int;
}

let create ~empty ~union ~equal =
  {
    summaries = Hashtbl.create 64;
    empty;
    union;
    equal;
    readers = Hashtbl.create 64;
    walking = None;
    queue = Queue.create ();
    queued = Hashtbl.create 64;
    walks = 0;
  }

let enqueue t body =
  if not (Hashtbl.mem t.queued body) then begin
    Hashtbl.replace t.queued body ();
    Queue.add body t.queue
  end

(* A verb's summary so far: [empty] until a walk of its body adds to it.
   [read_opt] tells a verb with a body, which [start] registered, from one
   without. Either notes the body being walked as a reader of the verb's
   summary, so that the body is walked again when the summary grows. *)
let read_opt t id =
  (match t.walking with
  | Some body ->
      let rs =
        match Hashtbl.find_opt t.readers id with
        | Some rs -> rs
        | None ->
            let rs = Hashtbl.create 4 in
            Hashtbl.replace t.readers id rs;
            rs
      in
      Hashtbl.replace rs body ()
  | None -> ());
  Hashtbl.find_opt t.summaries id

let read t id = Option.value ~default:t.empty (read_opt t id)
let start t id = if not (Hashtbl.mem t.summaries id) then Hashtbl.replace t.summaries id t.empty

(* Joins [s] into the verb's summary; when that grows it, the bodies that
   read it are walked again. *)
let add t id s =
  let old = Option.value ~default:t.empty (Hashtbl.find_opt t.summaries id) in
  let now = t.union old s in
  if not (t.equal old now) then begin
    Hashtbl.replace t.summaries id now;
    match Hashtbl.find_opt t.readers id with
    | Some rs -> Hashtbl.iter (fun body () -> enqueue t body) rs
    | None -> ()
  end

(* Runs [walk ~report:false] on each body, and again on each body that read
   a summary after it grew, until none grows; then [walk ~report:true] on
   every body once, in order. *)
let settle t bodies walk =
  let bodies = Array.of_list bodies in
  Array.iteri (fun i _ -> enqueue t i) bodies;
  while not (Queue.is_empty t.queue) do
    let i = Queue.pop t.queue in
    Hashtbl.remove t.queued i;
    t.walking <- Some i;
    t.walks <- t.walks + 1;
    walk ~report:false bodies.(i)
  done;
  t.walking <- None;
  Array.iter (walk ~report:true) bodies

let walks t = t.walks
