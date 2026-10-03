import Ambiguity
open Ambiguity

def main (args : List String) : IO UInt32 := do
  match args with
  | ["certificate", path] =>
    let text ← IO.FS.readFile path
    let j ← IO.ofExcept (Lean.Json.parse text)
    let (M, C) ← IO.ofExcept (parseCert j)
    if check zaneBrackets M C then
      IO.println s!"VERIFIED: {M.size} model states, {C.frames.length} frames"
      return 0
    else
      IO.println "REJECTED"
      return 1
  | _ => IO.eprintln "usage: zane-ambiguity-check certificate <certificate.json>"; return 2
