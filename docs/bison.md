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
