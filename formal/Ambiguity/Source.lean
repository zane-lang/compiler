import Ambiguity.Pipeline
import Ambiguity.Lr1

/-!
# The source grammar's parse relation

`SourceUnambiguous text` is the target theorem of the verification roadmap,
stated for the text of a Menhir grammar file: the parse relation that the
file's precedence declarations define (`Lr1.canonical` of the expanded
grammar `Mly.sourceGrammar`) assigns at most one tree to every token string.
-/

namespace Ambiguity

def sourceAutomaton (text : String) : Except String Automaton := do
  Lr1.canonical (← Mly.sourceGrammar text)

/-- The file defines a parse relation, and that relation is unambiguous. -/
def SourceUnambiguous (text : String) : Prop :=
  ∃ A, sourceAutomaton text = .ok A ∧ AUnambiguous A

def verifySource (text : String) (ev : Evidence) : Bool :=
  match sourceAutomaton text with
  | .ok A => verify A ev
  | .error _ => false

theorem verifySource_sound (text : String) (ev : Evidence) (h : verifySource text ev = true) :
    SourceUnambiguous text := by
  unfold verifySource at h
  cases hA : sourceAutomaton text with
  | error e => rw [hA] at h; cases h
  | ok A =>
    rw [hA] at h
    exact ⟨A, hA, verify_sound A ev h⟩

end Ambiguity
