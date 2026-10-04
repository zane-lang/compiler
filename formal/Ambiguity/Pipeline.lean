import Ambiguity.HorizMain
import Ambiguity.CtxSound
import Ambiguity.QuotientSound
import Ambiguity.AnglesSound
import Ambiguity.LookaheadSound
import Ambiguity.Json

/-!
# The whole pipeline

`verify A ev` runs every check, from the LR automaton `A` to the counted
model's certificate, on evidence `ev` that an unverified producer computed.
`verify_sound` states what a `true` answer means: the automaton's accepted
trees are determined by their yields.
-/

namespace Ambiguity

/-- Everything the producer computes; none of it is trusted. -/
structure Evidence where
  Q : GGrammar
  hQ : Array Nat
  S : AngleSets
  first : Std.HashMap (Nat × Tok) (List (Option Tok))
  L : LGrammar
  E : PGrammar
  hE : Array Nat
  H : HFacts
  keys : Array UKey
  idx : Std.HashMap UKey Nat
  fI : Array (Option Nat)
  M : Model
  wits : Array CompWit
  C : Cert

def Evidence.F (ev : Evidence) : FirstTbl := fun y t => ev.first.getD (y, t) []

def verify (A : Automaton) (ev : Evidence) : Bool :=
  A.wf && checkHom A.ctxGrammar ev.Q (fun x => ev.hQ[x]!) && noGTokens ev.Q &&
  checkAngles (tagGrammar ev.Q) ev.S && checkFirst (tagGrammar ev.Q) ev.F &&
  checkExplore (tagGrammar ev.Q) ev.F ev.L && pcheckHom ev.L.plain ev.E (fun x => ev.hE[x]!) &&
  checkUniverse ev.H ev.E ev.keys ev.fI ev.M && checkFacts ev.H ev.E && checkEps ev.H ev.E &&
  checkLib ev.H && checkKeys ev.keys ev.idx && checkInners ev.E ev.fI &&
  checkWits ev.H ev.keys ev.idx ev.fI ev.M ev.wits && check zaneBrackets ev.M ev.C

/-- **End-to-end soundness.** -/
theorem verify_sound (A : Automaton) (ev : Evidence) (h : verify A ev = true) : AUnambiguous A := by
  simp only [verify, Bool.and_eq_true] at h
  obtain ⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨hwf, hhom⟩, hno⟩, hang⟩, hfirst⟩, hexp⟩, hpc⟩, hU⟩, hF⟩, hE⟩, hL⟩, hK⟩, hI⟩, hW⟩,
    hc⟩ := h
  have hroot := check_sound zaneBrackets ev.M ev.C hc
  have hcall : ∀ p, ∀ e ∈ ev.M.out p, ∀ o f t c, e = .call o f t c → f < ev.fI.size := by
    intro p e he o f t c hec
    have := check_calls hc p e he o f t c hec
    rwa [(universe_parts ev.H ev.E ev.keys ev.fI ev.M hU).2.2.1] at this
  have hP := horiz_sound ev.H ev.E ev.keys ev.fI ev.M hU ev.idx hK hL ev.wits hW hF hE hI hcall hroot
  have hLp := phom_sound hpc hP
  have hT := lookahead_sound (tagGrammar ev.Q) ev.F hfirst ev.L hexp hLp
  have hQu := angles_sound ev.Q ev.S hno hang hT
  exact ctx_sound A hwf (hom_sound hhom hQu)

/-! ## Producer (unverified) -/

def produce (A : Automaton) (fuel : Nat := 1000000) : Except String Evidence := do
  let C := A.ctxGrammar
  let (Q, hQ) := quotient C (fun x => x % A.nts.size)
  let T := tagGrammar Q
  let S := angleSets T
  let first := firstTable T
  let F : FirstTbl := fun y t => first.getD (y, t) []
  let L := explore T F
  let (E, hE) := pquotient L.plain
  let (H, ub, wits, frags) ← buildUniverse E
  let M := ub.model frags
  let cert ← search zaneBrackets M fuel
  return { Q, hQ, S, first, L, E, hE, H, keys := ub.keys, idx := ub.ids, fI := ub.fragInner, M, wits, C := cert }

end Ambiguity
