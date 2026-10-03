import Ambiguity.S
import Std.Data.HashMap
import Std.Data.HashSet

/-!
# Counted visibly pushdown models and their certificate checker

A model is a finite graph whose edges are epsilon edges with a weight in `S`,
internal edges that read one ordinary token, and call edges that read a whole
bracket group: an opening token, a balanced interior accepted by a child
fragment, and the matching closing token. A fragment is a pair of nodes
(entry, end).

`W M n q v r` is the capped weighted number of paths of at most `n` edges from
`q` to `r` reading the structured word `v`, where the interior of each bracket
group is counted, again with at most `n` edges, by the called fragment. It is
defined by the *last* edge of a path, which is the shape the checker's
closure argument needs. Taking every `n` covers every path, so a bound that
holds for every `n` bounds the number of all paths.
-/

namespace Ambiguity

abbrev Tok := String

inductive Edge where
  | eps (to : Nat) (w : S)
  | int (a : Tok) (to : Nat)
  | call (o : Tok) (f : Nat) (ret : Nat) (c : Tok)
  deriving Repr, Inhabited, DecidableEq

structure Model where
  edges : Array (List Edge)
  frags : Array (Nat × Nat)

namespace Model
def size (M : Model) : Nat := M.edges.size
def out (M : Model) (q : Nat) : List Edge := M.edges.getD q []
def entry (M : Model) (f : Nat) : Nat := (M.frags.getD f (0, 0)).1
def fin (M : Model) (f : Nat) : Nat := (M.frags.getD f (0, 0)).2
end Model

/-- A structured word: ordinary tokens and bracket groups. -/
inductive Item where
  | tok (a : Tok)
  | grp (o : Tok) (inner : List Item) (c : Tok)
  deriving Repr, Inhabited

mutual
def Item.sz : Item → Nat
  | .tok _ => 1
  | .grp _ inner _ => 1 + itemsSz inner
def itemsSz : List Item → Nat
  | [] => 0
  | x :: xs => x.sz + itemsSz xs
end

/-- What edge `e`, leaving `p`, contributes to paths from `q` to `r` reading
`v`, given the counts `Wn` of shorter paths. -/
def stepC (M : Model) (Wn : Nat → List Item → Nat → S) (q : Nat) (v : List Item)
    (r : Nat) (p : Nat) : Edge → S
  | .eps t w => if t = r then Wn q v p * w else 0
  | .int a t =>
    if t = r then
      match v.getLast? with
      | some (.tok b) => if a = b then Wn q v.dropLast p else 0
      | _ => 0
    else 0
  | .call o f t c =>
    if t = r then
      match v.getLast? with
      | some (.grp o' inner c') =>
        if o = o' ∧ c = c' then Wn q v.dropLast p * Wn (M.entry f) inner (M.fin f) else 0
      | _ => 0
    else 0

def base (q : Nat) (v : List Item) (r : Nat) : S :=
  if v.isEmpty ∧ q = r then 1 else 0

/-- Capped number of paths of at most `n` edges. -/
def W (M : Model) : Nat → Nat → List Item → Nat → S
  | 0 => fun q v r => base q v r
  | n + 1 => fun q v r =>
    base q v r + sumL (List.range M.size) fun p => sumL (M.out p) fun e => stepC M (W M n) q v r p e

/-- A model accepts a word ambiguously when two paths, or one path through a
weight-2 edge, lead from the root fragment's entry to its end. -/
def RootUnambiguous (M : Model) : Prop :=
  ∀ (v : List Item) (n : Nat), W M n (M.entry 0) v (M.fin 0) ≤ 1

/-! ## Certificates -/

/-- Weighted control vector: entries `(fragment, node, weight)`. -/
abbrev Vec := List (Nat × Nat × S)

def getV (V : Vec) (f q : Nat) : S :=
  sumL V fun e => if e.1 = f ∧ e.2.1 = q then e.2.2 else 0

def Edge.isEps : Edge → Bool
  | .eps .. => true
  | _ => false

