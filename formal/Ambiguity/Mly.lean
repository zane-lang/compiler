import Std.Data.HashMap
import Std.Data.HashSet

/-!
# Menhir grammar files

The source grammar's meaning, read directly from `parser.mly` and Menhir's
`standard.mly`: tokens with their aliases, the precedence table, and the rules,
expanded the way Menhir's front end expands them (parameterized symbols
instantiated, `%inline` symbols substituted, token aliases resolved). Semantic
actions, types and attributes are skipped; they do not affect which trees the
grammar has.

This file is the definition of the source grammar used by the theorem, so it is
kept close to the manual and to Menhir's `Inlining.ml`: an instance
`f(a1, ..., an)` is named `f_a1_..._an_` as Menhir names it, and a `%prec`
annotation of an inlined production moves to its host.
-/

namespace Ambiguity.Mly

inductive Tk where
  | id (s : String)
  | str (s : String)
  | kw (s : String)
  | colon | bar | lp | rp | comma | eq | semi | act | ty
  deriving Repr, BEq, Inhabited

/-! ## Lexing -/

def isIdChar (c : Char) : Bool := c.isAlphanum || c == '_' || c == '\'' || c == '.'

/-- Skip an OCaml comment starting after its opening `(*`; nested comments count. -/
partial def skipOCamlComment (s : Array Char) (i : Nat) (depth : Nat := 1) : Nat :=
  if i + 1 ≥ s.size then s.size
  else if s[i]! == '(' && s[i+1]! == '*' then skipOCamlComment s (i + 2) (depth + 1)
  else if s[i]! == '*' && s[i+1]! == ')' then
    if depth == 1 then i + 2 else skipOCamlComment s (i + 2) (depth - 1)
  else if s[i]! == '"' then skipOCamlComment s (skipString s (i + 1)) depth
  else skipOCamlComment s (i + 1) depth
where
  skipString (s : Array Char) (i : Nat) : Nat :=
    if i ≥ s.size then s.size
    else if s[i]! == '\\' then skipString s (i + 2)
    else if s[i]! == '"' then i + 1
    else skipString s (i + 1)
  termination_by s.size - i
  decreasing_by all_goals omega

/-- Skip an OCaml character literal at `i` (the opening quote), if it is one. -/
def skipChar (s : Array Char) (i : Nat) : Nat :=
  if i + 2 < s.size && s[i+1]! != '\\' && s[i+2]! == '\'' then i + 3
  else if i + 3 < s.size && s[i+1]! == '\\' && s[i+3]! == '\'' then i + 4
  else if i + 1 < s.size && s[i+1]! == '\\' then
    -- '\ddd' or '\xhh'
    Id.run do
      let mut j := i + 2
      while j < s.size && s[j]! != '\'' && j < i + 6 do j := j + 1
      return j + 1
  else i + 1

/-- Skip a semantic action starting after its `{`; braces nest, and strings,
characters and comments inside are OCaml's. -/
partial def skipAction (s : Array Char) (i : Nat) (depth : Nat := 1) : Nat :=
  if i ≥ s.size then s.size
  else
    let c := s[i]!
    if c == '{' then skipAction s (i + 1) (depth + 1)
    else if c == '}' then (if depth == 1 then i + 1 else skipAction s (i + 1) (depth - 1))
    else if c == '"' then skipAction s (skipOCamlComment.skipString s (i + 1)) depth
    else if c == '\'' then skipAction s (skipChar s i) depth
    else if c == '(' && i + 1 < s.size && s[i+1]! == '*' then skipAction s (skipOCamlComment s (i + 2)) depth
    else skipAction s (i + 1) depth

