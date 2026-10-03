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

def SourceUnambiguous (text : String) : Prop :=
  ∀ A, sourceAutomaton text = .ok A → AUnambiguous A

def verifySource (text : String) (ev : Evidence) : Bool :=
  match sourceAutomaton text with
  | .ok A => verify A ev
  | .error _ => false

theorem verifySource_sound (text : String) (ev : Evidence) (h : verifySource text ev = true) :
    SourceUnambiguous text := by
  intro A hA
  unfold verifySource at h
  rw [hA] at h
  exact verify_sound A ev h

end Ambiguity
