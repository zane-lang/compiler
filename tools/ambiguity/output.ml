(* Everything the engine shows a caller: the flushed writers, the progress
   line and its cadence, the compact number and clock formats, and the search
   progress record as it is rendered and persisted.

   Presentation only. Nothing here knows what an automaton, a stack or a proof
   is, which is what keeps the two proof algorithms free of it. *)

(* Everything this tool prints is written as it is produced, not at the end.

   A proof run is long -- an abstract phase that can hold the whole timeout,
   then a bounded search that can run for an hour -- and it is nearly always
   read through a pipe: `tools/ambiguity/cli.py` folds stderr into stdout, streams
   both to the terminal, and copies every line into the saved report. On a pipe
   OCaml block-buffers stdout, so the survey, the retirements and the line
   announcing that concretization has started all sat in a 64 KiB buffer until
   the process exited, and the report file stayed empty for the whole run it
   was meant to document. Flushing on every write costs one syscall per line,
   on output no run produces much of. *)
let printf fmt =
  Printf.ksprintf
    (fun text ->
      print_string text;
      flush stdout)
    fmt

let eprintf fmt =
  Printf.ksprintf
    (fun text ->
      prerr_string text;
      flush stderr)
    fmt

(* How progress is shown, and how often.

   On a terminal it is one line rewritten in place several times a second.
   Everywhere else there is no cursor to move back to and the stream is usually
   being saved, so the same numbers go out as ordinary lines at a much slower
   cadence. Showing nothing at all off a terminal -- which is what this used to
   do -- is what made every wrapped run silent for its entire length: the
   wrapper that streams the engine's output line by line was the one guaranteed
   never to receive a line. AMBIGUITY_PROGRESS_SECONDS sets the cadence; zero
   or less turns progress off, for a caller that wants the verdict and nothing
   else. *)
let progress_on_terminal = Unix.isatty Unix.stderr

(* Read on first use rather than at module initialisation, so a malformed value
   is reported by the same handler that reports every other bad setting --
   "error: ..." and status 2 -- instead of an uncaught exception printed before
   [main] has begun. *)
let progress_interval =
  lazy
    (match Sys.getenv_opt "AMBIGUITY_PROGRESS_SECONDS" with
    | None | Some "" -> if progress_on_terminal then 0.2 else 10.
    | Some value -> (
        match float_of_string_opt value with
        (* [float_of_string_opt] accepts "nan" and "infinity", and neither is a
           cadence. Both would be taken for a setting and then silently show no
           progress at all: every comparison against nan is false, so it reads
           as switched off, and nothing is ever as old as infinity, so a run
           reports progress as enabled and then never prints a line.
           [classify_float] rather than [Float.is_finite] because it is in
           every version of the stdlib this builds under. *)
        | Some seconds when classify_float seconds <> FP_nan
                           && classify_float seconds <> FP_infinite ->
            seconds
        | _ ->
            invalid_arg "AMBIGUITY_PROGRESS_SECONDS must be a finite number"))

let progress_is_visible () = Lazy.force progress_interval > 0.

(* One clock across every phase, so that handing over from the abstract phase
   to the concretization search cannot produce two lines at once, and so a
   phase that ends quickly does not leave the next one waiting out an interval
   it never used. *)
let last_progress_render = ref 0.

let progress_due () =
  progress_is_visible ()
  && Unix.gettimeofday () -. !last_progress_render
     >= Lazy.force progress_interval

let show_progress_line text =
  if progress_is_visible () then begin
    last_progress_render := Unix.gettimeofday ();
    if progress_on_terminal then eprintf "\r\027[2K%s" text
    else eprintf "%s\n" text
  end

(* Only a terminal has a partial line to take back. Off one the progress lines
   are ordinary output and stay in the log, which is the point of them.

   Deliberately independent of the interval: this also runs from the toplevel
   error handler, and a malformed AMBIGUITY_PROGRESS_SECONDS is one of the
   errors that gets it there. Reading the setting here would raise a second
   time, out of the handler, and turn a reported error into an uncaught
   exception. *)
let clear_progress () = if progress_on_terminal then eprintf "\r\027[2K"

let compact_number value =
  let value = float_of_int value in
  if value >= 1_000_000_000. then Printf.sprintf "%.1fB" (value /. 1_000_000_000.)
  else if value >= 1_000_000. then Printf.sprintf "%.1fM" (value /. 1_000_000.)
  else if value >= 1_000. then Printf.sprintf "%.1fk" (value /. 1_000.)
  else Printf.sprintf "%.0f" value

let elapsed_clock seconds =
  let seconds = int_of_float (max 0. seconds) in
  Printf.sprintf "%02d:%02d" (seconds / 60) (seconds mod 60)

(* What a search worker reports about itself, and what a resumed run reads
   back. The searches fill it; this module is where it is turned into a line
   and where it is written to and read from disk. *)
type search_progress = {
  depth : int;
  ambiguities : ((int * string) list * int) list;
  explored : int;
  unique : int;
  rss_bytes : float;
}

let memory_bar used budget =
  let width = 12 in
  let ratio = if budget <= 0. then 0. else min 1. (used /. budget) in
  let filled = int_of_float (floor ((ratio *. float_of_int width) +. 0.5)) in
  String.make filled '#' ^ String.make (width - filled) '-'

let render_progress ~started ~max_tokens ~memory_budget
    (entries : (bool * search_progress) list) =
  if entries <> [] && progress_due () then begin
    let has_active = List.exists fst entries in
    let depth =
      List.fold_left
        (fun current
             (is_active, (progress : search_progress)) ->
          if has_active && not is_active then current
          else max current progress.depth)
        0 entries
    in
    let profiles = Hashtbl.create 64 in
    let explored = ref 0 in
    let unique = ref 0 in
    let rss_bytes = ref 0. in
    List.iter
      (fun (_, (progress : search_progress)) ->
        explored := !explored + progress.explored;
        unique := !unique + progress.unique;
        rss_bytes := !rss_bytes +. progress.rss_bytes;
        List.iter
          (fun (profile, witness_depth) ->
            match Hashtbl.find_opt profiles profile with
            | Some previous when previous <= witness_depth -> ()
            | _ -> Hashtbl.replace profiles profile witness_depth)
          progress.ambiguities)
      entries;
    let at_depth =
      Hashtbl.fold
        (fun _ witness_depth count ->
          if witness_depth = depth then count + 1 else count)
        profiles 0
    in
    let elapsed = Unix.gettimeofday () -. started in
    show_progress_line
      (Printf.sprintf
         "● search %d/%d | amb %d | explored %s | unique %s | RAM [%s] \
          %.1f/%.1fG | %s"
         depth max_tokens at_depth (compact_number !explored)
         (compact_number !unique)
         (memory_bar !rss_bytes memory_budget)
         (!rss_bytes /. 1024. /. 1024. /. 1024.)
         (memory_budget /. 1024. /. 1024. /. 1024.)
         (elapsed_clock elapsed))
  end

let write_progress path (progress : search_progress) =
  let temporary = path ^ ".new" in
  let channel = open_out_bin temporary in
  Marshal.to_channel channel progress [];
  close_out channel;
  Sys.rename temporary path

let read_progress path : search_progress option =
  try
    let channel = open_in_bin path in
    Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
        Some (Marshal.from_channel channel : search_progress))
  with Sys_error _ | End_of_file | Failure _ -> None
