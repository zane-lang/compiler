import Ambiguity.Product
import Ambiguity.Vpa

/-!
# Horizontal compilation and the counted model (producers)

Port of `regular.py`, `horizontal.py` and `prove.py`. Nothing here is trusted:
the components, automata and model are checked or proved separately, and the
fixed-point search only proposes a certificate for `check`.
-/

namespace Ambiguity

inductive Atom where
  | t (a : Tok)
  | call (o : Tok) (inner : Option Nat) (c : Tok)
  deriving DecidableEq, Hashable, Repr, Inhabited

/-- A minimized horizontal DFA: initial state 0. -/
structure DFA where
  trans : Array (List (Atom × Nat))
  acc : Array S
  deriving Inhabited, BEq, Hashable

instance : BEq S := ⟨fun a b => decide (a = b)⟩

/-- Rule shape facts for the plain grammar. -/
def groupRule? : List Sym → Option (Tok × Option Nat × Tok)
  | [.t o, .t c] => if closerOf o == some c then some (o, none, c) else none
  | [.t o, .n y, .t c] => if closerOf o == some c then some (o, some y, c) else none
  | _ => none

/-- Nonterminals deriving a nonempty word (least fixpoint). -/
def nonemptySet (E : PGrammar) : Array Bool := Id.run do
  let n := E.rules.size
  let mut ne := Array.replicate n false
  let mut changed := true
  while changed do
    changed := false
    for x in List.range n do
      if ne[x]! then continue
      if (E.rulesOf x).any (fun r => (groupRule? r).isSome || r.any fun | .t _ => true | .n y => ne[y]!) then
        ne := ne.set! x true; changed := true
  return ne

/-- Capped counts of empty derivations (least fixpoint). -/
def epsCounts (E : PGrammar) : Array S := Id.run do
  let n := E.rules.size
  let mut eps : Array S := Array.replicate n 0
  let mut changed := true
  while changed do
    changed := false
    for x in List.range n do
      let v := sumL (E.rulesOf x) fun r =>
        if (groupRule? r).isSome then 0 else
        r.foldl (fun acc s => acc * match s with | .t _ => 0 | .n y => eps[y]!) 1
      if v != eps[x]! then eps := eps.set! x v; changed := true
  return eps

/-- Tarjan's strongly connected components over the flat dependency graph,
in reverse topological order (callees first). -/
partial def sccs (n : Nat) (succ : Nat → List Nat) : Array Nat × Nat := Id.run do
  let mut index : Array (Option Nat) := Array.replicate n none
  let mut low : Array Nat := Array.replicate n 0
  let mut onStack : Array Bool := Array.replicate n false
  let mut stack : Array Nat := #[]
  let mut comp : Array Nat := Array.replicate n 0
  let mut ncomp := 0
  let mut counter := 0
  for root in List.range n do
    if index[root]!.isSome then continue
    -- iterative DFS: frames (node, remaining successors)
    let mut work : Array (Nat × List Nat) := #[(root, succ root)]
    index := index.set! root (some counter); low := low.set! root counter; counter := counter + 1
    stack := stack.push root; onStack := onStack.set! root true
    while work.size > 0 do
      let (v, rest) := work.back!
      match rest with
      | w :: rest' =>
        work := work.set! (work.size - 1) (v, rest')
        match index[w]! with
        | none =>
          index := index.set! w (some counter); low := low.set! w counter; counter := counter + 1
          stack := stack.push w; onStack := onStack.set! w true
          work := work.push (w, succ w)
        | some iw => if onStack[w]! then low := low.set! v (min low[v]! iw)
      | [] =>
        work := work.pop
        if work.size > 0 then
          let (u, _) := work.back!
          low := low.set! u (min low[u]! low[v]!)
        if low[v]! == index[v]!.get! then
          let mut done := false
          while !done do
            let w := stack.back!
            stack := stack.pop
            onStack := onStack.set! w false
            comp := comp.set! w ncomp
            if w == v then done := true
          ncomp := ncomp + 1
  return (comp, ncomp)

/-! ## The fixed-point search (prove.py) -/

partial def search (br : Tok → Option Tok) (M : Model) (limit : Nat) : Except String Cert := do
  let mut frames : Array (List Nat × Option Tok) := #[]
  let mut fids : Std.HashMap (List Nat × Option Tok) Nat := {}
  let mut nodes : Array (Std.HashSet Vec) := #[]
  let mut nodeList : Array (Array Vec) := #[]
  let mut exits : Array (Array (List (Nat × S))) := #[]
  let mut callers : Array (Array (Nat × Nat × Tok)) := #[]   -- (parent frame, node vector index, opener)
  let mut queue : Array (Nat × Vec) := #[]
  let mut reached := 0
  -- frame helper
  let rootKey : List Nat × Option Tok := ([0], none)
  fids := fids.insert rootKey 0; frames := frames.push rootKey
  nodes := nodes.push {}; nodeList := nodeList.push #[]; exits := exits.push #[]; callers := callers.push #[]
  let v0 := filt M (closure M [(0, M.entry 0, 1)])
  nodes := nodes.set! 0 (nodes[0]!.insert v0); nodeList := nodeList.modify 0 (·.push v0)
  queue := queue.push (0, v0)
  let mut qi := 0
  while qi < queue.size do
    let (fid, v) := queue[qi]!
    qi := qi + 1
    reached := reached + 1
    if reached > limit then throw "node limit"
    let mut succs : List (Nat × Vec) := []
    -- acceptance
    let fs := frames[fid]!.1
    let acc := accOf M fs v
    if !acc.isEmpty && !(exits[fid]!.contains acc) then
      exits := exits.modify fid (·.push acc)
      for (pf, pvi, o) in callers[fid]! do
        let pv := nodeList[pf]![pvi]!
        let c := retCounts M pv o acc
        if !c.isEmpty then succs := succs ++ [(pf, filt M (closure M c))]
    for a in (tokensOf M v).eraseDups do
      let c := intCounts M v a
      if !c.isEmpty then succs := succs ++ [(fid, filt M (closure M c))]
    for o in (openersOf M v).eraseDups do
      let cfs := dedupSorted (childrenOf M v o)
      let key := (cfs, br o)
      let cid ← match fids.get? key with
        | some c => pure c
        | none => do
          let c := frames.size
          fids := fids.insert key c; frames := frames.push key
          nodes := nodes.push {}; nodeList := nodeList.push #[]; exits := exits.push #[]; callers := callers.push #[]
          let e := filt M (closure M (cfs.map fun f => (f, M.entry f, 1)))
          succs := succs ++ [(c, e)]
          pure c
      let vi := (nodeList[fid]!.findIdx? (· == v)).getD 0
      if !(callers[cid]!.contains (fid, vi, o)) then
        callers := callers.modify cid (·.push (fid, vi, o))
        for acc in exits[cid]! do
          let c := retCounts M v o acc
          if !c.isEmpty then succs := succs ++ [(fid, filt M (closure M c))]
    for (f, w) in succs do
      if !nodes[f]!.contains w then
        nodes := nodes.modify f (·.insert w); nodeList := nodeList.modify f (·.push w)
        queue := queue.push (f, w)
  let fr := (List.range frames.size).map fun i =>
    ({ fs := frames[i]!.1, closer := frames[i]!.2, nodes := nodeList[i]!.toList,
       exits := exits[i]!.toList } : Frame)
  return { frames := fr }

end Ambiguity
