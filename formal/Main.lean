import Ambiguity
open Ambiguity

def say (s : String) : IO Unit := do
  IO.println s
  (← IO.getStdout).flush

def reachable (G : GGrammar) : Array Bool := Id.run do
  let mut seen := Array.replicate G.rules.size false
  let mut stack := [G.start]
  seen := seen.set! G.start true
  let mut count := 0
  while true do
    match stack with
    | [] => break
    | x :: rest =>
      stack := rest
      count := count + 1
      for r in G.rulesOf x do
        if r.guard.isEmpty then continue
        for s in r.rhs do
          match s with
          | .n y => if !seen[y]! then seen := seen.set! y true; stack := y :: stack
          | _ => pure ()
  return seen

def main (args : List String) : IO UInt32 := do
  match args with
  | ["certificate", path] =>
    let text ← IO.FS.readFile path
    let j ← IO.ofExcept (Lean.Json.parse text)
    let (M, C) ← IO.ofExcept (parseCert j)
    if check zaneBrackets M C then
      say s!"VERIFIED: {M.size} model states, {C.frames.length} frames"
      return 0
    else
      IO.println "REJECTED"
      return 1
  | ["stats", dump] =>
    let A ← IO.ofExcept (parseDump (← IO.FS.readFile dump) "package")
    say s!"states {A.trans.size} productions {A.prods.size} nts {A.nts.size}"
    let C := A.ctxGrammar
    let seen := reachable C
    let mut nts := 0
    let mut rules := 0
    for i in List.range C.rules.size do
      if seen[i]! then
        nts := nts + 1
        rules := rules + ((C.rulesOf i).filter (!·.guard.isEmpty)).length
    say s!"context grammar: {nts} reachable nonterminals, {rules} usable rules"
    let (Q, h) := quotient C (fun x => x % A.nts.size)
    let ok := checkHom C Q (fun x => h[x]!)
    let seenQ := reachable Q
    let mut qn := 0
    let mut qr := 0
    for i in List.range Q.rules.size do
      if seenQ[i]! then
        qn := qn + 1
        qr := qr + ((Q.rulesOf i).filter (!·.guard.isEmpty)).length
    say s!"quotient: {Q.rules.size} classes, {qn} reachable, {qr} usable rules, hom check {ok}"
    let T := tagGrammar Q
    say s!"angles: {checkAngles T (angleSets T)}"
    let Gr := groupGrammar T
    let n0 := T.rules.size
    let wrapped := fun x => x ≥ n0 && (match (Gr.rulesOf x).head? with
      | some r => match r.rhs.head? with | some (.t o) => isOpen o | _ => false
      | none => false)
    say s!"grouped: {Gr.rules.size - n0} new nonterminals"
    let (P, _) := product Gr wrapped
    let pr := P.rules.foldl (fun a rs => a + rs.length) 0
    say s!"product: {P.rules.size} nonterminals, {pr} rules"
    let (E, _) := pquotient P
    let er := E.rules.foldl (fun a rs => a + rs.length) 0
    say s!"exact: {E.rules.size} nonterminals, {er} rules"
    let symName := fun (s : Sym) => match s with | .t a => a | .n y => s!"n{y}"
    let mut txt := "%token X\n%start n0\n%%\n"
    for x in List.range E.rules.size do
      let rs := E.rulesOf x
      if rs.isEmpty then continue
      txt := txt ++ s!"n{x} : " ++ " | ".intercalate (rs.map fun r => " ".intercalate (r.map symName)) ++ " ;\n"
    IO.FS.writeFile "/tmp/claude-0/lean-exact.y" txt
    let Cm ← IO.ofExcept (compile E)
    say s!"horizontal: {Cm.ncomp} components, {Cm.lib.size} languages, {Cm.lib.foldl (fun a D => a + D.trans.size) 0} states"
    let M := buildModel Cm E.start
    say s!"model: {M.size} states, {M.frags.size} fragments"
    let cert ← IO.ofExcept (search zaneBrackets M 1000000)
    let cfgs := cert.frames.foldl (fun a K => a + K.nodes.length) 0
    say s!"search: {cfgs} configurations, {cert.frames.length} frames"
    say s!"check: {check zaneBrackets M cert}"
    return 0
  | _ => IO.eprintln "usage"; return 2
