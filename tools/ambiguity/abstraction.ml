(* How concrete stacks project into the finite proof state space.

   The abstract stack keeps a bounded suffix plus enough residue to tell apart
   the histories the suffix has forgotten. Everything here is about that
   projection: the moves it admits, the joint outcomes of two runs over it, and
   the diagnostics that say which imprecision let a pair through. *)

open Output
open Automaton
open Recognizer

(* ----- Conservative unambiguity prover -----

   Abstract every GLR stack to its top-K states; a suffix shorter than K means
   the states below are unknown, which over-approximates every continuation,
   including the true stack bottom. Reductions that pop into the unknown part
   re-enter through every goto edge on the reduced nonterminal. The abstract
   configuration space is finite, so a pair search over runs that consume the
   same input terminates. Every concrete ambiguous sentence projects onto an
   abstract pair of runs that diverge in their actions and both accept, so if
   no such abstract pair exists, the grammar is unambiguous. The converse does
   not hold: an abstract diverging pair may be spurious, which is why a found
   candidate only downgrades the verdict to "not proven". *)

let rec drop_states count list =
  if count = 0 then list
  else match list with [] -> [] | _ :: tail -> drop_states (count - 1) tail

let truncate_suffix limit list =
  let rec take count = function
    | [] -> []
    | _ when count = 0 -> []
    | head :: tail -> head :: take (count - 1) tail
  in
  take limit list

(* How much stack to retain, as a property of the state on top rather than of
   the whole run. A uniform level pays for depth in every corner of the
   automaton to buy it in the one corner that needs it, and on a grammar this
   size that is the difference between a proof that finishes and one that does
   not. Keeping the depth per state lets a refinement deepen only the stacks
   that reach a blind spot.

   Soundness does not depend on the assignment. Truncation is the only thing
   that ever shortens a suffix and nothing ever invents one, so every concrete
   stack still projects onto the abstract stack its run carries, whatever
   depths are in force; a shallower entry admits more moves and a deeper one
   fewer, and only the second direction could lose a real parse. That is why
   refinement can be driven by a heuristic without putting the verdict at
   risk. *)
type precision = int array

(* An abstract stack: the suffix the abstraction retains, and how tall the
   real stack under it is.

   The suffix says which states are on top. It never says where the stack
   ends, and that is a separate fact with its own consequences: a reduction
   can only fire if there are entries for it to pop and a state left
   underneath to goto from. Without the height the abstraction has to assume
   there is always more stack below, so it admits reductions no parse could
   make and then guesses where they landed - and the guess is what keeps
   spurious pairs alive.

   The height is exact while it stays under [height_ceiling] and saturates
   there. Saturation is the safe direction: a stack that might be taller than
   any reduction is wide is a stack no reduction can be ruled out on, which is
   what the abstraction assumed everywhere before. The ceiling only has to
   clear the widest reduction in the grammar, because past that the answer to
   "are there enough entries" is yes regardless. *)
(* A small fingerprint of the terminal-labelled edges in the whole viable
   stack. It complements the exact suffix: when a reduction pops beyond that
   suffix, its goto source is guessed, but the guess still has to occur on an
   automaton path with the terminal residue the concrete stack would have.

   XOR makes shift and reduction updates exact: a shift adds its terminal and
   a reduction removes the direct terminals in its right-hand side. Collisions
   only merge concrete stacks and therefore admit extra moves; they cannot
   remove one. Keeping the residue in [stack] also means deduplication never
   substitutes the fingerprint of one path for another. *)
let residue_count = 1024

let terminal_residue token =
  let value = Hashtbl.hash token land (residue_count - 1) in
  if value = 0 then 1 else value

type stack = { suffix : int list; height : int; residue : int }

let production_residue automaton prod =
  let text = production_name automaton prod in
  match String.split_on_char '>' text with
  | _lhs :: rest ->
      List.fold_left
        (fun residue symbol ->
          if StringSet.mem symbol automaton.terminals then
            residue lxor terminal_residue symbol
          else residue)
        0 (words (String.concat ">" rest))
  | [] -> 0

let production_residues automaton =
  Array.init (Hashtbl.length automaton.production_text)
    (production_residue automaton)

(* Residues of terminal symbols along every automaton path from the initial
   state. Every concrete LR stack is such a path. This regular over-approximation
   cheaply rules out a guessed reduction base whose outstanding terminals could
   not occur below that state; hash collisions only admit extra paths. *)
let reachable_stack_residues automaton =
  let reachable =
    Array.init (Array.length automaton.states) (fun _ ->
        Array.make residue_count false)
  in
  let queue = Queue.create () in
  let push state residue =
    if not reachable.(state).(residue) then begin
      reachable.(state).(residue) <- true;
      Queue.add (state, residue) queue
    end
  in
  push 0 0;
  while not (Queue.is_empty queue) do
    let state, residue = Queue.take queue in
    Hashtbl.iter
      (fun symbol target ->
        let next =
          if StringSet.mem symbol automaton.terminals then
            residue lxor terminal_residue symbol
          else residue
        in
        push target next)
      automaton.states.(state).transitions
  done;
  reachable

