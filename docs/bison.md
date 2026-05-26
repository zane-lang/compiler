for recursion dont need to specify the single node variant when empty a variant.
also: empty doesnt need explicit instantiation.

```
parameters
	: %empty
	| parameters[params] COMMA parameter[p]
		{
			$params.push_back(std::move($p));
			$$ = std::move($params);
		}
	;
```
only use single node variant if we dont allow empty.

actually, this is incorrect, as only allowing empty nodes mess with commas, which would only allow:
```
Void main(, test Int) {
	print(2, 2)
	Std$print(1 + 1 + 3 + 4)
	@Intrinsics$print("hello", "bye")
}
```
instead of:
```
Void main(test Int) {
	print(2, 2)
	Std$print(1 + 1 + 3 + 4)
	@Intrinsics$print("hello", "bye")
}
```

so we use:
```
parameters
	: %empty
	| parameters[params] COMMA parameter[p]
		{
			$params.push_back(std::move($p));
			$$ = std::move($params);
		}
	;
```
but possible in homologous:
```
statements
	: %empty
		{ $$ = std::vector<std::unique_ptr<ast::nodes::Statement>>(); }
	| statements[list] statement[stmt]
		{
			$list.push_back(std::make_unique<ast::nodes::Statement>(std::move($stmt)));
			$$ = std::move($list);
		}
	;
```
