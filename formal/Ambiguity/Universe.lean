import Ambiguity.Horizontal

/-!
# The universe model

One `Model` holds every node the horizontal proof talks about: the counted
model's nodes (fragment ends, weights, copies of horizontal DFAs) and, for each
strongly regular component, the nodes of its NFA (member entries, a start for a
left-linear component, a final for a right-linear one, and chains reading rule
bodies). Each node carries a key, and `specEdges` states the node's edges as a
pure function of the grammar and the compiled facts. The checks compare the
model's edges with that specification.
-/

namespace Ambiguity

inductive CSym where
  | term (a : Tok)
  | call (o : Tok) (inner : Option Nat) (c : Tok)
  | low (y : Nat)
  | w2
  deriving DecidableEq, Hashable, Repr, Inhabited

inductive UKey where
  | fin (f : Nat)
  | weight (tail : Nat) (w : S)
  | comp (lid d tail : Nat)
  | entry (c m : Nat)
  | start (c : Nat)
  | cfin (c : Nat)
  | chain (c : Nat) (body : List CSym) (dest : UKey)
  deriving DecidableEq, Hashable, Repr, Inhabited

/-- Edge targets in the specification: a node id, a keyed node, or the start
of a copy of a horizontal DFA continuing at a target. -/
inductive Tgt where
  | id (n : Nat)
  | key (k : UKey)
  | comp0 (lid : Nat) (tail : Tgt)
  deriving Repr, Inhabited

inductive SEdge where
  | eps (t : Tgt) (w : S)
  | int (a : Tok) (t : Tgt)
  | call (o : Tok) (inner : Option Nat) (t : Tgt) (c : Tok)
  deriving Repr, Inhabited

/-- Compiled horizontal facts. -/
structure HFacts where
  ne : Array Bool
  eps : Array S
  comp : Array Nat
  left : Array Bool
  members : Array (List Nat)
  lib : Array DFA
  lang : Array Nat
  deriving Inhabited

namespace HFacts
def isNe (H : HFacts) (y : Nat) : Bool := H.ne.getD y false
def epsOf (H : HFacts) (y : Nat) : S := H.eps.getD y 0
def compOf (H : HFacts) (y : Nat) : Nat := H.comp.getD y 0
def isLeft (H : HFacts) (c : Nat) : Bool := H.left.getD c false
def mems (H : HFacts) (c : Nat) : List Nat := H.members.getD c []
def langOf (H : HFacts) (y : Nat) : Nat := H.lang.getD y 0
def dfa (H : HFacts) (lid : Nat) : DFA := H.lib.getD lid default
end HFacts

def DFA.accAt (D : DFA) (d : Nat) : S := D.acc.getD d 0
def DFA.transAt (D : DFA) (d : Nat) : List (Atom × Nat) := D.trans.getD d []

/-- How a rule of a component member becomes an NFA edge. -/
inductive RuleNfa where
  | dead
  | bad
  | edge (origin : UKey) (body : List CSym) (dest : UKey) (w : S)
  deriving Inhabited

/-- Body symbols as NFA chain symbols; `none` when some symbol has no
derivation at all (the rule is dead). -/
def bodySyms (H : HFacts) : List Sym → Option (List CSym)
  | [] => some []
  | .t a :: rest => (CSym.term a :: ·) <$> bodySyms H rest
  | .n y :: rest =>
    if H.isNe y then (CSym.low y :: ·) <$> bodySyms H rest
    else if H.epsOf y = 0 then none
    else if H.epsOf y = 2 then (CSym.w2 :: ·) <$> bodySyms H rest
    else bodySyms H rest

/-- Product of the empty-derivation counts of a context that derives only
the empty word; `none` if it contains a terminal or a nonempty symbol. -/
def epsCtx (H : HFacts) : List Sym → Option S
  | [] => some 1
  | .t _ :: _ => none
  | .n y :: rest => if H.isNe y then none else (H.epsOf y * ·) <$> epsCtx H rest

def sameIdx (H : HFacts) (c : Nat) (r : List Sym) : List Nat :=
  (r.zipIdx.filter fun (s, _) => match s with | .n y => H.isNe y && H.compOf y == c | _ => false).map (·.2)

