import Ambiguity.Universe

/-! # Checks on the universe model and the horizontal facts -/

namespace Ambiguity

section
variable (keys : Array UKey) (fragInner : Array (Option Nat))

def tgtOk : Tgt → Nat → Bool
  | .id n, t => t == n
  | .key k, t => keys[t]? == some k
  | .comp0 lid tl, t =>
    match keys[t]? with
    | some (.comp lid' d j) => lid' == lid && d == 0 && tgtOk tl j
    | _ => false

def edgeOk : SEdge → Edge → Bool
  | .eps t w, .eps t' w' => w == w' && tgtOk keys t t'
  | .int a t, .int a' t' => a == a' && tgtOk keys t t'
  | .call o inner t c, .call o' f t' c' =>
    o == o' && c == c' && fragInner[f]? == some inner && tgtOk keys t t'
  | _, _ => false

def edgesOk (spec : List SEdge) (es : List Edge) : Bool :=
  spec.length == es.length && (spec.zip es).all fun (s, e) => edgeOk keys fragInner s e
end

/-- (C1) every node's edges are its specification; (C2) fragments. -/
def checkUniverse (H : HFacts) (E : PGrammar) (keys : Array UKey) (fragInner : Array (Option Nat))
    (M : Model) : Bool :=
  keys.size == M.edges.size &&
  (List.range keys.size).all (fun j =>
    edgesOk keys fragInner (specEdges H E (keys[j]?.getD (.fin 0))) (M.out j)) &&
  M.frags.size == fragInner.size && fragInner[0]? == some (some E.start) &&
  (fragInner.toList.eraseDups.length == fragInner.size) &&
  (List.range M.frags.size).all fun f =>
    keys[M.fin f]? == some (.fin f) && tgtOk keys (headTgt H (fragInner.getD f none) (M.fin f)) (M.entry f)

/-- (C3) grammar facts: nonempty and empty-count post-fixpoints, bracket
shape, component order, membership, and linearity. -/
def hasBracket (r : List Sym) : Bool := r.any fun | .t a => isOpen a || isClose a | _ => false

def checkFacts (H : HFacts) (E : PGrammar) : Bool :=
  (List.range E.rules.size).all fun x => (E.rulesOf x).all fun r =>
    -- nonempty is closed upward; empty counts bound the rules of empty-only symbols
    ((groupRule? r).isSome || r.any (fun | .t _ => true | .n y => H.isNe y) → H.isNe x) &&
    -- brackets only in group rules
    ((groupRule? r).isSome || !hasBracket r) &&
    (!H.isNe x || (
      (H.mems (H.compOf x)).contains x &&
      (match ruleNfa H (H.compOf x) x r with | .bad => false | _ => true) &&
      ((groupRule? r).isSome ||
        r.all fun | .n y => !H.isNe y || H.compOf y == H.compOf x || decide (H.compOf y < H.compOf x)
                  | _ => true)))

/-- The rules of an empty-only symbol sum to at most its count (separately,
since `checkFacts` bounds each rule only). -/
def checkEps (H : HFacts) (E : PGrammar) : Bool :=
  (List.range E.rules.size).all fun x =>
    H.isNe x || decide (sumL (E.rulesOf x) (fun r =>
      r.foldl (fun acc s => acc * match s with | .n y => H.epsOf y | _ => 0) 1) ≤ H.epsOf x)

def checkMembers (H : HFacts) : Bool :=
  (List.range H.members.size).all fun c => (H.mems c).all fun m => H.isNe m && H.compOf m == c

/-- (C4) determinization and minimization witnesses. -/
def checkWit (H : HFacts) (keys : Array UKey) (idx : Std.HashMap UKey Nat) (fragInner : Array (Option Nat))
    (M : Model) (w : CompWit) : Bool :=
  let mems := H.mems w.c
  let ids : UKey → Option Nat := fun k =>
    match idx.get? k with
    | some j => if keys[j]? == some k then some j else none
    | none => none
  match mems.mapM (fun m => (ids (startNode H w.c m), ids (finalNode H w.c m)).1.bind fun s =>
      (ids (finalNode H w.c m)).map fun f => (m, s, f)) with
  | none => false
  | some sf =>
    let finals := sf.map (·.2.2)
    let st := fun (d : Nat) => w.states.getD d []
    -- every state's successors are post-fixpoint closures with the recorded kept part
    (List.range w.states.size).all (fun d =>
      let V := st d
      let atoms := (V.flatMap fun e => (M.out e.2.1).filterMap (atomOfEdge fragInner)).eraseDups
      atoms.all fun a =>
        match (w.trans.getD d []).lookup a with
        | none => false
        | some d' =>
          let c := edgeCounts M V (atomH fragInner a)
          let R := closure M c
          isPost M c R && filtH M finals R == st d') &&
    sf.all fun (m, s, fnode) =>
      match w.startState.lookup m, w.hmap.lookup m, w.dead.lookup m with
      | some s0, some h, some dd =>
        let R := closure M [(0, s, 1)]
        let isDead := fun d => dd.getD d false
        isPost M [(0, s, 1)] R && filtH M finals R == st s0 &&
        h.getD s0 none == some 0 &&
        let D := H.dfa (H.langOf m)
        (List.range w.states.size).all fun d =>
          let accd := getV (st d) 0 fnode
          (match h.getD d none with
           | some e =>
             decide (accd ≤ D.accAt e) &&
             (w.trans.getD d []).all fun (a, d') =>
               match h.getD d' none with
               | some e' => (D.transAt e).lookup a == some e'
               | none => isDead d'
           | none => true) &&
          (!isDead d || (accd == 0 && (w.trans.getD d []).all fun (_, d') => isDead d'))
      | _, _, _ => false

def checkWits (H : HFacts) (keys : Array UKey) (idx : Std.HashMap UKey Nat) (fragInner : Array (Option Nat))
    (M : Model) (wits : Array CompWit) : Bool :=
  -- every component with members has a witness
  (List.range H.members.size).all (fun c => (H.mems c).isEmpty || wits.any (·.c == c)) &&
  wits.all (checkWit H keys idx fragInner M)

end Ambiguity