def Model.isEnd (M : Model) (q : Nat) : Bool := M.frags.toList.any fun fr => fr.2 == q
def Model.kept (M : Model) (q : Nat) : Bool := M.isEnd q || (M.out q).any fun e => !e.isEps

def filt (M : Model) (V : Vec) : Vec := V.filter fun e => M.kept e.2.1

/-- Total weight of epsilon edges from `p` to `t`. -/
def epsW (M : Model) (p t : Nat) : S :=
  sumL (M.out p) fun
    | .eps t' w => if t' = t then w else 0
    | _ => 0

/-- Weight flowing along epsilon edges into `(f, t)` from the vector `R`. -/
def epsIn (M : Model) (R : Vec) (f t : Nat) : S :=
  sumL R fun e => if e.1 = f then e.2.2 * epsW M e.2.1 t else 0

/-- Keys whose post-fixpoint inequality could be nontrivial. -/
def postKeys (M : Model) (c R : Vec) : List (Nat × Nat) :=
  c.map (fun e => (e.1, e.2.1)) ++
    R.flatMap fun e => (M.out e.2.1).filterMap fun
      | .eps t _ => some (e.1, t)
      | _ => none

/-- `R` is a post-fixpoint of epsilon closure from `c`: `c + E(R) ≤ R`. -/
def isPost (M : Model) (c R : Vec) : Bool :=
  (postKeys M c R).all fun k => decide (getV c k.1 k.2 + epsIn M R k.1 k.2 ≤ getV R k.1 k.2)

/-! ### Unverified producer: exact epsilon closure by delta propagation -/

def vecLt (a b : Nat × Nat × S) : Bool := a.1 < b.1 || (a.1 == b.1 && a.2.1 < b.2.1)

/-- Kleene iteration `m ← c + E(m)` from `c` until stable: the least
fixpoint, hence the exact capped closure. Unverified: `isPost` checks it. -/
partial def closure (M : Model) (c : Vec) : Vec := Id.run do
  let mut init : Std.HashMap (Nat × Nat) S := {}
  for (f, q, w) in c do
    init := init.insert (f, q) (init.getD (f, q) 0 + w)
  let mut m := init
  let mut changed := true
  while changed do
    let mut next := init
    for ((f, q), cur) in m.toList do
      for e in M.out q do
        match e with
        | .eps t w => next := next.insert (f, t) (next.getD (f, t) 0 + cur * w)
        | _ => pure ()
    changed := next.size != m.size || next.toList.any fun (k, w) => m.getD k 0 != w
    m := next
  let l := m.toList.filterMap fun ((f, q), w) => if w == 0 then none else some (f, q, w)
  return l.mergeSort fun a b => !(vecLt b a)

/-- The certificate's frames. -/
structure Frame where
  fs : List Nat
  closer : Option Tok
  nodes : List Vec
  exits : List (List (Nat × S))
  deriving Inhabited

structure Cert where
  frames : List Frame

def accOf (M : Model) (fs : List Nat) (N : Vec) : List (Nat × S) :=
  fs.filterMap fun f => if getV N f (M.fin f) = 0 then none else some (f, getV N f (M.fin f))

def exGet (ex : List (Nat × S)) (f : Nat) : S := sumL ex fun e => if e.1 = f then e.2 else 0

/-- Closed successor check: the closure of `c` is a post-fixpoint whose kept
part is a node of the frame. An empty `c` needs no successor. -/
def succOk (M : Model) (nodes : Std.HashSet Vec) (c : Vec) : Bool :=
  c.isEmpty ||
    let R := closure M c
    isPost M c R && nodes.contains (filt M R)

/-- Successor counts along non-epsilon edges selected by `h`: an edge `e`
leaving an entry `(f, p, w)` with `h e = some (t, m)` contributes `(f, t, w * m)`. -/
def edgeCounts (M : Model) (N : Vec) (h : Edge → Option (Nat × S)) : Vec :=
  N.flatMap fun e => (M.out e.2.1).filterMap fun ed => (h ed).map fun tm => (e.1, tm.1, e.2.2 * tm.2)

