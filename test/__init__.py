# Present so `test` is a regular package rather than a namespace one. Python's
# own standard library ships a package called `test`, and a namespace portion
# found earlier on the path loses to a regular package found later -- so
# without this file `python3 -m unittest test.parser.syntax_test` imports the
# standard library's `test` and reports the module as missing.
