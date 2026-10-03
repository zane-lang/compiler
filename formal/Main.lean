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
  | ["prove-source", mly] =>
    -- `verifySource_sound`: a true check makes the source parse relation unambiguous
    let text ← IO.FS.readFile mly
    match sourceAutomaton text with
    | .error e => IO.println s!"REJECTED: {e}"; return 2
    | .ok A =>
      say s!"source: {A.prods.size} productions, canonical LR(1) automaton with {A.trans.size} states"
      match produce A with
      | .error e => IO.println s!"REJECTED: producer failed: {e}"; return 1
      | .ok ev =>
        if verifySource text ev then
          say s!"VERIFIED: the source parse relation of {mly} is unambiguous ({ev.M.size} model nodes, {ev.C.frames.length} frames)"
          return 0
        else
          IO.println "REJECTED"
          return 1
  | ["prove-glr", mly, dump] =>
    -- `verifyGlr_sound`: a true check gives `GlrSound`, the GLR parser's relation
    -- unambiguous and read injectively as derivations of the source grammar
    let text ← IO.FS.readFile mly
    let G ← IO.ofExcept (parseDump (← IO.FS.readFile dump) "package")
    let S ← IO.ofExcept (sourceGrammarAut text)
    let (corr, base, eps) ← match produceCorr G S with
      | .ok r => pure r
      | .error e => IO.println s!"REJECTED: correspondence producer failed: {e}"; return 1
    let units := corr.foldl (fun n c => match c with | .unit => n + 1 | _ => n) 0
    say s!"correspondence: {G.prods.size} GLR productions against {S.prods.size} source productions ({units} unit), check {checkCorr G S corr base eps}"
    match produce G with
    | .error e => IO.println s!"REJECTED: producer failed: {e}"; return 1
    | .ok ev =>
      if verifyGlr text G { ev, corr, base, eps } then
        say s!"VERIFIED: the GLR relation of {dump} is unambiguous and corresponds to {mly} ({G.trans.size} LR states, {ev.M.size} model nodes, {ev.C.frames.length} frames)"
        return 0
      else
        IO.println "REJECTED"
        return 1
  | ["verify", dump] =>
    -- `verify_sound`: a true `verify` makes the automaton's accepted trees unambiguous
    let A ← IO.ofExcept (parseDump (← IO.FS.readFile dump) "package")
    match produce A with
    | .error e => IO.println s!"REJECTED: producer failed: {e}"; return 1
    | .ok ev =>
      if verify A ev then
        say s!"VERIFIED: {A.trans.size} LR states, {ev.E.rules.size} grammar symbols, {ev.M.size} model nodes, {ev.C.frames.length} frames"
        return 0
      else
        IO.println "REJECTED"
        return 1
  | ["expand", mly] =>
    match Mly.sourceGrammar (← IO.FS.readFile mly) with
    | .error e => IO.eprintln e; return 2
    | .ok g =>
      for p in g.prods do
        IO.println s!"{p.lhs}: {" ".intercalate p.rhs}{match p.prec with | some x => " %prec " ++ x | none => ""}"
      return 0
  | ["compare", mly, dump] =>
    -- cross-check the canonical construction against a Menhir --canonical dump
    let g ← IO.ofExcept (Mly.sourceGrammar (← IO.FS.readFile mly))
    let A ← IO.ofExcept (Lr1.canonical g)
    let B0 ← IO.ofExcept (parseDump (← IO.FS.readFile dump) g.start)
    let mg := fun (x : String) => String.map (fun ch => if ch == '(' || ch == ',' || ch == ')' then '_' else ch) x
    let B : Automaton := { B0 with
      prods := B0.prods.map fun (l, r) => (mg l, r.map mg)
      trans := B0.trans.map fun l => l.map fun (x, q) => (mg x, q) }
    say s!"lean: {A.trans.size} states, menhir: {B.trans.size} states"
    let key := fun (X : Automaton) (p : Nat) => X.prods.getD p ("", [])
    let mut map : Std.HashMap Nat Nat := ({} : Std.HashMap Nat Nat).insert 0 0
    let mut todo : List (Nat × Nat) := [(0, 0)]
    let mut diffs := 0
    while !todo.isEmpty do
      let (a, b) :: rest := todo | break
      todo := rest
      let ta := A.trans.getD a []
      let tb := B.trans.getD b []
      if (ta.map (·.1)).mergeSort != (tb.map (·.1)).mergeSort then
        diffs := diffs + 1
        if diffs ≤ 10 then say s!"state {a}/{b}: transitions {ta.map (·.1)} vs {tb.map (·.1)}"
      for (x, a') in ta do
        match tb.lookup x with
        | some b' =>
          match map.get? a' with
          | some b'' => if b'' != b' then diffs := diffs + 1; if diffs ≤ 10 then say s!"state {a'} maps to {b''} and {b'}"
          | none => map := map.insert a' b'; todo := todo ++ [(a', b')]
        | none => pure ()
      let ra := ((A.reds.getD a []).map fun (p, ts) => (key A p, ts.mergeSort)).mergeSort (fun u v => toString u ≤ toString v)
      let rb := ((B.reds.getD b []).map fun (p, ts) => (key B p, ts.mergeSort)).mergeSort (fun u v => toString u ≤ toString v)
      if ra != rb then
        diffs := diffs + 1
        if diffs ≤ 10 then say s!"state {a}/{b}: reductions {ra} vs {rb}"
    say s!"mapped {map.size} states, {diffs} differences"
    return (if diffs == 0 && map.size == A.trans.size && A.trans.size == B.trans.size then 0 else 1)
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