/-- Skip an OCaml type after `<`, up to the matching `>` (an arrow's `>` does not close it). -/
partial def skipType (s : Array Char) (i : Nat) (depth : Nat := 1) : Nat :=
  if i ≥ s.size then s.size
  else if s[i]! == '-' && i + 1 < s.size && s[i+1]! == '>' then skipType s (i + 2) depth
  else if s[i]! == '<' then skipType s (i + 1) (depth + 1)
  else if s[i]! == '>' then (if depth == 1 then i + 1 else skipType s (i + 1) (depth - 1))
  else skipType s (i + 1) depth

partial def closeC (s : Array Char) (j : Nat) : Nat :=
  if j + 1 ≥ s.size then s.size
  else if s[j]! == '*' && s[j+1]! == '/' then j + 2 else closeC s (j + 1)

partial def eol (s : Array Char) (j : Nat) : Nat := if j ≥ s.size || s[j]! == '\n' then j else eol s (j + 1)

partial def closeHeader (s : Array Char) (j : Nat) : Nat :=
  if j + 1 ≥ s.size then s.size
  else if s[j]! == '%' && s[j+1]! == '}' then j + 2 else closeHeader s (j + 1)

partial def word (s : Array Char) (j : Nat) : Nat := if j < s.size && isIdChar s[j]! then word s (j + 1) else j

partial def closeAttr (s : Array Char) (j : Nat) (d : Nat) : Nat :=
  if j ≥ s.size then s.size
  else if s[j]! == '[' then closeAttr s (j + 1) (d + 1)
  else if s[j]! == ']' then (if d == 1 then j + 1 else closeAttr s (j + 1) (d - 1))
  else closeAttr s (j + 1) d

partial def lexAux (s : Array Char) (i : Nat) (acc : Array Tk) (sections : Nat) : Array Tk :=
  if i ≥ s.size then acc
  else
    let c := s[i]!
    let next := fun (j : Nat) (t : Tk) => lexAux s j (acc.push t) sections
    if c.isWhitespace then lexAux s (i + 1) acc sections
    else if c == '(' && i + 1 < s.size && s[i+1]! == '*' then lexAux s (skipOCamlComment s (i + 2)) acc sections
    else if c == '/' && i + 1 < s.size && s[i+1]! == '*' then
      lexAux s (closeC s (i + 2)) acc sections
    else if c == '/' && i + 1 < s.size && s[i+1]! == '/' then
      lexAux s (eol s i) acc sections
    else if c == '%' && i + 1 < s.size && s[i+1]! == '{' then
      lexAux s (closeHeader s (i + 2)) acc sections
    else if c == '%' && i + 1 < s.size && s[i+1]! == '%' then
      -- the second `%%` starts the trailer, which is OCaml code
      if sections == 1 then acc.push (.kw "%%") else lexAux s (i + 2) (acc.push (.kw "%%")) (sections + 1)
    else if c == '%' then
      let j := word s (i + 1)
      next j (.kw ("%" ++ String.ofList (s.extract (i + 1) j).toList))
    else if c == '{' then next (skipAction s (i + 1)) .act
    else if c == '<' then next (skipType s (i + 1)) .ty
    else if c == '[' && i + 1 < s.size && s[i+1]! == '@' then
      -- an attribute
      lexAux s (closeAttr s (i + 1) 1) acc sections
    else if c == '"' then
      let j := skipOCamlComment.skipString s (i + 1)
      next j (.str (String.ofList (s.extract (i + 1) (j - 1)).toList))
    else if isIdChar c then
      let j := word s i
      next j (.id (String.ofList (s.extract i j).toList))
    else if c == ':' then next (i + 1) .colon
    else if c == '|' then next (i + 1) .bar
    else if c == '(' then next (i + 1) .lp
    else if c == ')' then next (i + 1) .rp
    else if c == ',' then next (i + 1) .comma
    else if c == '=' then next (i + 1) .eq
    else if c == ';' then next (i + 1) .semi
    else lexAux s (i + 1) acc sections

def lex (text : String) : Array Tk := lexAux text.toList.toArray 0 #[] 0

/-! ## Syntax -/

inductive Actual where
  | sym (name : String) (args : List Actual)
  deriving Repr, BEq, Hashable, Inhabited

structure Branch where
  prods : List Actual
  prec : Option String
  deriving Repr, Inhabited

structure Rule where
  name : String
  params : List String
  inline : Bool
  branches : List Branch
  deriving Repr, Inhabited

inductive Assoc where
  | left | right | nonassoc
  deriving Repr, BEq, Inhabited

structure File where
  tokens : List String := []
  aliases : List (String × String) := []
  /-- Precedence levels, loosest first: the symbols of each `%left`/`%right`/`%nonassoc`. -/
  levels : List (Assoc × List String) := []
  starts : List String := []
  rules : List Rule := []
  deriving Inhabited

/-! ## Parsing -/

structure P where
  toks : Array Tk
  pos : Nat := 0

def P.peek (p : P) (k : Nat := 0) : Tk := p.toks.getD (p.pos + k) (.kw "<eof>")

/-- Does a rule definition start at `i`: `name :` or `name (params) :`? -/
def ruleStart (t : Array Tk) (i : Nat) : Bool :=
  match t.getD i (.kw "<eof>") with
  | .kw "%public" | .kw "%inline" => true
  | .id _ =>
    match t.getD (i + 1) (.kw "<eof>") with
    | .colon => true
    | .lp => Id.run do
      let mut j := i + 2
      let mut d := 1
      while d > 0 && j < t.size do
        match t[j]! with
        | .lp => d := d + 1
        | .rp => d := d - 1
        | _ => pure ()
        j := j + 1
      return t.getD j (.kw "<eof>") == .colon
    | _ => false
  | _ => false

partial def parseActual (t : Array Tk) (i : Nat) : Except String (Actual × Nat) := do
  match t.getD i (.kw "<eof>") with
  | .str s => return (.sym ("\"" ++ s ++ "\"") [], i + 1)
  | .id n =>
    if t.getD (i + 1) (.kw "<eof>") == .lp then
      let mut j := i + 2
      let mut args : List Actual := []
      repeat
        let (a, j') ← parseActual t j
        args := args ++ [a]
        j := j'
        match t.getD j (.kw "<eof>") with
        | .comma => j := j + 1
        | .rp => break
        | tk => throw s!"expected , or ) in an actual, found {repr tk}"
      return (.sym n args, j + 1)
    else return (.sym n [], i + 1)
  | tk => throw s!"expected a symbol, found {repr tk}"

/-- Parse the rules section into rules. -/
partial def parseRules (t : Array Tk) (i0 : Nat) : Except String (List Rule) := do
  let mut i := i0
  let mut rules : List Rule := []
  while i < t.size && t[i]! != .kw "%%" do
    let mut inline := false
    while t[i]! == .kw "%public" || t[i]! == .kw "%inline" do
      if t[i]! == .kw "%inline" then inline := true
      i := i + 1
    let name ← match t[i]! with
      | .id n => pure n
      | tk => throw s!"expected a rule name, found {repr tk}"
    i := i + 1
    let mut params : List String := []
    if t.getD i .semi == .lp then
      i := i + 1
      repeat
        match t[i]! with
        | .id x => params := params ++ [x]; i := i + 1
        | tk => throw s!"expected a parameter, found {repr tk}"
        match t[i]! with
        | .comma => i := i + 1
        | .rp => i := i + 1; break
        | tk => throw s!"expected , or ), found {repr tk}"
    if t.getD i .semi != .colon then throw s!"expected : after {name}"
    i := i + 1
    if t.getD i .semi == .bar then i := i + 1
    let mut branches : List Branch := []
    let mut group : List (List Actual) := []
    let mut cur : List Actual := []
    let mut prec : Option String := none
    let mut done := false
    while !done do
      match t.getD i (.kw "<eof>") with
      | .act =>
        group := group ++ [cur]
        i := i + 1
        -- a %prec may also follow the action
        if t.getD i .semi == .kw "%prec" then
          match t.getD (i + 1) .semi with
          | .id x => prec := some x; i := i + 2
          | _ => throw "expected a symbol after %prec"
        branches := branches ++ group.map fun ps => { prods := ps, prec }
        group := []; cur := []; prec := none
        match t.getD i (.kw "<eof>") with
        | .bar => i := i + 1
        | .semi => i := i + 1; done := true
        | _ => done := true
      | .bar => group := group ++ [cur]; cur := []; i := i + 1
      | .semi => i := i + 1
      | .kw "%prec" =>
        match t.getD (i + 1) .semi with
        | .id x => prec := some x; i := i + 2
        | _ => throw "expected a symbol after %prec"
      | .kw "%%" => done := true
      | .kw "<eof>" => done := true
      | _ =>
        if ruleStart t i then done := true
        else
          -- `x = actual` or `actual`
          if t.getD (i + 1) .semi == .eq then i := i + 2
          let (a, j) ← parseActual t i
          cur := cur ++ [a]
          i := j
    if !cur.isEmpty || !group.isEmpty then throw s!"production without an action in {name}"
    rules := rules ++ [({ name, params, inline, branches } : Rule)]
  return rules

def parseFile (text : String) : Except String File := do
  let t := lex text
  let mut f : File := {}
  let mut i := 0
  while i < t.size && t[i]! != .kw "%%" do
    match t[i]! with
    | .kw "%token" =>
      i := i + 1
      if t.getD i .semi == .ty then i := i + 1
      let mut go := true
      while go do
        match t.getD i .semi with
        | .id x =>
          f := { f with tokens := f.tokens ++ [x] }
          i := i + 1
          match t.getD i .semi with
          | .str a => f := { f with aliases := f.aliases ++ [(a, x)] }; i := i + 1
          | _ => pure ()
        | _ => go := false
    | .kw k =>
      if k == "%left" || k == "%right" || k == "%nonassoc" then
        let assoc := if k == "%left" then Assoc.left else if k == "%right" then .right else .nonassoc
        i := i + 1
        let mut syms : List String := []
        while (match t.getD i .semi with | .id _ => true | _ => false) do
          match t[i]! with
          | .id x => syms := syms ++ [x]
          | _ => pure ()
          i := i + 1
        f := { f with levels := f.levels ++ [(assoc, syms)] }
      else if k == "%start" then
        i := i + 1
        if t.getD i .semi == .ty then i := i + 1
        while (match t.getD i .semi with | .id _ => true | _ => false) do
          match t[i]! with
          | .id x => f := { f with starts := f.starts ++ [x] }
          | _ => pure ()
          i := i + 1
      else
        -- %type and the rest carry no grammar
        i := i + 1
        while i < t.size && (match t[i]! with | .kw _ => false | _ => true) do i := i + 1
    | _ => i := i + 1
  let rules ← parseRules t (i + 1)
  return { f with rules }

/-! ## Expansion -/

/-- A source production after expansion: left-hand side, right-hand side
(terminal and nonterminal names), and its `%prec` symbol if any. -/
structure Prod where
  lhs : String
  rhs : List String
  prec : Option String
  deriving Repr, BEq, Inhabited

structure Grammar where
  tokens : List String
  levels : List (Assoc × List String)
  start : String
  prods : Array Prod
  deriving Inhabited

/-- Substitute parameters; an applied parameter receives its arguments. -/
partial def subst (env : List (String × Actual)) : Actual → Actual
  | .sym n args =>
    let args := args.map (subst env)
    match env.lookup n with
    | some (.sym m args0) => .sym m (args0 ++ args)
    | none => .sym n args

/-- Menhir's name for an instance. -/
partial def mangle : Actual → String
  | .sym n [] => n
  | .sym n args => n ++ "_" ++ "_".intercalate (args.map mangle) ++ "_"

structure ExpandState where
  done : Std.HashSet String := {}
  todo : List Actual := []
  prods : Array Prod := #[]

/-- Expand the grammar reachable from its start symbol. Unverified as code, but
it is part of the definition: it computes the source grammar's productions. -/
partial def expand (f : File) (std : List Rule) (fuel : Nat := 100000) : Except String Grammar := do
  let rules := f.rules ++ std.filter fun r => !(f.rules.any (·.name == r.name))
  let find := fun (n : String) => rules.find? (·.name == n)
  let tokens := f.tokens
  -- resolve an alias and decide whether a closed actual is a terminal
  let resolveTok := fun (a : Actual) => match a with
    | .sym n [] =>
      if tokens.contains n then some n
      else if n.startsWith "\"" then f.aliases.lookup ((n.drop 1).dropEnd 1).toString
      else none
    | _ => none
  -- normalize arguments: aliases become token names
  let rec norm (a : Actual) : Actual :=
    match resolveTok a with
    | some t => .sym t []
    | none => match a with | .sym n args => .sym n (args.map norm)
  -- the expanded branches of an instance: each a list of closed symbols and a %prec
  let rec branchesOf (inst : Actual) (depth : Nat) : Except String (List (List Actual × Option String)) := do
    if depth > 64 then throw s!"inline expansion too deep at {mangle inst}"
    match inst with
    | .sym n args =>
      let some r := find n | throw s!"unknown symbol {n}"
      if r.params.length != args.length then throw s!"{n} expects {r.params.length} arguments"
      let env := r.params.zip args
      let mut out := []
      for b in r.branches do
        -- inline left to right: a list of partial expansions
        let mut partials : List (List Actual × Option String) := [([], b.prec)]
        for a in b.prods do
          let a := norm (subst env a)
          match resolveTok a with
          | some t => partials := partials.map fun (ps, pr) => (ps ++ [.sym t []], pr)
          | none =>
            match a with
            | .sym m _ =>
              let some r' := find m | throw s!"unknown symbol {m}"
              if r'.inline then
                let callee ← branchesOf a (depth + 1)
                partials := partials.flatMap fun (ps, pr) => callee.map fun (cs, cp) =>
                  (ps ++ cs, match cp with | some _ => cp | none => pr)
              else partials := partials.map fun (ps, pr) => (ps ++ [a], pr)
        out := out ++ partials
      return out
  let some start := f.starts.head? | throw "no %start"
  let mut st : ExpandState := { todo := [.sym start []] }
  let mut n := 0
  while !st.todo.isEmpty do
    n := n + 1
    if n > fuel then throw "expansion limit"
    let inst :: rest := st.todo | break
    st := { st with todo := rest }
    let name := mangle inst
    if st.done.contains name then continue
    st := { st with done := st.done.insert name }
    let bs ← branchesOf inst 0
    for (ps, pr) in bs do
      st := { st with prods := st.prods.push { lhs := name, rhs := ps.map mangle, prec := pr } }
      for p in ps do
        if (resolveTok p).isNone && !st.done.contains (mangle p) then
          st := { st with todo := st.todo ++ [p] }
  return { tokens, levels := f.levels, start, prods := st.prods }

/-- The rules of Menhir's standard library (manual §5.4), as Menhir defines
them; actions are irrelevant here and written as `{}`. -/
def stdlib : String := "%%
%public %inline endrule(X): X {}
%public %inline anonymous(X): X {}
%public midrule(X): X {}
%public embedded(X): X {}
%public option(X): {} | X {}
%public %inline ioption(X): {} | X {}
%public boption(X): {} | X {}
%public loption(X): {} | X {}
%public %inline epsilon: {}
%public %inline pair(X, Y): X Y {}
%public %inline separated_pair(X, sep, Y): X sep Y {}
%public %inline preceded(opening, X): opening X {}
%public %inline terminated(X, closing): X closing {}
%public %inline delimited(opening, X, closing): opening X closing {}
%public list(X): {} | X list(X) {}
%public nonempty_list(X): X {} | X nonempty_list(X) {}
%public %inline separated_list(separator, X): loption(separated_nonempty_list(separator, X)) {}
%public separated_nonempty_list(separator, X): X {} | X separator separated_nonempty_list(separator, X) {}
%public %inline rev(XS): XS {}
%public %inline flatten(XSS): XSS {}
%public %inline append(XS, YS): XS YS {}
"

/-- The source grammar of a Menhir file, with Menhir's standard library. -/
def sourceGrammar (text : String) (stdText : String := stdlib) : Except String Grammar := do
  let f ← parseFile text
  let s ← parseFile stdText
  expand f s.rules

end Ambiguity.Mly