(* Every stack the abstraction can still tell apart at this depth.

   A stack can be shorter than its state is entitled to keep, and the shortest
   ones come from the abstraction itself: a reduction that pops past what is
   retained rebuilds the stack as a goto target on a guessed source, two
   entries and nothing under them. Walking downward from the deepest entry
   recovers context wherever the automaton leaves no choice about what sits
   below.

   It stops at the first entry with more than one possible predecessor.
   Descending through a branch means carrying one stack per predecessor, and
   two stacks that differ only in how a split resolved are different possible
   worlds rather than two parses of one sentence, so the joint walk pairs each
   side's variants against the other's across every pair of distinct
   productions: the cost of a split is quadratic in it, while the depth it buys
   is not. That depth is also no longer worth buying here. A reduction chain
   keeps the entries its own pops leave behind, so the context a split would
   recover is context the chain never dropped, and on the real grammar
   descending through branches changes the explored pair count by well under a
   percent while making a refined run's stacks fan out far enough to exhaust
   memory. [AMBIGUITY_DESCENT_LIMIT] raises the bound for a grammar that wants
   the split; the descent then stops at whatever depth it has reached when the
   next level would cross it, and keeps the stacks it has.

   Most of the descent is free either way: the automaton forces the entry below
   for the large majority of its states, and a forced level adds depth without
   adding a variant, so stopping at the first branch still reaches a long way
   down a chain that never branches.

   The height steers the walk as well as ending it. Every stack starts at the
   initial state, so when the height is exact it says precisely how many
   entries are still missing, and a candidate for one of them is only real if
   the bottom is still that many predecessor steps below it. Candidates that
   cannot get there are dropped before they are ever carried, which is what
   makes the walk forced as often as it is: a chain that has to land on the
   initial state in three more entries has far fewer ways to do it than the
   automaton's shape alone suggests.

   Reaching the bottom is what the walk is for. A stack that descends to the
   initial state has nothing below it, and a reduction wider than it can pop is
   then not a move any parse can make - a conclusion the abstraction cannot
   draw while the stack is stranded above a branch. *)
(* Forced rather than read at module initialization: a top-level binding is
   evaluated before [main] is entered, so a rejected value would escape the
   handler around it and print a bare [Fatal error] instead of the tool's own
   [error:] line - and would skip [clear_progress]. *)
let descent_limit =
  lazy
    (match Sys.getenv_opt "AMBIGUITY_DESCENT_LIMIT" with
     | None | Some "" -> 1
     | Some value -> (
         match int_of_string_opt value with
         | Some chosen when chosen >= 1 -> chosen
         | _ -> invalid_arg "AMBIGUITY_DESCENT_LIMIT must be a positive integer"))

let cap_variants preds below (precision : precision) keep ceiling height
    ?(residue = 0) states =
  match states with
  | [] -> [ { suffix = []; height; residue } ]
  | top :: _ ->
      (* The suffix can never be longer than the stack it is a suffix of, so a
         known height bounds the retained depth as surely as the precision
         does, and a suffix that reaches the height has reached the bottom. *)
      (* [keep] is a floor the caller has already earned: entries this stack
         is demonstrably carrying, which cutting would only hand back to the
         descent to invent - through every predecessor the automaton allows
         rather than the one that was really there. It can never exceed the
         height, since it counts entries of a stack that tall. *)
      let limit =
        max keep
          (if height >= ceiling then precision.(top)
           else min precision.(top) height)
      in
      let kept = truncate_suffix limit states in
      (* Descent reveals entries that were already in the whole viable stack;
         it does not push them. Their terminal-labelled edges are therefore
         already included in [residue], even when the retained suffix had
         hidden them, so reconstruction preserves the residue unchanged. *)
      let wrap suffix = { suffix; height; residue } in
      (match List.rev kept with
      | [] -> [ wrap kept ]
      | deepest :: _ as reversed ->
          let finished = ref [] in
          let frontier = ref [ (reversed, List.length kept, deepest) ] in
          let stop = ref false in
          while (not !stop) && !frontier <> [] do
            let growing = ref [] in
            let held = ref [] in
            List.iter
              (fun ((below_first, length, deepest) as variant) ->
                if length >= limit then finished := below_first :: !finished
                else
                  let sources = preds.(deepest) in
                  if IntSet.is_empty sources then
                    finished := below_first :: !finished
                  else begin
                    held := variant :: !held;
                    IntSet.iter
                      (fun source ->
                        (* When the height is exact it says how many entries
                           are still missing, and every stack bottoms out at
                           the initial state, so a candidate that cannot reach
                           it in exactly that many more steps is not one. *)
                        if
                          height >= ceiling
                          || IntSet.mem 0 (below source (height - length - 1))
                        then
                          growing :=
                            (source :: below_first, length + 1, source)
                            :: !growing)
                      sources
                  end)
              !frontier;
            if
              List.length !growing + List.length !finished
              > Lazy.force descent_limit
            then begin
              (* One level too far. Keep every variant at the depth already
                 reached rather than the level that crossed the bound. *)
              List.iter
                (fun (below_first, _, _) -> finished := below_first :: !finished)
                !held;
              stop := true
            end
            else frontier := !growing
          done;
          List.rev_map (fun below_first -> wrap (List.rev below_first)) !finished)

