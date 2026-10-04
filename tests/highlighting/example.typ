#set page(width: auto, height: auto, margin: 10pt)
#set raw(syntaxes: "../../editors/typst/Zane.sublime-syntax")

```zane
/// A Unicode type and a private identifier.
type Résultat = struct { value Int; }
Unit main() {
  _count Int = 1'000;
  amount Float = 3.14;
  message String = "return // type";
  return Unit();
}
```
