libc caused issues, which is why the buildscript was updated to be more robust.
to test:

get to state before issue
`sudo apt remove libc++-21-dev libc++abi-21-dev`
get to state after issue
`sudo apt install libc++-21-dev libc++abi-21-dev`

should be fixed on the commit where notes.md is added