def ruleNfa (H : HFacts) (c m : Nat) (r : List Sym) : RuleNfa :=
  let left := H.isLeft c
  match groupRule? r with
  | some (o, inner, cl) =>
    if left then .edge (.start c) [.call o inner cl] (.entry c m) 1
    else .edge (.entry c m) [.call o inner cl] (.cfin c) 1
  | none =>
    match sameIdx H c r with
    | [] =>
      match bodySyms H r with
      | none => .dead
      | some body => if left then .edge (.start c) body (.entry c m) 1 else .edge (.entry c m) body (.cfin c) 1
    | [i] =>
      let y := match r[i]? with | some (.n y) => y | _ => 0
      if left then
        match epsCtx H (r.take i), bodySyms H (r.drop (i + 1)) with
        | some w, some body => if w = 0 then .dead else .edge (.entry c y) body (.entry c m) w
        | none, _ => .bad
        | some _, none => .dead
      else
        match epsCtx H (r.drop (i + 1)), bodySyms H (r.take i) with
        | some w, some body => if w = 0 then .dead else .edge (.entry c m) body (.entry c y) w
        | none, _ => .bad
        | some _, none => .dead
    | _ => .bad

def chainTgt (c : Nat) (body : List CSym) (dest : UKey) : Tgt :=
  if body.isEmpty then .key dest else .key (.chain c body dest)

/-- All rule edges of a component, with their origins, in a fixed order. -/
def compEdges (H : HFacts) (E : PGrammar) (c : Nat) : List (UKey × SEdge) :=
  (H.mems c).flatMap fun m => (E.rulesOf m).filterMap fun r =>
    match ruleNfa H c m r with
    | .edge o body dest w => some (o, .eps (chainTgt c body dest) w)
    | _ => none

