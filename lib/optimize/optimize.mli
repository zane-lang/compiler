(** Stage 5: optimization, the CGT to a faster CGT
    (docs/design/optimization.md). An unoptimized build runs none of it. *)

(** The program with every value it can compute at compile time computed. *)
val run : Cgt.Nodes.Program.t -> Cgt.Nodes.Program.t
