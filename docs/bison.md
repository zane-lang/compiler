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
		{ $$ = std::vector<ast::nodes::Parameter>(); }
	| parameter[p]
		{
			$$ = std::vector<ast::nodes::Parameter>();
			$$.push_back(std::move($p));
		}
	| parameters[params] COMMA parameter[p]
		{
			$params.push_back(std::move($p));
			$$ = std::move($params);
		}
	;
```

## Lookahead

The grammar is parsed with menhirGLR, so a rule may need more than one token of
lookahead: where the parser cannot yet tell two readings apart it forks and
carries both, and constructs are allowed to require unbounded lookahead.

What a rule must not do is leave an input with more than one parse. Forking is
free; every fork but one has to die before acceptance. `docs/ambiguity.md` holds
the policy and the per-conflict proof obligations a new rule has to satisfy.