def intH (a : Tok) : Edge → Option (Nat × S)
  | .int b t => if b = a then some (t, 1) else none
  | _ => none

def retH (o : Tok) (ex : List (Nat × S)) : Edge → Option (Nat × S)
  | .call o' cf t _ => if o' = o then some (t, exGet ex cf) else none
  | _ => none

def intCounts (M : Model) (N : Vec) (a : Tok) : Vec := edgeCounts M N (intH a)
def retCounts (M : Model) (N : Vec) (o : Tok) (ex : List (Nat × S)) : Vec :=
  edgeCounts M N (retH o ex)

def tokensOf (M : Model) (N : Vec) : List Tok :=
  N.flatMap fun e => (M.out e.2.1).filterMap fun
    | .int b _ => some b
    | _ => none

def openersOf (M : Model) (N : Vec) : List Tok :=
  N.flatMap fun e => (M.out e.2.1).filterMap fun
    | .call o .. => some o
    | _ => none

/-- Child fragments called on `o`. -/
def childrenOf (M : Model) (N : Vec) (o : Tok) : List Nat :=
  N.flatMap fun e => (M.out e.2.1).filterMap fun
    | .call o' cf _ _ => if o' = o then some cf else none
    | _ => none

def dedupSorted (l : List Nat) : List Nat :=
  (l.mergeSort fun a b => a ≤ b).eraseDups

def strictSorted : List Nat → Bool
  | a :: b :: l => a < b && strictSorted (b :: l)
  | _ => true

def findFrame (C : Cert) (fs : List Nat) (cl : Option Tok) : Option Frame :=
  C.frames.find? fun K => K.fs == fs && K.closer == cl

/-- The checker. `br` maps each opening bracket to its closing bracket. -/
def checkModel (br : Tok → Option Tok) (M : Model) : Bool :=
  0 < M.frags.size &&
  (List.range M.size).all fun q => (M.out q).all fun
    | .call o f _ c => br o == some c && decide (f < M.frags.size)
    | _ => true

def checkNode (br : Tok → Option Tok) (M : Model) (C : Cert) (K : Frame) (isRoot : Bool)
    (nodes : Std.HashSet Vec) (N : Vec) : Bool :=
  -- entries are nonzero, belong to the frame, and sit on kept nodes
  N.all (fun e => e.2.2 != 0 && K.fs.contains e.1 && M.kept e.2.1) &&
  -- acceptance summary is claimed, and the root never accepts twice
  (let acc := accOf M K.fs N; acc.isEmpty || K.exits.contains acc) &&
  (!isRoot || decide (getV N 0 (M.fin 0) ≤ 1)) &&
  -- internal successors
  (tokensOf M N).all (fun a => succOk M nodes (intCounts M N a)) &&
  -- returns from calls
  (openersOf M N).all fun o =>
    let cfs := childrenOf M N o
    match br o with
    | none => false
    | some cl =>
      match findFrame C (dedupSorted cfs) (some cl) with
      | none => false
      | some K' => cfs.all (fun cf => K'.fs.contains cf) &&
          K'.exits.all fun ex => succOk M nodes (retCounts M N o ex)

def checkFrame (br : Tok → Option Tok) (M : Model) (C : Cert) (K : Frame) : Bool :=
  let nodes := Std.HashSet.ofList K.nodes
  let isRoot := K.fs == [0] && K.closer == none
  strictSorted K.fs && !K.nodes.isEmpty &&
  succOk M nodes (K.fs.map fun f => (f, M.entry f, 1)) &&
  K.nodes.all (checkNode br M C K isRoot nodes)

def check (br : Tok → Option Tok) (M : Model) (C : Cert) : Bool :=
  checkModel br M &&
  (findFrame C [0] none).isSome &&
  C.frames.all (checkFrame br M C)

end Ambiguity
