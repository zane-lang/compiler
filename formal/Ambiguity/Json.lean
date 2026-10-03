import Lean.Data.Json
import Ambiguity.Vpa

/-! Reading the Python prover's `certificate.json`. Parsing is not part of the
trusted argument for a model the checker builds itself; for a supplied model it
only decides which model and certificate are checked. -/

namespace Ambiguity
open Lean

def toS : Nat → Except String S
  | 0 => .ok 0 | 1 => .ok 1 | 2 => .ok 2
  | n => .error s!"weight {n} out of range"

def jNat (j : Json) : Except String Nat := j.getNat?
def jStr (j : Json) : Except String String := j.getStr?
def jArr (j : Json) : Except String (Array Json) := j.getArr?

def parseEdge (j : Json) : Except String Edge := do
  let a ← jArr j
  match ← jStr a[0]! with
  | "E" => return .eps (← jNat a[1]!) (← toS (← jNat a[2]!))
  | "I" => return .int (← jStr a[1]!) (← jNat a[2]!)
  | "C" => return .call (← jStr a[1]!) (← jNat a[2]!) (← jNat a[3]!) (← jStr a[4]!)
  | k => throw s!"unknown edge kind {k}"

def parseModel (j : Json) : Except String Model := do
  let edges ← (← jArr (← j.getObjVal? "edges")).mapM fun es => do
    return (← (← jArr es).mapM parseEdge).toList
  let frags ← (← jArr (← j.getObjVal? "fragments")).mapM fun fr => do
    let a ← jArr fr
    return ((← jNat a[0]!), (← jNat a[1]!))
  return { edges, frags }

def parseVec (j : Json) : Except String Vec := do
  return (← (← jArr j).mapM fun e => do
    let a ← jArr e
    return ((← jNat a[0]!), (← jNat a[1]!), (← toS (← jNat a[2]!)))).toList

def parseCert (j : Json) : Except String (Model × Cert) := do
  let model ← parseModel (← j.getObjVal? "model")
  let vectors ← (← jArr (← j.getObjVal? "vectors")).mapM parseVec
  let frames ← (← jArr (← j.getObjVal? "frames")).mapM fun fr => do
    let key ← jArr (← fr.getObjVal? "key")
    let fs ← (← jArr key[0]!).mapM jNat
    let closer ← match key[1]! with
      | .null => pure none
      | c => some <$> jStr c
    let nodes ← (← jArr (← fr.getObjVal? "nodes")).mapM fun i => do
      let i ← jNat i
      if h : i < vectors.size then pure vectors[i] else throw "vector index"
    let exits ← (← jArr (← fr.getObjVal? "exits")).mapM fun ex => do
      return (← (← jArr ex).mapM fun e => do
        let a ← jArr e
        return ((← jNat a[0]!), (← toS (← jNat a[1]!)))).toList
    return ({ fs := fs.toList, closer, nodes := nodes.toList, exits := exits.toList } : Frame)
  return (model, { frames := frames.toList })

/-- The four bracket pairs of the Zane grammar. -/
def zaneBrackets : Tok → Option Tok
  | "LPAREN" => some "RPAREN"
  | "LBRACKET" => some "RBRACKET"
  | "LCURLY" => some "RCURLY"
  | "GLESS" => some "GMORE"
  | _ => none

end Ambiguity
