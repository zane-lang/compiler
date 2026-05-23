We use 4 stages:
1. parsing: astA
2. semantics: astB
3. optimizations: mutate astB
4. codegen: binary

we use two different ast's. astA only captures the content and doesnt do name resolution or desugaring.
those things are handled in stage 2 semantics.
