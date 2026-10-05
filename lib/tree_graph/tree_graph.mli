(** A tree of labelled nodes, and its rendering as the indented text the
    golden files hold. Each stage builds one from its own nodes. *)

include module type of struct
  include Node
end

val render : node -> string
