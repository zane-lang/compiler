(* An LLVM context is disposed only through [dispose], which runs a full
   collection first. The bindings free a builder ([Llvm.llbuilder]) only in
   its finalizer, and a builder made at an instruction ([Llvm.builder_before],
   [Llvm.builder_at]) holds a tracked reference to that instruction's debug
   location, a node the context owns. A builder the collector finalized after
   its context was disposed released freed memory: on Windows, `zanec --ll
   --optimize` crashed at exit when the rewrite passes had made builders in
   runtime code compiled with debug information. The collection finalizes
   every builder that is no longer reachable while the context still exists,
   so no builder may be kept past the context it was made in. *)
let dispose ctx =
  Gc.full_major ();
  Llvm.dispose_context ctx
