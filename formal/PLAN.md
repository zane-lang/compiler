# Working plan: formally checked unambiguity (session notes, temporary)

Goal: the four milestones of docs/ambiguity/verification-roadmap.md.

## Chain (all executable in Lean, each step with a soundness theorem)

Counts are capped in S = {0,1,2}. Every step proves an UPPER bound
`count_before ≤ count_after`, so unambiguity flows backward.

- R0  automaton A (Menhir dump) -> Acc-trees (trees of A's grammar whose LR
      simulation uses only retained actions). Spec-level definition.
- R1  A -> guarded context grammar C (lr.py), then a quotient (checked morphism).
- R2  angle tagging (angles.py) checked: tags are a function of the word.
- R3  bracket grouping + guard elimination product (lookahead.py) + quotient.
      NO factor.py needed: exact.y alone proves (2704 cfgs / 31 frames / 1486).
- R5  horizontal compilation: SCC/linearity check, per-component NFA with
      inlined lower DFAs, determinization (vector certificate check),
      minimization (bisimulation check), model nodes.
- R6  visible-stack invariant check (M1). Proof uses a BACKWARD (last-edge)
      recursive path count W_n; snoc decomposition; post-fixpoint closure
      (R >= init + E(R)) dominates bounded path counts.

Source side (M3):
- GLR rewrite: X -> nonempty_X unit productions plus per-occurrence patterns
  k(keep)/n(nonempty_)/d(drop). 707/714 GLR productions align uniquely; the 7
  others are the units. rho: GLR trees -> source trees, needs each dropped
  symbol to have exactly one epsilon-tree. |rho(S)| <= |S|.
- Validate A's LR(1) items (closure/goto), actions vs items and precedence.
- Lean expansion of parser.mly (parameterized rules, %inline, standard.mly)
  compared with A's productions.

Facts: non-determinized NFA model OOMs (15 GB) -> keep det/min.
Grammar shape after grouping: bracket tokens only in productions b -> o X c | o c.

## Status log
- M1 done: Ambiguity/VpaSound.lean check_sound (std axioms only).
- Lean pipeline (Automaton, Quotient, Product, Horizontal) reproduces Python:
  ctx 36350 rules; quotient 195 reachable; product 226022/281627; exact 2341;
  model 1486 states; 2704 cfgs; 31 frames; check true. 5.5 min (optimize).
- Bug lesson: DFA minimization signatures must sort transitions.

## R5 proof plan (horizontal)
Atom level first (finite alphabet: T a | call o inner c), generic weighted
automaton theory (backward fuel paths; concat; post-fixpoint; det check as in
M1; minimization = functional simulation). Symbolic NFA nodes:
Entry m | Start | Fin | Chain(suffix, dest) | Copy(lid, d, tail).
Then lift to items: cnt_E(X,u) <= sum_{alpha in cands(u)} cnt_atoms(X,alpha)*match,
model comp nodes realize DFA runs (labelled model, keys checked).
- R2 angles proven (AnglesSound.angles_sound); needs noGTokens Q check in final pipeline.
- R3 redesign: Lookahead.lean specRules over keys nt/seq(x,i,a,b)/grp/inner/dead,
  explored + checkExplore + checkFirst. Same final model 1486/2704/31, check true.
  (sFirst must eraseDups or duplicate rules create spurious ambiguity: checker caught it.)
  Proof plan: KWF spec-level trees; SL (slices) by induction on len inside NL by
  strong induction on tree size; pi projection gives injectivity.
- R3 proven (LookaheadSound.lookahead_sound) + plain hom (Plain.phom_sound). Remaining M2: R5 horizontal+model.

## R5 detailed plan (adopted)
One universe Model holds model nodes AND per-component NFA nodes (labelled keys,
spec edges checked like checkExplore). Keys: fin f | weight tail w |
comp lid d tail (= model node and inlined lower DFA copy) | entry c m | start c |
cfin c | chain c body dest. chainId([],dest)=dest.
W lemmas needed: monotone in fuel; forward unfolding W_{b+1} >= base + sum of
first-edge terms; snoc/backward decomposition (as M1). Wsup.
Checks: (D1/D2) determinization vectors over NFA ids (isPost, filt eq),
(M) minimization map h with dead states, lang/lib.
Proof chain: cnt_E(m,u) <= W(start_m,u,final_m) <= DFA <= lib DW <= model comp W
<= fragment W; items: flatten injective via parser lemma; two trees -> cnt=2.
- WLemmas: W_mono, fwd (forward unfolding, fuel b+c+1) proven. Concat over a node is FALSE in general with fuel (eps loops) -> use fwd/backward only.
