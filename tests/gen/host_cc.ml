(* The C compiler the C tests of the runtime (tests/runtime) are built with,
   for the host they run on: clang, or on Windows `zig cc` for MinGW, the
   only Windows the runtime supports (docs/design/platforms.md), from `ZIG`
   where it is set. Its arguments are passed on, and its status is this
   program's. *)
let () =
  let args = List.tl (Array.to_list Sys.argv) in
  let prog, args =
    if Sys.win32 then
      let zig = match Sys.getenv_opt "ZIG" with Some z when z <> "" -> z | _ -> "zig" in
      (zig, "cc" :: "--target=x86_64-windows-gnu" :: args)
    else ("clang", args)
  in
  exit (Sys.command (Filename.quote_command prog args))