def specEdges (H : HFacts) (E : PGrammar) : UKey → List SEdge
  | .fin _ => []
  | .weight tail w => [.eps (.id tail) w]
  | .comp lid d tail =>
    let D := H.dfa lid
    (if D.accAt d = 0 then [] else [.eps (.id tail) (D.accAt d)]) ++
      (D.transAt d).map fun (atom, d') =>
        match atom with
        | .t a => .int a (.key (.comp lid d' tail))
        | .call o inner c => .call o inner (.key (.comp lid d' tail)) c
  | .entry c m => (compEdges H E c).filterMap fun (o, e) => if o = .entry c m then some e else none
  | .start c => (compEdges H E c).filterMap fun (o, e) => if o = .start c then some e else none
  | .cfin _ => []
  | .chain _ [] _ => []
  | .chain c (s :: rest) dest =>
    match s with
    | .term a => [.int a (chainTgt c rest dest)]
    | .call o inner cl => [.call o inner (chainTgt c rest dest) cl]
    | .low y => [.eps (.comp0 (H.langOf y) (chainTgt c rest dest)) 1]
    | .w2 => [.eps (chainTgt c rest dest) 2]

/-- The fragment entry for an interior, continuing at the fragment end. -/
def headTgt (H : HFacts) (inner : Option Nat) (finId : Nat) : Tgt :=
  match inner with
  | none => .id finId
  | some y =>
    if H.isNe y then .comp0 (H.langOf y) (.id finId)
    else if H.epsOf y = 2 then .key (.weight finId 2)
    else .id finId

/-! ## Producer (unverified) -/

structure UBuild where
  keys : Array UKey := #[]
  ids : Std.HashMap UKey Nat := {}
  out : Array (Option (List Edge)) := #[]
  fragInner : Array (Option Nat) := #[]
  fids : Std.HashMap (Option Nat) Nat := {}
  deriving Inhabited

def UBuild.node (b : UBuild) (k : UKey) : Nat × UBuild :=
  match b.ids.get? k with
  | some i => (i, b)
  | none =>
    let i := b.keys.size
    (i, { b with keys := b.keys.push k, ids := b.ids.insert k i, out := b.out.push none })

def UBuild.frag (b : UBuild) (inner : Option Nat) : Nat × UBuild :=
  match b.fids.get? inner with
  | some f => (f, b)
  | none =>
    let f := b.fragInner.size
    (f, { b with fragInner := b.fragInner.push inner, fids := b.fids.insert inner f })

partial def UBuild.resolve (b : UBuild) : Tgt → Nat × UBuild
  | .id n => (n, b)
  | .key k => b.node k
  | .comp0 lid tl => let (j, b) := b.resolve tl; b.node (.comp lid 0 j)

def UBuild.realize (b : UBuild) : SEdge → Edge × UBuild
  | .eps t w => let (j, b) := b.resolve t; (.eps j w, b)
  | .int a t => let (j, b) := b.resolve t; (.int a j, b)
  | .call o inner t c =>
    let (j, b) := b.resolve t
    let (f, b) := b.frag inner
    (.call o f j c, b)

/-- Fill the edges of every node created so far (and those they create). -/
def UBuild.saturate (H : HFacts) (E : PGrammar) (b0 : UBuild) (from_ : Nat) : UBuild := Id.run do
  let mut b := b0
  let mut i := from_
  while i < b.keys.size do
    if b.out[i]!.isNone then
      let mut es : List Edge := []
      for se in specEdges H E b.keys[i]! do
        let (e, b') := b.realize se
        b := b'
        es := es ++ [e]
      b := { b with out := b.out.set! i (some es) }
    i := i + 1
  return b

def UBuild.model (b : UBuild) (frags : Array (Nat × Nat)) : Model :=
  { edges := b.out.map (·.getD []), frags }

/-- Per-component determinization witness. -/
structure CompWit where
  c : Nat
  states : Array Vec
  trans : Array (List (Atom × Nat))
  startState : List (Nat × Nat)           -- member ↦ state
  hmap : List (Nat × Array (Option Nat))  -- member ↦ (state ↦ lib state)
  dead : List (Nat × Array Bool)          -- member ↦ states that never accept
  deriving Inhabited

def startNode (H : HFacts) (c m : Nat) : UKey := if H.isLeft c then .start c else .entry c m
def finalNode (H : HFacts) (c m : Nat) : UKey := if H.isLeft c then .entry c m else .cfin c

def atomOfEdge (fragInner : Array (Option Nat)) : Edge → Option Atom
  | .int a _ => some (.t a)
  | .call o f _ c => some (.call o (fragInner.getD f none) c)
  | _ => none

def atomH (fragInner : Array (Option Nat)) (a : Atom) : Edge → Option (Nat × S)
  | .int b t => if Atom.t b = a then some (t, 1) else none
  | .call o f t c => if Atom.call o (fragInner.getD f none) c = a then some (t, 1) else none
  | _ => none

/-- Kept nodes of a horizontal vector: with a reading edge, or final. -/
def keptH (M : Model) (finals : List Nat) (q : Nat) : Bool :=
  finals.contains q || (M.out q).any fun e => !e.isEps

def filtH (M : Model) (finals : List Nat) (V : Vec) : Vec := V.filter fun e => keptH M finals e.2.1

end Ambiguity

namespace Ambiguity

def atomKey (a : Atom) : String := toString (repr a)

/-- Build the universe: compile every component callees first, then the
fragments. Unverified; everything it produces is checked. -/
def buildUniverse (E : PGrammar) : Except String (HFacts × UBuild × Array CompWit × Array (Nat × Nat)) := do
  let n := E.rules.size
  let ne := nonemptySet E
  let eps := epsCounts E
  let flatSucc : Nat → List Nat := fun x =>
    ((E.rulesOf x).flatMap fun r => if (groupRule? r).isSome then [] else
      r.filterMap fun | .n y => if ne[y]! then some y else none | _ => none).eraseDups
  let (comp, ncomp) := sccs n flatSucc
  let mut orient : Array (Bool × Bool) := Array.replicate ncomp (false, false)
  for x in List.range n do
    if !ne[x]! then continue
    let c := comp[x]!
    for r in E.rulesOf x do
      if (groupRule? r).isSome then continue
      let same := (r.zipIdx.filter fun (s, _) => match s with | .n y => ne[y]! && comp[y]! == c | _ => false).map (·.2)
      match same with
      | [i] =>
        let solid := fun (s : Sym) => match s with | .t _ => true | .n y => ne[y]!
        let (l, rt) := orient[c]!
        orient := orient.set! c (l || (r.drop (i+1)).any solid, rt || (r.take i).any solid)
      | _ => pure ()
  let left := orient.map fun (l, rt) => l && !rt
  let mut members : Array (List Nat) := Array.replicate ncomp []
  for x in List.range n do
    if ne[x]! then members := members.modify comp[x]! (· ++ [x])
  let mut H : HFacts := { ne, eps, comp, left, members, lib := #[], lang := Array.replicate n 0 }
  let mut b : UBuild := {}
  let (_, b0) := b.frag (some E.start)
  b := b0
  let mut wits : Array CompWit := #[]
  let mut libIds : Std.HashMap DFA Nat := {}
  for c in List.range ncomp do
    let mems := members[c]!
    if mems.isEmpty then continue
    let before := b.keys.size
    let mut startIds : List (Nat × Nat) := []
    let mut finalIds : List (Nat × Nat) := []
    for m in mems do
      let (s, b1) := b.node (startNode H c m)
      let (f, b2) := b1.node (finalNode H c m)
      b := b2
      startIds := startIds ++ [(m, s)]
      finalIds := finalIds ++ [(m, f)]
    b := b.saturate H E before
    let M := b.model #[]
    let finals := finalIds.map (·.2)
    let close := fun (V : Vec) => filtH M finals (closure M V)
    let mut states : Array Vec := #[]
    let mut sids : Std.HashMap Vec Nat := {}
    let mut trans : Array (List (Atom × Nat)) := #[]
    let mut startState : List (Nat × Nat) := []
    for (m, s) in startIds do
      let v := close [(0, s, 1)]
      match sids.get? v with
      | some d => startState := startState ++ [(m, d)]
      | none =>
        startState := startState ++ [(m, states.size)]
        sids := sids.insert v states.size; states := states.push v
    let mut di := 0
    while di < states.size do
      let v := states[di]!
      let atoms := (v.flatMap fun e => (M.out e.2.1).filterMap (atomOfEdge b.fragInner)).eraseDups
      let mut tr : List (Atom × Nat) := []
      for a in atoms do
        let v' := close (edgeCounts M v (atomH b.fragInner a))
        match sids.get? v' with
        | some d => tr := tr ++ [(a, d)]
        | none =>
          tr := tr ++ [(a, states.size)]; sids := sids.insert v' states.size; states := states.push v'
      trans := trans.push tr
      di := di + 1
      if states.size > 200000 then throw s!"component DFA limit at {c}"
    let nd := states.size
    let mut hmaps : List (Nat × Array (Option Nat)) := []
    let mut deads : List (Nat × Array Bool) := []
    for (m, fnode) in finalIds do
      let accOf := fun (d : Nat) => getV states[d]! 0 fnode
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
      let sd := (startState.lookup m).getD 0
      if !live[sd]! then throw s!"dead start for {m}"
      let mut colors : Array Nat := (Array.range nd).map fun d => (accOf d).toNat
      let mut count := 0
      for _ in [0:nd+1] do
        let mut intern : Std.HashMap (Nat × List (String × Nat)) Nat := {}
        let mut next := colors
        for d in List.range nd do
          if !live[d]! then continue
          let sig := (colors[d]!, ((trans[d]!.filter fun (_, d') => live[d']!).map fun (a, d') =>
            (atomKey a, colors[d']!)).mergeSort fun x y => decide (x.1 ≤ y.1))
          match intern.get? sig with
          | some k => next := next.set! d k
          | none => next := next.set! d intern.size; intern := intern.insert sig intern.size
        let stable := intern.size == count
        count := intern.size
        colors := next
        if stable then break
      let mut ren : Std.HashMap Nat Nat := ({} : Std.HashMap Nat Nat).insert colors[sd]! 0
      let mut repr' : Array Nat := #[sd]
      let mut bi := 0
      let mut ct : Array (List (Atom × Nat)) := #[]
      let mut ca : Array S := #[]
      while bi < repr'.size do
        let d := repr'[bi]!
        let mut edges : List (Atom × Nat) := []
        for (a, d') in trans[d]!.mergeSort (fun x y => decide (atomKey x.1 ≤ atomKey y.1)) do
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
      let lid ← match libIds.get? D with
        | some lid => pure lid
        | none => do
          let lid := H.lib.size
          libIds := libIds.insert D lid
          H := { H with lib := H.lib.push D }
          pure lid
      H := { H with lang := H.lang.set! m lid }
      hmaps := hmaps ++ [(m, (Array.range nd).map fun d => if live[d]! then ren.get? colors[d]! else none)]
      deads := deads ++ [(m, live.map (!·))]
    wits := wits.push { c, states, trans, startState, hmap := hmaps, dead := deads }
  -- fragments, now that every language is known
  let mut frags : Array (Nat × Nat) := #[]
  let mut f := 0
  while f < b.fragInner.size do
    let (fi, b1) := b.node (.fin f)
    let (en, b2) := b1.resolve (headTgt H b.fragInner[f]! fi)
    b := b2.saturate H E 0
    frags := frags.push (en, fi)
    f := f + 1
  return (H, b, wits, frags)

end Ambiguity
