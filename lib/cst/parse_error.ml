(* Raised by grammar actions for a form the grammar accepts but the language
   does not, such as an abort handler on an operation that cannot abort.
   [Cst.parse] catches it and reports it as a [Diagnostic.t] at the current
   position, so these stay inside the [Ok]/[Error] contract instead of escaping
   as [Invalid_argument].

   It carries the message alone because the action raising it does not choose
   where the report points: the lexer's position at the time of the raise is
   what the report has always used. *)
exception Rejected of string