let goto_edges automaton =
  let table = Hashtbl.create 256 in
  Array.iteri
    (fun source state ->
      Hashtbl.iter
        (fun symbol target ->
          if not (StringSet.mem symbol automaton.terminals) then
            Hashtbl.replace table symbol
              ((source, target)
              :: Option.value (Hashtbl.find_opt table symbol) ~default:[]))
        state.transitions)
    automaton.states;
  table

(* The states that can sit directly below a given state on a parser stack:
   [p] is a predecessor of [s] exactly when some grammar symbol takes [p] to
   [s]. Every abstract suffix is a chain of adjacent states — each one is
   pushed onto the one below it by a shift or a goto, and truncation only
   drops entries from the bottom — so the state a suffix hides beneath its
   deepest entry is always one of that entry's predecessors. *)
let predecessors automaton =
  let table = Array.make (Array.length automaton.states) IntSet.empty in
  Array.iteri
    (fun source state ->
      Hashtbl.iter
        (fun _ target -> table.(target) <- IntSet.add source table.(target))
        state.transitions)
    automaton.states;
  table

(* The states that can sit [steps] entries below [state] on a parser stack.
   One step is [predecessors]; further steps compose it, because a stack is a
   chain of adjacent states and each entry is pushed onto the one below by a
   shift or a goto.

   This is what a reduction popping past the retained stack lands on. Popping
   [width] entries off a suffix that only knows [depth] of them leaves the
   parser on the state [width - depth + 1] entries below the deepest one
   retained, so that is the set the goto source has to come from - never
   "anywhere", which is what the abstraction used to assume once the pop went
   further than one entry past the suffix. The set widens quickly with the
   number of steps and often saturates, but it starts out small, and it is
   empty exactly when the suffix reaches the bottom of the stack: nothing sits
   below the initial state, so a reduction that would pop past it is not a move
   any parse can make.

   Memoized because the same (state, steps) pair is asked for by every stack
   that ends there, and both arguments are small. *)
let below_steps preds =
  let cache = Hashtbl.create 1_024 in
  let rec walk state steps =
    if steps <= 0 then IntSet.singleton state
    else
      match Hashtbl.find_opt cache (state, steps) with
      | Some states -> states
      | None ->
          let nearer = walk state (steps - 1) in
          let states =
            IntSet.fold
              (fun state below -> IntSet.union below preds.(state))
              nearer IntSet.empty
          in
          Hashtbl.add cache (state, steps) states;
          states
  in
  walk

(* Deepen [state] to [depth].

   The request names one state, and one state is all this raises. That was not
   always enough: a suffix grew one entry at a time under the cap of whatever
   ended up on top, so a stack could only arrive at [state] holding [depth]
   entries if every state that could sit below it had been retaining
   [depth - 1] all along, and refinement had to walk a backward cone of
   predecessors to arrange it. The cone was the entire cost of a refinement,
   and its radius was the request: a radius-eleven cone reaches every state of
   a dense automaton at a depth close to the request, which is how a refinement
   aimed at four states ended up paying for the whole grammar and exhausting
   memory.

   Two things removed the need for it. A reduction chain keeps the entries its
   own pops leave behind, so depth survives a chain instead of being re-capped
   at every step; and where a stack does arrive short, the rebuilding descent
   walks it back down through the entries the automaton forces. Depth is
   therefore a property of the state on top and nothing else, and it can be
   granted where it is wanted without being bought everywhere behind it. *)
let deepen (precision : precision) state depth =
  if depth > precision.(state) then precision.(state) <- depth

let rec last_state = function
  | [] -> invalid_arg "last_state: empty suffix"
  | [ state ] -> state
  | _ :: tail -> last_state tail

(* One micro-step of a single run while consuming a token: apply one
   reduction, or terminate the chain by shifting the token (accepting, when
   the token is "#"). *)
(* How many moves the height test refused during the last abstract run, and how
   far the height was counted before it stopped deciding anything.

   Held beside the proof rather than carried through [prove_result], because
   every outcome wants them and none of them is a verdict. A test that silently
   removes moves is the same trap as a ceiling that silently clamps a request:
   the run looks like it explored a space it did not, and nothing in the output
   says which. Refinement re-runs the proof, so these describe its final round.
*)
let refused_stacks = ref 0
let refused_residues = ref 0
let tracked_height = ref 0

type side_move =
  | Reduce of int * stack (* production id, the stack afterwards *)
  | Terminate of stack (* the stack after the shift, or at acceptance *)

let side_moves automaton gotos below preds reachable reachable_height prod_residues
    (precision : precision) ceiling reduction_cache cache stack token =
  match Hashtbl.find_opt cache (stack, token) with
  | Some moves -> moves
  | None ->
      let { suffix; height; residue } = stack in
      let moves = ref [] in
      let depth = List.length suffix in
      let raise_height h = min ceiling (h + 1) in
      let residue_fits height state residue =
        if reachable.(state).(residue)
           && (height >= ceiling
               || Bytes.get reachable_height.(height).(state) residue = '\001')
        then true
        else begin
          incr refused_residues;
          false
        end
      in
      (* A stack too short to be carrying the state the move puts on top of it.
         The goto source of an imprecise reduction is guessed from the
         automaton's shape, which admits states that need a taller stack than
         this run has built; a state no path reaches at all needs more than any
         run can build. While the height is exact this rules the move out. *)
      let fits height top =
        let needed = automaton.min_height.(top) in
        if needed = max_int then begin
          incr refused_stacks;
          false
        end
        else if height >= ceiling || height >= needed then true
        else begin
          incr refused_stacks;
          false
        end
      in
      (match suffix with
      | [] -> ()
      | top :: _ ->
          let state = automaton.states.(top) in
          if token = "#" then begin
            if StringSet.mem "#" state.accepts && residue = 0 then
              moves := Terminate stack :: !moves
          end
          else
            Option.iter
              (fun target ->
                let shifted_residue = residue lxor terminal_residue token in
                if fits (raise_height height) target
                   && residue_fits (raise_height height) target shifted_residue
                then
                  moves :=
                    List.rev_append
                      (List.rev_map
                         (fun variant -> Terminate variant)
                         (cap_variants preds below precision 0 ceiling
                            (raise_height height)
                            ~residue:shifted_residue
                            (target :: suffix)))
                      !moves)
              (Hashtbl.find_opt state.transitions token);
          List.iter
            (fun reduction ->
              match Hashtbl.find_opt reduction_cache (stack, reduction.prod) with
              | Some reduced -> moves := List.rev_append reduced !moves
              | None ->
              let previous = !moves in
              moves := [];
              (
              (* A reduction pops [width] entries and leaves the parser on the
                 state below the last of them, so a stack of exactly that many
                 entries has nothing left to goto from. While the height is
                 exact this rules the move out outright, which is the whole
                 point of carrying it: the abstraction used to assume more
                 stack below and guess where the pop landed. *)
              if height < ceiling && reduction.width >= height then ()
              else
                (* A saturated height is not a number, it is the absence of
                   one: subtracting a width from it would manufacture an exact
                   height smaller than the truth, and an under-counted height
                   rules out reductions a real parse can make. So it stays
                   saturated, which is the direction that only ever admits more
                   moves. *)
                let after =
                  if height >= ceiling then ceiling
                  else min ceiling (height - reduction.width + 1)
                in
                let reduced_residue =
                  residue lxor prod_residues.(reduction.prod)
                in
                (* What is left after the pop is kept whole rather than cut
                   back to what the state on top is granted. A reduction chain
                   fires several times before it shifts, and re-truncating at
                   every step throws away entries the chain was demonstrably
                   holding a moment ago, only for the descent to invent them
                   back through every predecessor the automaton allows. That is
                   how a chain can walk to acceptance with every one of its
                   gotos exact and every stack it stood on made up. Keeping
                   them costs nothing that lasts: a pop never leaves more than
                   it was given, and the shift at the end of the chain cuts the
                   stack back to the retained depth before it becomes a node
                   the search stores. *)
                if reduction.width < depth then
                  match drop_states reduction.width suffix with
                  | [] -> assert false
                  | base :: _ as remaining ->
                      Option.iter
                        (fun target ->
                          if fits after target
                             && residue_fits after target reduced_residue
                          then
                            moves :=
                              List.rev_append
                                (List.rev_map
                                   (fun variant ->
                                     Reduce (reduction.prod, variant))
                                   (cap_variants preds below precision
                                      (depth - reduction.width + 1) ceiling
                                      after ~residue:reduced_residue
                                      (target :: remaining)))
                                !moves)
                        (Hashtbl.find_opt
                           automaton.states.(base).transitions reduction.lhs)
                else
                  (* The reduction pops into the unknown part of the stack; the
                     goto source is the state left on top afterwards, which sits
                     one entry below the last one popped. Counting from the
                     deepest entry the suffix does know, that is
                     [width - depth + 1] entries further down, and the states
                     that can be there are exactly the ones that many predecessor
                     steps away. Popping exactly the suffix is the one-step case
                     of the same rule. *)
                  let deepest = last_state suffix in
                  let sources = below deepest (reduction.width - depth + 1) in
                  (* The goto source does not merely sit that far below the
                     suffix, it sits at a known height. The reduction leaves a
                     stack of [after] entries with the goto target on top, so
                     the source is the entry directly below it, and every stack
                     a parse builds starts at the initial state. A source the
                     initial state cannot reach in exactly that many steps is
                     therefore not standing on any stack, however well it fits
                     the automaton's shape read backwards. While the height is
                     exact this is what turns a guessed goto into the only one
                     available. *)
                  let grounded source =
                    if after >= ceiling then true
                    else if after < 2 then false
                    else if IntSet.mem 0 (below source (after - 2)) then true
                    else begin
                      incr refused_stacks;
                      false
                    end
                  in
                  List.iter
                    (fun (source, target) ->
                      if
                        IntSet.mem source sources && grounded source
                        && residue_fits (if after >= ceiling then ceiling else after - 1) source reduced_residue
                        && fits after target
                        && residue_fits after target reduced_residue
                      then
                        moves :=
                          List.rev_append
                            (List.rev_map
                               (fun variant -> Reduce (reduction.prod, variant))
                               (cap_variants preds below precision 0 ceiling
                                  after ~residue:reduced_residue [ target; source ]))
                            !moves)
                    (Option.value
                       (Hashtbl.find_opt gotos reduction.lhs)
                       ~default:[]));
              let reduced = !moves in
              (* A reduction's result depends on its stack and production,
                 not on the lookahead that enabled it. Share it across tokens
                 within this precision round. *)
              Hashtbl.add reduction_cache (stack, reduction.prod) reduced;
              moves := List.rev_append reduced previous)
            (reductions state token));
      Hashtbl.add cache (stack, token) !moves;
      !moves

type chain_status = Running of stack | Finished of stack

(* All (left result, right result, diverged) ways for both runs to consume
   [token]. The two reduction chains advance in lockstep: aligned identical
   productions carry no divergence, so a reduction cycle both runs share
   cancels out instead of poisoning the verdict, while any position where the
   chains first differ - two different productions, or one run reducing while
   the other shifts - is exactly where two distinct parses of one sentence
   must part ways, and marks the pair diverged. Goto and shift-target
   differences alone are abstraction artifacts, never a first divergence, so
   they are deliberately not compared. *)
let joint_outcomes moves finish_cache ~diverged (start_left, start_right) token =
  let seen = Hashtbl.create 64 in
  let results = Hashtbl.create 16 in
  let queue = Queue.create () in
  let add_result left right diverged =
    if compare left right <= 0 then
      Hashtbl.replace results (left, right, diverged) ()
    else Hashtbl.replace results (right, left, diverged) ()
  in
  let push node =
    if not (Hashtbl.mem seen node) then begin
      Hashtbl.add seen node ();
      Queue.add node queue
    end
  in
  (* Once the two histories have diverged, their remaining reduction chains
     are independent. Walking their product one reduction at a time visits
     every pair of intermediate stacks even though only the two sets of final
     stacks matter. On a wide nullable chain that product can be orders of
     magnitude larger than its result. Close each side separately and take the
     product only at the end. This is the same relation: after divergence no
     later production comparison can undo the difference already found. *)
  let finishes = function
    | Finished stack -> [ stack ]
    | Running start -> (
        match Hashtbl.find_opt finish_cache (start, token) with
        | Some finished -> finished
        | None ->
            let side_seen = Hashtbl.create 16 in
            let side_results = Hashtbl.create 8 in
            let side_queue = Queue.create () in
            let side_push stack =
              if not (Hashtbl.mem side_seen stack) then begin
                Hashtbl.add side_seen stack ();
                Queue.add stack side_queue
              end
            in
            side_push start;
            while not (Queue.is_empty side_queue) do
              let stack = Queue.take side_queue in
              List.iter
                (function
                  | Reduce (_, next) -> side_push next
                  | Terminate result -> Hashtbl.replace side_results result ())
                (moves stack token)
            done;
            let finished =
              Hashtbl.fold (fun stack () all -> stack :: all) side_results []
            in
            Hashtbl.add finish_cache (start, token) finished;
            finished)
  in
  push (Running start_left, Running start_right, diverged);
  while not (Queue.is_empty queue) do
    let (left, right, diverged) = Queue.take queue in
    if diverged then
      List.iter
        (fun result_left ->
          List.iter
            (fun result_right -> add_result result_left result_right true)
            (finishes right))
        (finishes left)
    else
    match (left, right) with
    | Finished result_left, Finished result_right ->
        add_result result_left result_right diverged
    | Running suffix_left, Running suffix_right ->
        let paired move_left move_right =
          match (move_left, move_right) with
          | Reduce (p, l), Reduce (q, r) ->
              Some (Running l, Running r, diverged || p <> q)
          | Reduce (_, l), Terminate r -> Some (Running l, Finished r, true)
          | Terminate l, Reduce (_, r) -> Some (Finished l, Running r, true)
          | Terminate l, Terminate r -> Some (Finished l, Finished r, diverged)
        in
        if (not diverged) && suffix_left = suffix_right then
          (* The two runs are still the same run: same stack, so an
             unknown-base goto resolves identically on both sides. Identical
             moves pair diagonally; distinct moves pair only where two real
             parses can first part ways - different productions, or reducing
             against shifting. Same-production pairs with different gotos are
             different possible worlds, never two parses of one sentence. *)
          let all = moves suffix_left token in
          List.iter
            (fun move_left ->
              List.iter
                (fun move_right ->
                  let compatible =
                    match (move_left, move_right) with
                    | Reduce (p, _), Reduce (q, _) -> p <> q
                    | Reduce _, Terminate _ | Terminate _, Reduce _ -> true
                    | Terminate _, Terminate _ -> false
                  in
                  if move_left == move_right || compatible then
                    Option.iter push (paired move_left move_right))
                all)
            all
        else
          let moves_left = moves suffix_left token in
          let moves_right = moves suffix_right token in
          List.iter
            (fun move_left ->
              List.iter
                (fun move_right ->
                  Option.iter push (paired move_left move_right))
                moves_right)
            moves_left
    | Running suffix_left, Finished _ ->
        List.iter
          (fun move ->
            match move with
            | Reduce (_, l) -> push (Running l, right, diverged)
            | Terminate l -> push (Finished l, right, diverged))
          (moves suffix_left token)
    | Finished _, Running suffix_right ->
        List.iter
          (fun move ->
            match move with
            | Reduce (_, r) -> push (left, Running r, diverged)
            | Terminate r -> push (left, Finished r, diverged))
          (moves suffix_right token)
  done;
  Hashtbl.fold (fun key () list -> key :: list) results []

(* Where in a chain two runs actually part ways, for a site the survey reports.

   The joint walk lets two runs differ only by taking different moves, and the
   step that does sets the divergence flag, so every pair still undiverged
   carries the same stack on both sides. A site is therefore one stack and one
   lookahead - and the conflict it names is usually not at that stack. The
   chain reduces in lockstep for as long as one move is on offer, and the
   competing moves appear a step or two down; reporting only the site's own top
   state shows a single shared reduction and says nothing.

   So follow the shared chain from the site until a stack admits two moves that
   two parses of one sentence could take: two different productions, or a
   reduction against a shift. Same-production moves that differ only in their
   goto are different possible worlds rather than a divergence, exactly as in
   the joint walk, so the chain continues through each of them.

   This is diagnostic only, and deliberately separate from [joint_outcomes]:
   carrying provenance through the hot path would multiply the outcome set it
   deduplicates on, and only the handful of sites a survey prints ever ask. *)
let conflicting_moves moves stack token =
  let seen = Hashtbl.create 16 in
  let queue = Queue.create () in
  let found = ref None in
  let push stack =
    if not (Hashtbl.mem seen stack) then begin
      Hashtbl.add seen stack ();
      Queue.add stack queue
    end
  in
  let rec pair_off = function
    | [] -> None
    | move :: rest -> (
        let partner =
          List.find_opt
            (fun other ->
              match (move, other) with
              | Reduce (p, _), Reduce (q, _) -> p <> q
              | Reduce _, Terminate _ | Terminate _, Reduce _ -> true
              | Terminate _, Terminate _ -> false)
            rest
        in
        match partner with
        | Some other -> Some (move, other)
        | None -> pair_off rest)
  in
  push stack;
  while !found = None && not (Queue.is_empty queue) do
    let current = Queue.take queue in
    let available = moves current token in
    match pair_off available with
    | Some pair -> found := Some (current, pair)
    | None ->
        List.iter
          (function Reduce (_, next) -> push next | Terminate _ -> ())
          available
  done;
  !found

(* What a refinement would have to fix, at one stack under one lookahead.

   The abstraction is exact for a reduction exactly while the reduction pops
   less than the retained stack. At or past that boundary the goto source is a
   set rather than a state - the states the right number of predecessor steps
   below the deepest entry retained - and picking the wrong member of that set
   is the only way a pair of runs that no real sentence separates can stay
   alive. So the places worth deepening are the stacks where a reduction
   reaches or passes the retained depth, and the depth that would make it exact
   is one more than the reduction is wide.

   Walking the reduction chain, rather than only the stack it starts from, is
   what makes this useful: a chain reduces several times before it shifts, and
   the reduction that loses the context is rarely the first one.

   Like [conflicting_moves] this is diagnostic and runs only when a candidate
   has already been found, so it recomputes the chain instead of making the hot
   path carry provenance. The visit bound is a guard rather than a limit that
   is expected to bite: a refinement request this walk misses costs precision
   on the next round, never soundness. *)
let chain_imprecision automaton moves stack token =
  let seen = Hashtbl.create 64 in
  let queue = Queue.create () in
  let requests = ref [] in
  let visits = ref 0 in
  let push stack =
    if not (Hashtbl.mem seen stack) then begin
      Hashtbl.add seen stack ();
      Queue.add stack queue
    end
  in
  push stack;
  while (not (Queue.is_empty queue)) && !visits < 4096 do
    incr visits;
    let current = Queue.take queue in
    (match current.suffix with
    | [] -> ()
    | top :: _ ->
        let depth = List.length current.suffix in
        List.iter
          (fun reduction ->
            if reduction.width >= depth then
              requests := (top, reduction.width + 1) :: !requests)
          (reductions automaton.states.(top) token));
    List.iter
      (function Reduce (_, next) -> push next | Terminate _ -> ())
      (moves current token)
  done;
  !requests

(* Where a chain leaving one stack is standing on a stack it has forgotten.

   [chain_imprecision] finds the one kind of guess a deeper stack removes by
   making a goto exact. It is not the only kind. A reduction chain truncates
   its stack at every step, under the cap of whatever state ends up on top, and
   a stack cut below its own height has thrown away entries it was demonstrably
   holding. The rebuilding descent then walks those entries back - through every
   predecessor the automaton allows, not just the one that was really there -
   so the chain continues on stacks no parse was ever standing on.

   Nothing about that reads as a guess at the goto: each goto along the way
   resolves exactly, off a suffix long enough to expose its source. The chain
   is exact and standing on an invention. That is how a candidate can survive
   with every step of its trace marked exact and refinement reporting that no
   retained stack rules it out.

   The depth that fixes it is the stack's own height, for the same reason the
   path-level widening asks for it: a stack retaining as many entries as it is
   tall is the whole stack, and the descent has nothing left to invent.

   Being cut short is not on its own a reason to ask, though, and asking on
   every cut would aim a refinement at most of the automaton at once. A
   truncated stack has lost nothing if walking it back down reconstructs the
   whole of it: every entry was forced, so the descent recovers the ones that
   were really there and no others, and depth would buy nothing the walk does
   not already give. So [descend] runs the walk to the stack's full height, and
   the depth is worth asking for whenever the walk comes back short of it -
   stopped at a branch, split into several, or given a height too saturated to
   pin anything down.

   The walk over the chain is the same one [chain_imprecision] makes, and
   carries the same visit bound for the same reason: a request it misses costs
   a round, never soundness. *)
let chain_truncations descend moves stack token =
  let seen = Hashtbl.create 64 in
  let queue = Queue.create () in
  let requests = ref [] in
  let visits = ref 0 in
  let push stack =
    if not (Hashtbl.mem seen stack) then begin
      Hashtbl.add seen stack ();
      Queue.add stack queue
    end
  in
  push stack;
  while (not (Queue.is_empty queue)) && !visits < 4096 do
    incr visits;
    let current = Queue.take queue in
    (match current.suffix with
    | [] -> ()
    | top :: _ -> (
        if List.length current.suffix < current.height then
          match descend current with
          | [ rebuilt ] when List.length rebuilt.suffix >= rebuilt.height -> ()
          | _ -> requests := (top, current.height) :: !requests));
    List.iter
      (function Reduce (_, next) -> push next | Terminate _ -> ())
      (moves current token)
  done;
  !requests

(* The imprecise reductions on the joint step a recorded edge actually took.

   [chain_imprecision] explores every chain leaving one stack, which is what
   refinement wants: deepening a state the candidate did not go through costs
   precision it did not need, never a wrong verdict. A trace cannot be read that
   way, because it claims to say what happened on this pair's path, and a guess
   from a branch the pair never entered names the wrong state to sharpen.

   Filtering each side on its own by "can this chain reach one of the recorded
   child's stacks" is not enough either. It is a reachability test, so a chain
   that reaches the right stack for the wrong reason still passes, and it says
   nothing about whether the two sides' chains were taken *together* - which is
   the only sense in which a joint step has a provenance at all.

   So this replays the step the way [joint_outcomes] walks it, keeping both
   sides in lockstep and with the same pairing rules, and marks the joint nodes
   that can still reach an outcome matching the recorded child. A reduction is
   reported only when it fires on an edge between two marked nodes: taken on a
   path that demonstrably ends where this pair ended. Any deviation from
   [joint_outcomes]'s rules here would replay a different graph from the one the
   search walked, so the pairing logic is deliberately identical.

   The child is matched as an unordered pair, because [push] canonicalises by
   ordering the two sides and which side became which is not recoverable. That
   is the one place this stays an approximation: a step whose two sides ended on
   the same pair of stacks in the opposite arrangement is indistinguishable from
   the recorded one. It cannot admit a chain that ends somewhere else. *)
let joint_imprecision automaton moves pair token target =
  let matches (left, right) =
    match target with
    | None -> true
    | Some (child_left, child_right) ->
        (left = child_left && right = child_right)
        || (left = child_right && right = child_left)
  in
  let width_of stack prod =
    match stack.suffix with
    | [] -> None
    | top :: _ ->
        Option.map
          (fun reduction -> reduction.width)
          (List.find_opt
             (fun reduction -> reduction.prod = prod)
             (reductions automaton.states.(top) token))
  in
  (* A move is imprecise exactly where [side_moves] had to guess: the reduction
     reaches or passes the depth the stack retains. *)
  let imprecision stack move =
    match move with
    | Terminate _ -> None
    | Reduce (prod, _) -> (
        match width_of stack prod with
        | Some width when width >= List.length stack.suffix ->
            Some (List.hd stack.suffix, width + 1)
        | _ -> None)
  in
  let successors = Hashtbl.create 64 in
  let reaches = Hashtbl.create 64 in
  let visited = ref [] in
  let seen = Hashtbl.create 64 in
  let queue = Queue.create () in
  let visits = ref 0 in
  let push node =
    if not (Hashtbl.mem seen node) then begin
      Hashtbl.add seen node ();
      Queue.add node queue
    end
  in
  let record source target_node found =
    Hashtbl.replace successors source
      ((target_node, found)
      :: Option.value (Hashtbl.find_opt successors source) ~default:[]);
    push target_node
  in
  let start = (Running (fst pair), Running (snd pair), false) in
  push start;
  while (not (Queue.is_empty queue)) && !visits < 4096 do
    incr visits;
    let ((left, right, diverged) as current) = Queue.take queue in
    visited := current :: !visited;
    match (left, right) with
    | Finished result_left, Finished result_right ->
        if matches (result_left, result_right) then
          Hashtbl.replace reaches current ()
    | Running suffix_left, Running suffix_right ->
        let paired move_left move_right =
          let found =
            List.filter_map
              (fun (stack, move) -> imprecision stack move)
              [ (suffix_left, move_left); (suffix_right, move_right) ]
          in
          match (move_left, move_right) with
          | Reduce (p, l), Reduce (q, r) ->
              Some ((Running l, Running r, diverged || p <> q), found)
          | Reduce (_, l), Terminate r -> Some ((Running l, Finished r, true), found)
          | Terminate l, Reduce (_, r) -> Some ((Finished l, Running r, true), found)
          | Terminate l, Terminate r ->
              Some ((Finished l, Finished r, diverged), found)
        in
        if (not diverged) && suffix_left = suffix_right then
          let all = moves suffix_left token in
          List.iter
            (fun move_left ->
              List.iter
                (fun move_right ->
                  let compatible =
                    match (move_left, move_right) with
                    | Reduce (p, _), Reduce (q, _) -> p <> q
                    | Reduce _, Terminate _ | Terminate _, Reduce _ -> true
                    | Terminate _, Terminate _ -> false
                  in
                  if move_left == move_right || compatible then
                    Option.iter
                      (fun (next, found) -> record current next found)
                      (paired move_left move_right))
                all)
            all
        else
          let moves_left = moves suffix_left token in
          let moves_right = moves suffix_right token in
          List.iter
            (fun move_left ->
              List.iter
                (fun move_right ->
                  Option.iter
                    (fun (next, found) -> record current next found)
                    (paired move_left move_right))
                moves_right)
            moves_left
    | Running suffix_left, Finished _ ->
        List.iter
          (fun move ->
            let found =
              Option.to_list (imprecision suffix_left move)
            in
            match move with
            | Reduce (_, l) -> record current (Running l, right, diverged) found
            | Terminate l -> record current (Finished l, right, diverged) found)
          (moves suffix_left token)
    | Finished _, Running suffix_right ->
        List.iter
          (fun move ->
            let found =
              Option.to_list (imprecision suffix_right move)
            in
            match move with
            | Reduce (_, r) -> record current (left, Running r, diverged) found
            | Terminate r -> record current (left, Finished r, diverged) found)
          (moves suffix_right token)
  done;
  (* Backward from the matching outcomes: a node is on a path to the recorded
     child when one of its edges leads to a node that is. The joint graph can
     cycle, so this is a fixpoint rather than one sweep. *)
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter
      (fun node ->
        if not (Hashtbl.mem reaches node) then
          if
            List.exists
              (fun (next, _) -> Hashtbl.mem reaches next)
              (Option.value (Hashtbl.find_opt successors node) ~default:[])
          then begin
            Hashtbl.replace reaches node ();
            changed := true
          end)
      !visited
  done;
  let requests = Hashtbl.create 16 in
  List.iter
    (fun node ->
      if Hashtbl.mem reaches node then
        List.iter
          (fun (next, found) ->
            if Hashtbl.mem reaches next then
              List.iter (fun request -> Hashtbl.replace requests request ()) found)
          (Option.value (Hashtbl.find_opt successors node) ~default:[]))
    !visited;
  List.sort compare
    (Hashtbl.fold (fun request () found -> request :: found) requests [])
