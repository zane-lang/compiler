# Grammar notes

## List rules

A list rule allows the empty case and grows by one element per recursive step.
The empty case needs no explicit instantiation:

```bison
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

## Separated lists

A list whose elements are separated — rather than terminated — by a token needs
a single-element base case. Recursing straight from `%empty` over a separator
puts the separator before the first element, so `f(, test Int)` would parse and
`f(test Int)` would not:

```bison
parameters
	: %empty
	| parameter
	| parameters[params] COMMA parameter[p]
		{
			$params.push_back(std::move($p));
			$$ = std::move($params);
		}
	;
```

## Lookahead

Sub-nodes are reduced before they are matched, so no ambiguity may exist that
would have to be resolved by looking at a following sub-node. GLR parsing would
handle it, but LALR(1) is linear and GLR is slower.
