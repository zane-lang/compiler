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

inductive NEdge where
  | e (to : Nat) (w : S)
  | a (atom : Atom) (to : Nat)
  | nt (y : Nat) (to : Nat)
  deriving Inhabited

structure Compiled where
  ne : Array Bool
  eps : Array S
  comp : Array Nat
  ncomp : Nat
  dirLeft : Array Bool
  lang : Array Nat
  lib : Array DFA

/-- Compile every component, callees first. Returns `none` when a component
is not strongly regular. -/
def compile (E : PGrammar) : Except String Compiled := do
  let n := E.rules.size
  let ne := nonemptySet E
  let eps := epsCounts E
  let flatSucc : Nat → List Nat := fun x =>
    ((E.rulesOf x).flatMap fun r => if (groupRule? r).isSome then [] else
      r.filterMap fun | .n y => if ne[y]! then some y else none | _ => none).eraseDups
  let (comp, ncomp) := sccs n flatSucc
  -- orientation
  let mut dirLeft : Array Bool := Array.replicate ncomp false
  let mut orient : Array (Bool × Bool) := Array.replicate ncomp (false, false)
  for x in List.range n do
    if !ne[x]! then continue
    let c := comp[x]!
    for r in E.rulesOf x do
      if (groupRule? r).isSome then continue
      let same := (r.zipIdx.filter fun (s, _) => match s with | .n y => ne[y]! && comp[y]! == c | _ => false).map (·.2)
      if same.length > 1 then throw s!"nonlinear rule for {x}"
      match same with
      | [i] =>
        let solid := fun (s : Sym) => match s with | .t _ => true | .n y => ne[y]!
        let before := (r.take i).any solid
        let after := (r.drop (i+1)).any solid
        if before && after then throw s!"two-sided rule for {x}"
        let (l, rt) := orient[c]!
        orient := orient.set! c (l || after, rt || before)
      | _ => pure ()
  for c in List.range ncomp do
    let (l, rt) := orient[c]!
    if l && rt then throw s!"mixed orientation in component {c}"
    dirLeft := dirLeft.set! c (l && !rt)
  -- members per component
  let mut members : Array (List Nat) := Array.replicate ncomp []
  for x in List.range n do
    if ne[x]! then members := members.modify comp[x]! (· ++ [x])
  let mut lang : Array Nat := Array.replicate n 0
  let mut lib : Array DFA := #[]
  let mut libIds : Std.HashMap DFA Nat := {}
  for c in List.range ncomp do
    let mems := members[c]!
    if mems.isEmpty then continue
    let left := dirLeft[c]!
    -- NFA construction
    let mut nodes : Array (List NEdge) := #[]
    let mut entries : Std.HashMap Nat Nat := {}
    for m in mems do
      entries := entries.insert m nodes.size; nodes := nodes.push []
    let start := nodes.size
    if left then nodes := nodes.push []
    let fin := nodes.size
    if !left then nodes := nodes.push []
    -- seqhead: a chain reading `body` into `tail`
    let mut heads : Std.HashMap (String × Nat) Nat := {}
    for m in mems do
      for r in E.rulesOf m do
        let body0 : List (Sum Atom Nat) :=
          match groupRule? r with
          | some (o, inner, cl) => [.inl (.call o inner cl)]
          | none => []
        let isGroup := (groupRule? r).isSome
        let same := if isGroup then [] else
          (r.zipIdx.filter fun (s, _) => match s with | .n y => ne[y]! && comp[y]! == c | _ => false).map (·.2)
        let (origin, dest, body, w) : Nat × Nat × List Sym × S :=
          match same with
          | [i] =>
            if left then
              (entries.getD (match r[i]! with | .n y => y | _ => 0) 0, entries.getD m 0, r.drop (i+1),
               (r.take i).foldl (fun acc s => acc * match s with | .n y => eps[y]! | _ => 0) 1)
            else
              (entries.getD m 0, entries.getD (match r[i]! with | .n y => y | _ => 0) 0, r.take i,
               (r.drop (i+1)).foldl (fun acc s => acc * match s with | .n y => eps[y]! | _ => 0) 1)
          | _ => (if left then start else entries.getD m 0, if left then entries.getD m 0 else fin,
                  if isGroup then [] else r, 1)
        -- build the chain reading `body` into `dest`, right to left
        let mut tail := dest
        let elems : List (Sum Atom Nat) ←
          if isGroup then pure body0 else
            body.foldlM (init := []) fun acc s => match s with
              | .t a => pure (acc ++ [.inl (.t a)])
              | .n y =>
                if ne[y]! then pure (acc ++ [.inr y])
                else if eps[y]! == 0 then throw s!"epsilon-only {y} has no derivation"
                else if eps[y]! == 2 then pure (acc ++ [.inr (n + y)])
                else pure acc
        for el in elems.reverse do
          let (key, edge) : (String × Nat) × (Nat → NEdge) := match el with
            | .inl atom => ((s!"A{repr atom}", tail), fun t => .a atom t)
            | .inr y => if y < n then ((s!"N{y}", tail), fun t => .nt y t) else (("W", tail), fun t => .e t 2)
          match heads.get? key with
          | some q => tail := q
          | none =>
            let q := nodes.size
            nodes := nodes.push [edge tail]; heads := heads.insert key q; tail := q
        nodes := nodes.modify origin (· ++ [.e tail w])
    -- inline lower languages
    let mut copies : Std.HashMap (Nat × Nat) Nat := {}
    let mut qq := 0
    while qq < nodes.size do
      let es := nodes[qq]!
      let mut out : List NEdge := []
      for e in es do
        match e with
        | .nt y tl =>
          let lid := lang[y]!
          let key := (lid, tl)
          let entry ← match copies.get? key with
            | some s => pure s
            | none => do
              let D := lib[lid]!
              let base := nodes.size
              for d in List.range D.trans.size do
                let mut es' : List NEdge := []
                if D.acc[d]! != 0 then es' := es' ++ [.e tl D.acc[d]!]
                for (atom, d') in D.trans[d]! do es' := es' ++ [.a atom (base + d')]
                nodes := nodes.push es'
              copies := copies.insert key base
              pure base
          out := out ++ [.e entry 1]
        | _ => out := out ++ [e]
      nodes := nodes.set! qq out
      qq := qq + 1
    -- determinize
    let finals : Std.HashMap Nat Nat :=
      if left then mems.foldl (fun m x => m.insert (entries.getD x 0) x) {} else ({} : Std.HashMap Nat Nat).insert fin 0
    let hasAtom : Nat → Bool := fun q => nodes[q]!.any fun | .a .. => true | _ => false
    let close : List (Nat × S) → List (Nat × S) := fun counts => Id.run do
      let mut init : Std.HashMap Nat S := {}
      for (q, w) in counts do init := init.insert q (init.getD q 0 + w)
      let mut m := init
      let mut changed := true
      while changed do
        let mut next := init
        for (q, w) in m.toList do
          for e in nodes[q]! do
            match e with
            | .e t w' => next := next.insert t (next.getD t 0 + w * w')
            | _ => pure ()
        changed := next.size != m.size || next.toList.any fun (k, w) => m.getD k 0 != w
        m := next
      let l := m.toList.filter fun (q, w) => w != 0 && (finals.contains q || hasAtom q)
      return l.mergeSort fun a b => a.1 ≤ b.1
    let mut states : Array (List (Nat × S)) := #[]
    let mut sids : Std.HashMap (List (Nat × S)) Nat := {}
    let mut trans : Array (List (Atom × Nat)) := #[]
    let mut starts : Std.HashMap Nat Nat := {}
    for m in mems do
      let v := close [(if left then start else entries.getD m 0, 1)]
      match sids.get? v with
      | some d => starts := starts.insert m d
      | none => starts := starts.insert m states.size; sids := sids.insert v states.size; states := states.push v
    let mut di := 0
    while di < states.size do
      let v := states[di]!
      let mut choices : List (Atom × List (Nat × S)) := []
      for (q, w) in v do
        for e in nodes[q]! do
          match e with
          | .a atom t =>
            choices := match choices.lookup atom with
              | some l => choices.map fun (a, l') => if a == atom then (a, l' ++ [(t, w)]) else (a, l')
              | none => choices ++ [(atom, [(t, w)])]
          | _ => pure ()
      let mut tr : List (Atom × Nat) := []
      for (atom, l) in choices do
        let v' := close l
        match sids.get? v' with
        | some d => tr := tr ++ [(atom, d)]
        | none =>
          tr := tr ++ [(atom, states.size)]; sids := sids.insert v' states.size; states := states.push v'
      trans := trans.push tr
      di := di + 1
      if states.size > 200000 then throw s!"component DFA limit: comp {c} members {mems} nfa {nodes.size} copies {copies.size} dir {left} maxlib {lib.foldl (fun a D => max a D.trans.size) 0} libs {lib.size}"
    -- minimize per member
    for m in mems do
      let fnode := if left then entries.getD m 0 else fin
      let accOf := fun (d : Nat) => (states[d]!.lookup fnode).getD 0
      -- live states
      let nd := states.size
      let mut live := Array.replicate nd false
      let mut rev : Array (List Nat) := Array.replicate nd []
      for d in List.range nd do
        for (_, d') in trans[d]! do rev := rev.modify d' (d :: ·)
      let mut stk := (List.range nd).filter fun d => accOf d != 0
      for d in stk do live := live.set! d true
      while !stk.isEmpty do
        let d := stk.head!
        stk := stk.tail
        for p in rev[d]! do
          if !live[p]! then live := live.set! p true; stk := p :: stk
      let sd := starts.getD m 0
      if !live[sd]! then throw s!"dead start for {m}"
      let mut colors : Array Nat := (Array.range nd).map fun d => (accOf d).toNat
      let mut count := 0
      for _ in [0:nd+1] do
        let mut intern : Std.HashMap (Nat × List (Atom × Nat)) Nat := {}
        let mut next := colors
        for d in List.range nd do
          if !live[d]! then continue
          let sig := (colors[d]!, (trans[d]!.filterMap fun (a, d') => if live[d']! then some (a, colors[d']!) else none).mergeSort
            fun x y => decide (toString (repr x.1) ≤ toString (repr y.1)))
          match intern.get? sig with
          | some k => next := next.set! d k
          | none => next := next.set! d intern.size; intern := intern.insert sig intern.size
        let stable := intern.size == count
        count := intern.size
        colors := next
        if stable then break
      -- canonical renumbering by BFS from the start
      let mut ren : Std.HashMap Nat Nat := ({} : Std.HashMap Nat Nat).insert colors[sd]! 0
      let mut repr' : Array Nat := #[sd]
      let mut bi := 0
      let mut ct : Array (List (Atom × Nat)) := #[]
      let mut ca : Array S := #[]
      while bi < repr'.size do
        let d := repr'[bi]!
        let mut edges : List (Atom × Nat) := []
        for (a, d') in trans[d]!.mergeSort (fun x y => decide (toString (repr x.1) ≤ toString (repr y.1))) do
          if !live[d']! then continue
          let k := colors[d']!
          match ren.get? k with
          | some j => edges := edges ++ [(a, j)]
          | none =>
            edges := edges ++ [(a, ren.size)]
            repr' := repr'.push d'
            ren := ren.insert k ren.size
        ct := ct.push edges
        ca := ca.push (accOf d)
        bi := bi + 1
      let D : DFA := { trans := ct, acc := ca }
      match libIds.get? D with
      | some lid => lang := lang.set! m lid
      | none => lang := lang.set! m lib.size; libIds := libIds.insert D lib.size; lib := lib.push D
  return { ne, eps, comp, ncomp, dirLeft, lang, lib }

/-! ## The model -/

inductive MKey where
  | fin (f : Nat)
  | weight (tail : Nat) (w : S)
  | int (a : Tok) (tail : Nat)
  | call (o : Tok) (f : Nat) (tail : Nat) (c : Tok)
  | comp (lid d tail : Nat)
  deriving DecidableEq, Hashable, Repr, Inhabited

structure MBuild where
  keys : Array MKey := #[]
  ids : Std.HashMap MKey Nat := {}
  frags : Array (Nat × Nat) := #[]
  fids : Std.HashMap (Option Nat) Nat := {}
  deriving Inhabited

def MBuild.node (b : MBuild) (k : MKey) : Nat × MBuild :=
  match b.ids.get? k with
  | some i => (i, b)
  | none => (b.keys.size, { b with keys := b.keys.push k, ids := b.ids.insert k b.keys.size })

/-- Head of the fragment for the interior `inner` (a nonterminal or empty). -/
def MBuild.head (C : Compiled) (b : MBuild) (inner : Option Nat) (tail : Nat) : Nat × MBuild :=
  match inner with
  | none => (tail, b)
  | some y =>
    if C.ne.getD y false then b.node (.comp (C.lang.getD y 0) 0 tail)
    else if C.eps.getD y 0 == 2 then b.node (.weight tail 2) else (tail, b)

/-- Fragment for an interior; fragments are created lazily, as in Python. -/
def MBuild.fragment (C : Compiled) (b : MBuild) (inner : Option Nat) : Nat × MBuild :=
  match b.fids.get? inner with
  | some f => (f, b)
  | none =>
    let f := b.frags.size
    let b := { b with frags := b.frags.push (0, 0), fids := b.fids.insert inner f }
    let (e, b) := b.node (.fin f)
    let (h, b) := b.head C inner e
    (f, { b with frags := b.frags.set! f (h, e) })

/-- Build the reachable model from the root fragment `[start]`. -/
def buildModel (C : Compiled) (start : Nat) : Model := Id.run do
  let mut b : MBuild := {}
  let (_, b') := b.fragment C (some start)
  b := b'
  let mut edges : Array (List Edge) := #[]
  let mut i := 0
  while i < b.keys.size do
    let k := b.keys[i]!
    let mut out : List Edge := []
    match k with
    | .fin _ => pure ()
    | .weight tail w => out := [.eps tail w]
    | .int a tail => out := [.int a tail]
    | .call o f tail c => out := [.call o f tail c]
    | .comp lid d tail =>
      let D := C.lib[lid]!
      let w := D.acc[d]!
      if w != 0 then out := out ++ [.eps tail w]
      for (atom, d') in D.trans[d]! do
        let (dest, b2) := b.node (.comp lid d' tail)
        b := b2
        match atom with
        | .t a => out := out ++ [.int a dest]
        | .call o inner c =>
          let (f, b3) := b.fragment C inner
          b := b3
          out := out ++ [.call o f dest c]
    edges := edges.push out
    i := i + 1
  return { edges, frags := b.frags }

/-! ## The fixed-point search (prove.py) -/

def vecKey (V : Vec) : Vec := V

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
