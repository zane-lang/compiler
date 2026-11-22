(* A builder made at an instruction that has a debug location, as the
   rewrite passes make one in runtime code compiled with debug information,
   and dropped while its context lives. The context is then disposed through
   Contexts.dispose and the heap collected. Disposed through
   Llvm.dispose_context instead, the builder's finalizer runs in that last
   collection and releases the location's node after the context freed it,
   which Valgrind reports (tests/runtime/valgrind_test.py). Run natively,
   the program only has to exit. *)

let ir =
  {|
define void @f() !dbg !5 {
  ret void, !dbg !8
}
!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)
!1 = !DIFile(filename: "runtime.c", directory: "/")
!3 = !{i32 2, !"Debug Info Version", i32 3}
!5 = distinct !DISubprogram(name: "f", scope: !1, file: !1, line: 1, type: !6, unit: !0)
!6 = !DISubroutineType(types: !7)
!7 = !{null}
!8 = !DILocation(line: 2, column: 3, scope: !5)
|}

let () =
  let ctx = Llvm.create_context () in
  let m = Llvm_irreader.parse_ir ctx (Llvm.MemoryBuffer.of_string ir) in
  let f = Option.get (Llvm.lookup_function "f" m) in
  let ret = Option.get (Llvm.block_terminator (Llvm.entry_block f)) in
  ignore (Sys.opaque_identity (Llvm.builder_before ctx ret));
  Llvm.dispose_module m;
  Codegen__Contexts.dispose ctx;
  Gc.full_major ()
