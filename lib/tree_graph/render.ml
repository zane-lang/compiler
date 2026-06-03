let indent level = String.make (level * 2) ' ' 


let rec render indent_level node = 
  match node with
  | Node.Leaf leaf -> 
    indent indent_level ^ leaf
  | Node.Fields (name, fields) -> 
    indent indent_level ^ name ^ ":\n" ^ render_fields (indent_level + 1) fields
  | Node.Children (name, children) ->
    indent indent_level ^ name ^ ":\n" ^ 
    String.concat "\n" (List.map (fun c -> render (indent_level + 1) c) children)

and render_fields indent_level fields =
    Node.StringMap.bindings fields
  |> List.map (fun (key, child_node) ->
    indent indent_level ^ key ^ ":\n" ^ render (indent_level + 1) child_node
  )
  |> String.concat "\n"
