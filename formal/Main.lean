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
    let ft := firstTable T
    let F : FirstTbl := fun y t => ft.getD (y, t) []
    say s!"first table: {checkFirst T F}"
    let L := explore T F
    let lr := L.rules.foldl (fun a rs => a + rs.length) 0
    say s!"lookahead product: {L.keys.size} keys, {lr} rules, closure check {checkExplore T F L}"
    let (E, _) := pquotient L.plain
    let er := E.rules.foldl (fun a rs => a + rs.length) 0
    say s!"exact: {E.rules.size} nonterminals, {er} rules"
    let symName := fun (s : Sym) => match s with | .t a => a | .n y => s!"n{y}"
    let mut txt := "%token X\n%start n0\n%%\n"
    for x in List.range E.rules.size do
      let rs := E.rulesOf x
      if rs.isEmpty then continue
      txt := txt ++ s!"n{x} : " ++ " | ".intercalate (rs.map fun r => " ".intercalate (r.map symName)) ++ " ;\n"
    IO.FS.writeFile "/tmp/claude-0/lean-exact.y" txt
    let (H, ub, wits, frags) ← IO.ofExcept (buildUniverse E)
    say s!"horizontal: {wits.size} components, {H.lib.size} languages, {H.lib.foldl (fun a D => a + D.trans.size) 0} states"
    let M := ub.model frags
    say s!"universe: {M.size} nodes, {M.frags.size} fragments"
    say s!"universe check: {checkUniverse H E ub.keys ub.fragInner M}"
    say s!"facts check: {checkFacts H E && checkEps H E && checkMembers H && checkLib H}"
    say s!"keys check: {checkKeys ub.keys ub.ids}, inners check: {checkInners E ub.fragInner}"
    say s!"witness check: {checkWits H ub.keys ub.ids ub.fragInner M wits}"
    let cert ← IO.ofExcept (search zaneBrackets M 1000000)
    let cfgs := cert.frames.foldl (fun a K => a + K.nodes.length) 0
    say s!"search: {cfgs} configurations, {cert.frames.length} frames"
    say s!"check: {check zaneBrackets M cert}"
    return 0
  | _ => IO.eprintln "usage"; return 2
